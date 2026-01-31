local api = vim.api
local fn = vim.fn
local fmt = string.format
local job = require("plenary.job")
local curl = require("plenary.curl")
local config = require("lvim-dependencies.config")
local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local L = vim.log.levels
local versions_cache = {}

local M = {}

-- Helper functions (must be defined before parsers / fetchers)
local function is_packagist_candidate(name)
	if not name or name == "" then
		return false
	end
	if name:find("/", 1, true) then
		return true
	end
	return false
end

local function to_version(str)
	if not str then
		return { 0, 0, 0 }
	end
	local s = tostring(str)
	if utils and type(utils.clean_version) == "function" then
		local ok, cv = pcall(utils.clean_version, s)
		if ok and cv and cv ~= "" then
			s = cv
		end
	end
	s = s:gsub("^%s*[vV]", "")
	s = s:gsub("%+.*$", ""):gsub("%-.*$", "")
	local parts = {}
	for i, p in ipairs(vim.split(s, ".", { plain = true })) do
		parts[i] = tonumber(p) or 0
	end
	return { parts[1] or 0, parts[2] or 0, parts[3] or 0 }
end

local function compare_versions(a, b)
	local na = to_version(a)
	local nb = to_version(b)
	for i = 1, 3 do
		local va = na[i] or 0
		local vb = nb[i] or 0
		if va > vb then
			return 1
		elseif va < vb then
			return -1
		end
	end
	return 0
end

local function clean(v)
	if not v then
		return nil
	end
	return utils.clean_version(v)
end

local function extract_latest_from_pub_body(body)
	if not body or body == "" then
		return nil
	end
	local m = body:match('"latest"%s*:%s*{[^}]-"version"%s*:%s*"(.-)"')
	if m and m ~= "" then
		return m
	end
	m = body:match('"version"%s*:%s*"(.-)"')
	if m and m ~= "" then
		return m
	end
	return nil
end

local function parse_pubdev_latest_slow(body)
	local ok, parsed = pcall(function()
		return decoder.parse_json(body)
	end)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	if parsed.latest and type(parsed.latest) == "table" and parsed.latest.version then
		return tostring(parsed.latest.version)
	end
	if parsed.versions and type(parsed.versions) == "table" and parsed.versions[1] and parsed.versions[1].version then
		return tostring(parsed.versions[1].version)
	end
	return nil
end

-- host failure & negative caches (use config values; no defaults here)
local host_failures = {} -- host -> { count = n, blackout_until = ts }
local negative_cache = {} -- key(manifest.."|"..name) -> { ts = now, reason = str }

local function now_ms()
	return vim.loop.now()
end

local function host_from_url(url)
	return url:match("^https?://([^/]+)")
end

local function is_host_blackouted(host)
	local rec = host_failures[host]
	if not rec then
		return false
	end
	return rec.blackout_until and rec.blackout_until > now_ms()
end

local function record_host_failure(host)
	host_failures[host] = host_failures[host] or { count = 0, blackout_until = nil, last_failed = 0 }
	local rec = host_failures[host]
	rec.count = rec.count + 1
	rec.last_failed = now_ms()
	if rec.count >= config.performance.dynamic_throttle.failure_threshold then
		rec.blackout_until = now_ms() + config.network.host_failure_blackout_ms
		utils.notify_safe(
			fmt(
				"Host %s temporarily suspended for %d ms due to repeated failures",
				tostring(host),
				config.network.host_failure_blackout_ms
			),
			L.WARN
		)
	end
end

local function clear_host_failures(host)
	host_failures[host] = nil
end

local function negative_cache_key(manifest, name)
	return manifest .. "|" .. (name or "")
end

local function is_negative_cached(manifest, name)
	local k = negative_cache_key(manifest, name)
	local rec = negative_cache[k]
	if not rec then
		return false
	end
	return (now_ms() - rec.ts) < config.network.negative_cache_ttl_ms
end

local function set_negative_cache(manifest, name, reason)
	local k = negative_cache_key(manifest, name)
	negative_cache[k] = { ts = now_ms(), reason = reason }
end

local function clear_negative_cache(manifest, name)
	local k = negative_cache_key(manifest, name)
	negative_cache[k] = nil
end

local function backoff_delay(attempt)
	local base = config.network.request_retry_base_ms
	local jitter = math.random(0, config.network.request_retry_jitter_ms)
	local mult = 2 ^ (attempt - 1)
	return base * mult + jitter
end

local function perform_request_with_retries(url, name, manifest_key, parser_fn, on_success, on_error)
	local host = host_from_url(url)

	if is_host_blackouted(host) then
		on_error(fmt("host %s is temporarily suspended", tostring(host)))
		return
	end

	if is_negative_cached(manifest_key, name) then
		local rec = negative_cache[negative_cache_key(manifest_key, name)]
		on_error(
			fmt("negative cache for %s/%s: %s", tostring(manifest_key), tostring(name), tostring(rec and rec.reason))
		)
		return
	end

	local max_retries = config.network.request_max_retries
	local attempt = 0

	local function try_once()
		attempt = attempt + 1
		curl.get({
			url = url,
			timeout = config.network.per_request_timeout_ms / 1000,
			callback = function(response)
				if not response then
					if attempt <= max_retries then
						local delay = backoff_delay(attempt)
						vim.defer_fn(try_once, delay)
						return
					end
					record_host_failure(host)
					set_negative_cache(manifest_key, name, "no response")
					on_error(fmt("no response from %s for %s (attempt=%d)", tostring(url), tostring(name), attempt))
					return
				end

				local body_len = (response.body and #response.body) or 0
				local status = response.status or 0

				if body_len == 0 then
					if attempt <= max_retries then
						local delay = backoff_delay(attempt)
						vim.defer_fn(try_once, delay)
						return
					end
					record_host_failure(host)
					set_negative_cache(manifest_key, name, fmt("empty body (status=%d, len=%d)", status, body_len))
					utils.notify_safe(
						fmt(
							"Empty body from %s for %s (status=%d, len=%d)",
							tostring(url),
							tostring(name),
							status,
							body_len
						),
						L.WARN
					)
					on_error(fmt("empty body (status=%d, len=%d) for %s", status, body_len, tostring(name)))
					return
				end

				if status ~= 200 then
					if status >= 500 and attempt <= max_retries then
						local delay = backoff_delay(attempt)
						vim.defer_fn(try_once, delay)
						return
					end
					record_host_failure(host)
					set_negative_cache(manifest_key, name, fmt("HTTP %d (len=%d)", status, body_len))
					utils.notify_safe(
						fmt("HTTP %d from %s for %s (len=%d)", status, tostring(url), tostring(name), body_len),
						L.WARN
					)
					on_error(fmt("HTTP %d for %s", status, tostring(name)))
					return
				end

				local ok, parsed, perr = pcall(function()
					return parser_fn(response.body)
				end)
				if not ok then
					utils.notify_safe(
						fmt("Parser threw for %s (%s): %s", tostring(name), tostring(url), tostring(parsed)),
						L.WARN
					)
					record_host_failure(host)
					set_negative_cache(manifest_key, name, tostring(parsed))
					on_error(fmt("parser threw for %s: %s", tostring(name), tostring(parsed)))
					return
				end

				if parsed == nil and perr then
					utils.notify_safe(
						fmt(
							"Parse error for %s (%s): %s (status=%d, len=%d)",
							tostring(name),
							tostring(url),
							tostring(perr),
							status,
							body_len
						),
						L.WARN
					)
					record_host_failure(host)
					set_negative_cache(manifest_key, name, tostring(perr))
					on_error(fmt("parse error for %s: %s", tostring(name), tostring(perr)))
					return
				end

				clear_host_failures(host)
				clear_negative_cache(manifest_key, name)
				on_success(parsed)
			end,
		})
	end

	try_once()
end

-- parser helpers returning latest or nil; they only return values (no notify) so wrapper handles notifications
local function parser_pub(body)
	local m = extract_latest_from_pub_body(body)
	if m and m ~= "" then
		return clean(m)
	end
	-- fallback to slower JSON parse helper
	local latest2 = parse_pubdev_latest_slow(body)
	if latest2 and latest2 ~= "" then
		return clean(latest2)
	end
	return nil
end

local function parser_crates(body)
	local ok, parsed = pcall(function()
		return decoder.parse_json(body)
	end)
	if not ok then
		error(parsed)
	end
	if parsed and type(parsed) == "table" then
		if parsed.crate and parsed.crate.max_stable_version then
			return clean(parsed.crate.max_stable_version)
		end
		if parsed.crate and parsed.crate.max_version then
			return clean(parsed.crate.max_version)
		end
		if parsed.versions and type(parsed.versions) == "table" and parsed.versions[1] and parsed.versions[1].num then
			return clean(parsed.versions[1].num)
		end
	end
	local v = body:match('"max_stable_version"%s*:%s*"(.-)"') or body:match('"max_version"%s*:%s*"(.-)"')
	if v and v ~= "" then
		return clean(v)
	end
	return nil
end

local function parser_npm(body)
	local ok, parsed = pcall(function()
		return decoder.parse_json(body)
	end)
	if not ok then
		error(parsed)
	end
	if parsed and type(parsed) == "table" then
		if parsed["dist-tags"] and parsed["dist-tags"].latest then
			return clean(parsed["dist-tags"].latest)
		end
	end
	local m = body:match('"dist%-tags"%s*:%s*{.-"latest"%s*:%s*"(.-)"')
	if m and m ~= "" then
		return clean(m)
	end
	return nil
end

local function parser_packagist(body)
	local ok, parsed = pcall(function()
		return decoder.parse_json(body)
	end)
	if not ok then
		error(parsed)
	end
	if parsed and type(parsed) == "table" and parsed.packages then
		for _, entries in pairs(parsed.packages) do
			if entries and entries[1] then
				local entry = entries[1]
				local v = entry.version or entry["version"] or entry["version_normalized"] or nil
				if v and v ~= "" then
					return clean(v)
				end
			end
		end
	end
	local m = body:match('"version"%s*:%s*"(.-)"')
	if m and m ~= "" then
		return clean(m)
	end
	return nil
end

local function parser_go(body)
	local ok, parsed = pcall(function()
		return decoder.parse_json(body)
	end)
	if not ok then
		error(parsed)
	end
	if parsed and type(parsed) == "table" and parsed.Version then
		return tostring(parsed.Version)
	end
	local m = body:match('"Version"%s*:%s*"(.-)"') or body:match('"version"%s*:%s*"(.-)"')
	if m and m ~= "" then
		return m
	end
	return nil
end

-- fetcher wrappers that call perform_request_with_retries with appropriate parser
local function fetch_pub_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local url = fmt("%s/packages/%s", config.network.pubspec_uri, name)
	perform_request_with_retries(url, name, "pubspec", parser_pub, function(latest)
		on_success(latest)
	end, on_error)
end

local function fetch_crates_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local url = fmt("%s/%s", config.network.crates_uri, name)
	perform_request_with_retries(url, name, "crates", parser_crates, function(latest)
		on_success(latest)
	end, on_error)
end

local function url_encode_npm(name)
	if not name then
		return ""
	end
	local enc = name:gsub("@", "%%40"):gsub("/", "%%2F")
	return enc
end

local function fetch_npm_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local enc = url_encode_npm(name)
	local url = fmt("%s/%s", config.network.package_uri, enc)
	perform_request_with_retries(url, name, "package", parser_npm, function(latest)
		on_success(latest)
	end, on_error)
end

local function fetch_packagist_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local url = fmt("%s/%s.json", config.network.composer_uri, name)
	perform_request_with_retries(url, name, "composer", parser_packagist, function(latest)
		on_success(latest)
	end, on_error)
end

local function url_encode_module(s)
	if not s then
		return ""
	end
	return (s:gsub("([^A-Za-z0-9_~%.%-])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function fetch_go_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local base = tostring(config.network.go_uri):gsub("/+$", "")
	local enc = url_encode_module(name)
	local url = fmt("%s/%s/@latest", base, enc)
	perform_request_with_retries(url, name, "go", parser_go, function(latest)
		on_success(latest)
	end, on_error)
end

local FETCHERS = {
	pubspec = fetch_pub_async,
	crates = fetch_crates_async,
	package = fetch_npm_async,
	composer = fetch_packagist_async,
	go = fetch_go_async,
}

-- the rest of the module (scheduling, publishing, CLI fallback, caching, UI triggers)
local function schedule_publish(bufnr, manifest_key)
	manifest_key = manifest_key or "pubspec"
	if not bufnr then
		return
	end

	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil, last_fetched_at = nil }

	local cache = versions_cache[manifest_key][bufnr]
	if cache.publish_timer then
		return
	end

	cache.publish_timer = vim.defer_fn(function()
		cache.publish_timer = nil

		cache.data = cache.data or {}
		for name, entry in pairs(cache.pending or {}) do
			if entry and entry.latest then
				cache.data[name] = { latest = entry.latest }
			else
				cache.data[name] = nil
			end
		end
		cache.pending = {}

		local deps_state = state.get_dependencies and state.get_dependencies(manifest_key) or {}
		local installed_table = deps_state and deps_state.installed or {}
		local final = {}
		for name, info in pairs(cache.data or {}) do
			if info and info.latest and installed_table and installed_table[name] then
				local installed_cur = installed_table[name] and installed_table[name].current
				if installed_cur and installed_cur ~= "" then
					local cmp = compare_versions(installed_cur, info.latest)
					if cmp == 1 then
						final[name] = {
							current = installed_table[name] and installed_table[name].current or nil,
							latest = info.latest,
							constraint_newer = true,
						}
						goto continue_entry
					elseif cmp == 0 then
						goto continue_entry
					end
				end

				final[name] =
					{ current = installed_table[name] and installed_table[name].current or nil, latest = info.latest }
			end
			::continue_entry::
		end

		if type(state.set_outdated) == "function" then
			vim.schedule(function()
				pcall(state.set_outdated, manifest_key, final)

				versions_cache[manifest_key] = versions_cache[manifest_key] or {}
				versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr] or {}
				versions_cache[manifest_key][bufnr].last_fetched_at = vim.loop.now()

				pcall(function()
					local ok, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok and ui and type(ui.display) == "function" then
						pcall(ui.display, bufnr, manifest_key)
					end
				end)
			end)
		end
	end, config.network.publish_debounce_ms)
end

local function add_pending_result(bufnr, name, latest, manifest_key)
	manifest_key = manifest_key or "pubspec"
	if not bufnr then
		return
	end
	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil, last_fetched_at = nil }

	local cache = versions_cache[manifest_key][bufnr]
	cache.pending = cache.pending or {}
	cache.pending[name] = { latest = latest }
	schedule_publish(bufnr, manifest_key)
end

local function try_cli_commands_async(cmds, cwd, scalar_deps, on_success, on_failure)
	local idx = 1
	local function try_next()
		if idx > #cmds then
			on_failure()
			return
		end
		local cmd = cmds[idx]
		idx = idx + 1
		job:new({
			command = cmd[1],
			args = vim.list_slice(cmd, 2),
			cwd = cwd,
			on_exit = function(j, code)
				vim.schedule(function()
					local raw = j:result()
					if code ~= 0 then
						raw = j:stderr_result()
					end
					if raw and #raw > 0 then
						local ok, parsed, perr = pcall(function()
							return decoder.parse_json(table.concat(raw, "\n"))
						end)
						if not ok then
							utils.notify_safe(
								fmt("JSON parse threw for CLI output (%s): %s", cmd[1], tostring(parsed)),
								L.WARN
							)
						elseif parsed == nil and perr then
							utils.notify_safe(
								fmt("JSON parse error for CLI output (%s): %s", cmd[1], tostring(perr)),
								L.WARN
							)
						end
						if ok and type(parsed) == "table" and next(parsed) then
							local filtered = {}
							for name, info in pairs(parsed) do
								if scalar_deps[name] then
									filtered[name] = info
								end
							end
							if next(filtered) then
								on_success(filtered)
								return
							end
						end
					end
					try_next()
				end)
			end,
		}):start()
	end
	try_next()
end

function M.check_manifest_outdated(bufnr, manifest_key)
	bufnr = bufnr or api.nvim_get_current_buf()
	if bufnr == -1 then
		return
	end

	local filename = api.nvim_buf_get_name(bufnr) or ""
	local basename = fn.fnamemodify(filename, ":t")
	manifest_key = manifest_key
		or (state.get_manifest_key_from_filename and state.get_manifest_key_from_filename(basename))
		or (basename == "package.json" and "package")
		or (basename == "Cargo.toml" and "crates")
		or (basename == "pubspec.yaml" and "pubspec")
		or (basename == "composer.json" and "composer")
		or manifest_key
	if not manifest_key then
		return
	end

	local deps_state = state.get_dependencies and state.get_dependencies(manifest_key) or {}
	local installed_table = deps_state and deps_state.installed or {}
	local scalar_deps = {}
	for name, info in pairs(installed_table) do
		if info and info.current and info.current ~= "" then
			if manifest_key == "composer" then
				if is_packagist_candidate(name) then
					scalar_deps[name] = true
				end
			else
				scalar_deps[name] = true
			end
		end
	end

	if vim.tbl_isempty(scalar_deps) then
		if type(state.set_outdated) == "function" then
			vim.schedule(function()
				pcall(state.set_outdated, manifest_key, {})
			end)
		end
		return
	end

	local cwd = (utils and utils.get_buffer_dir and utils.get_buffer_dir(bufnr)) or fn.getcwd()

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}
	state.buffers[bufnr].is_loading = true
	vim.schedule(function()
		pcall(function()
			local ok_ui, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
			if ok_ui and ui and type(ui.display) == "function" then
				pcall(ui.display, bufnr, manifest_key)
			end
		end)
	end)

	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil, last_fetched_at = nil }
	local cache = versions_cache[manifest_key][bufnr]

	local now = vim.loop.now()
	if
		cache.last_fetched_at
		and config.performance.cache_ttl_ms
		and config.performance.cache_ttl_ms > 0
		and (now - cache.last_fetched_at) < config.performance.cache_ttl_ms
	then
		if type(state.set_outdated) == "function" then
			vim.schedule(function()
				pcall(state.set_outdated, manifest_key, state.get_dependencies(manifest_key).outdated or {})
				local ok_ui, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
				if ok_ui and ui and type(ui.display) == "function" then
					pcall(ui.display, bufnr, manifest_key)
				end
			end)
		end
		state.buffers[bufnr].is_loading = false
		return
	end

	if not (cache and cache.watchdog) then
		local t = nil
		local ok_new, maybe_t = pcall(function()
			return vim.loop.new_timer()
		end)
		if ok_new and maybe_t then
			t = maybe_t
			local started_ok = pcall(function()
				t:start(
					config.network.overall_watchdog_ms,
					0,
					vim.schedule_wrap(function()
						if
							bufnr
							and state
							and state.buffers
							and state.buffers[bufnr]
							and state.buffers[bufnr].is_loading
						then
							state.buffers[bufnr].is_loading = false
							if type(state.set_outdated) == "function" then
								vim.schedule(function()
									pcall(state.set_outdated, manifest_key, {})
								end)
							end
							vim.schedule(function()
								pcall(function()
									local ok2, ui2 = pcall(require, "lvim-dependencies.ui.virtual_text")
									if ok2 and ui2 and type(ui2.display) == "function" then
										pcall(ui2.display, bufnr, manifest_key)
									end
								end)
							end)
						end
						if t then
							pcall(function()
								t:stop()
							end)
							pcall(function()
								t:close()
							end)
						end
						if versions_cache and versions_cache[manifest_key] and versions_cache[manifest_key][bufnr] then
							versions_cache[manifest_key][bufnr].watchdog = nil
						end
					end)
				)
			end)
			if not started_ok then
				pcall(function()
					if t then
						t:close()
					end
				end)
				t = nil
			end
		end

		if t then
			versions_cache[manifest_key] = versions_cache[manifest_key] or {}
			versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr] or {}
			versions_cache[manifest_key][bufnr].watchdog = t
		else
			vim.defer_fn(function()
				if bufnr and state and state.buffers and state.buffers[bufnr] and state.buffers[bufnr].is_loading then
					state.buffers[bufnr].is_loading = false
					if type(state.set_outdated) == "function" then
						pcall(state.set_outdated, manifest_key, {})
					end
					pcall(function()
						local ok2, ui2 = pcall(require, "lvim-dependencies.ui.virtual_text")
						if ok2 and ui2 and type(ui2.display) == "function" then
							pcall(ui2.display, bufnr, manifest_key)
						end
					end)
				end
				if versions_cache and versions_cache[manifest_key] and versions_cache[manifest_key][bufnr] then
					versions_cache[manifest_key][bufnr].watchdog = nil
				end
			end, config.network.overall_watchdog_ms)
		end
	end

	local names_to_fetch = {}
	for name, _ in pairs(scalar_deps) do
		names_to_fetch[#names_to_fetch + 1] = name
	end

	local n = #names_to_fetch
	local concurrency = math.min(
		config.performance.max_concurrency,
		math.max(1, math.floor(n / 6) + 1, config.performance.base_concurrency)
	)
	if n > 80 then
		concurrency = 1
	elseif n > 30 then
		concurrency = math.min(concurrency, 2)
	end

	local fetcher = FETCHERS[manifest_key]
	local has_flutter = (fn.executable("flutter") == 1)
	local has_dart = (fn.executable("dart") == 1)
	local use_cli_fallback = (not fetcher) and (has_flutter or has_dart)

	if not fetcher and not use_cli_fallback then
		if state.buffers and state.buffers[bufnr] then
			state.buffers[bufnr].is_loading = false
		end
		if type(state.set_outdated) == "function" then
			vim.schedule(function()
				pcall(state.set_outdated, manifest_key, {})
			end)
		end
		pcall(vim.schedule, function()
			local ok_ui, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
			if ok_ui and ui and type(ui.display) == "function" then
				pcall(ui.display, bufnr, manifest_key)
			end
		end)
		return
	end

	if use_cli_fallback and not fetcher then
		local cmds = {}
		if has_flutter then
			table.insert(cmds, { "flutter", "pub", "outdated", "--format=json" })
			table.insert(cmds, { "flutter", "pub", "outdated", "--json" })
			table.insert(cmds, { "flutter", "pub", "outdated" })
		end
		if has_dart then
			table.insert(cmds, { "dart", "pub", "outdated", "--format=json" })
			table.insert(cmds, { "dart", "pub", "outdated", "--json" })
			table.insert(cmds, { "dart", "pub", "outdated" })
		end

		if #cmds == 0 then
			if state.buffers and state.buffers[bufnr] then
				state.buffers[bufnr].is_loading = false
			end
			pcall(vim.schedule, function()
				pcall(state.set_outdated, manifest_key, {})
				local ok_ui, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
				if ok_ui and ui and type(ui.display) == "function" then
					pcall(ui.display, bufnr, manifest_key)
				end
			end)
			return
		end

		try_cli_commands_async(cmds, cwd, scalar_deps, function(parsed_cli)
			versions_cache[manifest_key] = versions_cache[manifest_key] or {}
			versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr] or { data = {}, pending = {} }
			local c = versions_cache[manifest_key][bufnr]
			c.data = c.data or {}
			for name, info in pairs(parsed_cli) do
				if scalar_deps[name] and info and info.latest then
					c.data[name] = { latest = info.latest }
					add_pending_result(bufnr, name, info.latest, manifest_key)
				end
			end

			vim.schedule(function()
				local c2 = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
				if c2 then
					c2.last_changed = api.nvim_buf_get_changedtick(bufnr)
				end
				if c2 and c2.watchdog then
					pcall(function()
						c2.watchdog:stop()
					end)
					pcall(function()
						c2.watchdog:close()
					end)
					c2.watchdog = nil
				end
				if state.buffers and state.buffers[bufnr] then
					state.buffers[bufnr].is_loading = false
				end
				schedule_publish(bufnr, manifest_key)
			end)
		end, function()
			if
				versions_cache[manifest_key]
				and versions_cache[manifest_key][bufnr]
				and versions_cache[manifest_key][bufnr].watchdog
			then
				pcall(function()
					versions_cache[manifest_key][bufnr].watchdog:stop()
				end)
				pcall(function()
					versions_cache[manifest_key][bufnr].watchdog:close()
				end)
				versions_cache[manifest_key][bufnr].watchdog = nil
			end
			if state.buffers and state.buffers[bufnr] then
				state.buffers[bufnr].is_loading = false
			end
			if type(state.set_outdated) == "function" then
				pcall(vim.schedule, function()
					state.set_outdated(manifest_key, {})
				end)
			end
			pcall(vim.schedule, function()
				local ok_ui, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
				if ok_ui and ui and type(ui.display) == "function" then
					pcall(ui.display, bufnr, manifest_key)
				end
			end)
		end)

		return
	end

	local in_flight, idx = 0, 1
	local total = #names_to_fetch

	local function try_next()
		while in_flight < concurrency and idx <= total do
			local name = names_to_fetch[idx]
			idx = idx + 1
			in_flight = in_flight + 1

			local on_success = function(latest)
				in_flight = in_flight - 1
				versions_cache[manifest_key] = versions_cache[manifest_key] or {}
				versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr] or { data = {}, pending = {} }
				local c = versions_cache[manifest_key][bufnr]
				c.data = c.data or {}
				if latest then
					c.data[name] = { latest = latest }
				else
					if c and c.data then
						c.data[name] = nil
					end
				end

				add_pending_result(bufnr, name, latest, manifest_key)

				try_next()

				if idx > total and in_flight == 0 then
					vim.schedule(function()
						local c2 = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
						if c2 then
							c2.last_changed = api.nvim_buf_get_changedtick(bufnr)
						end
						if c2 and c2.watchdog then
							pcall(function()
								c2.watchdog:stop()
							end)
							pcall(function()
								c2.watchdog:close()
							end)
							c2.watchdog = nil
						end
						if state.buffers and state.buffers[bufnr] then
							state.buffers[bufnr].is_loading = false
						end
						schedule_publish(bufnr, manifest_key)
					end)
				end
			end

			local on_error = function(err)
				in_flight = in_flight - 1
				utils.notify_safe(fmt("Error fetching %s: %s", name, tostring(err)), L.ERROR)
				local c = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
				if c and c.data then
					c.data[name] = nil
				end
				add_pending_result(bufnr, name, nil, manifest_key)

				try_next()

				if idx > total and in_flight == 0 then
					vim.schedule(function()
						local c2 = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
						if c2 then
							c2.last_changed = api.nvim_buf_get_changedtick(bufnr)
						end
						if c2 and c2.watchdog then
							pcall(function()
								c2.watchdog:stop()
							end)
							pcall(function()
								c2.watchdog:close()
							end)
							c2.watchdog = nil
						end
						if state.buffers and state.buffers[bufnr] then
							state.buffers[bufnr].is_loading = false
						end
						schedule_publish(bufnr, manifest_key)
					end)
				end
			end

			pcall(function()
				fetcher(name, on_success, on_error)
			end)
		end
	end

	try_next()
end

function M.clear_cache(bufnr, manifest_key)
	if manifest_key then
		if
			versions_cache[manifest_key]
			and versions_cache[manifest_key][bufnr]
			and versions_cache[manifest_key][bufnr].watchdog
		then
			pcall(function()
				versions_cache[manifest_key][bufnr].watchdog:stop()
			end)
			pcall(function()
				versions_cache[manifest_key][bufnr].watchdog:close()
			end)
		end
		if bufnr then
			versions_cache[manifest_key][bufnr] = nil
		else
			versions_cache[manifest_key] = nil
		end
	else
		for mk, tbl in pairs(versions_cache) do
			if bufnr and tbl[bufnr] and tbl[bufnr].watchdog then
				pcall(function()
					tbl[bufnr].watchdog:stop()
				end)
				pcall(function()
					tbl[bufnr].watchdog:close()
				end)
			end
			if bufnr then
				tbl[bufnr] = nil
			else
				versions_cache[mk] = nil
			end
		end
	end
end

return M
