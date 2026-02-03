local api = vim.api
local fn = vim.fn
local fmt = string.format
local job = require("plenary.job")
local curl = require("plenary.curl")
local decoder = require("lvim-dependencies.libs.decoder")

local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local ui = require("lvim-dependencies.ui.virtual_text") -- required once for performance

local L = vim.log.levels
local versions_cache = {}

local M = {}

-- small helpers (localized for speed)
local now_ms = vim.loop.now
local defer_fn = vim.defer_fn
local schedule = vim.schedule
local tbl_isempty = vim.tbl_isempty
local list_slice = vim.list_slice

-- -------------------------
-- utilities
-- -------------------------
local function is_packagist_candidate(name)
	return type(name) == "string" and name:find("/", 1, true) ~= nil
end

local function to_version(str)
	if not str then
		return { 0, 0, 0 }
	end
	local s = tostring(str)
	local cv = utils.clean_version(s)
	if cv and cv ~= "" then
		s = cv
	end
	s = s:gsub("^%s*[vV]", ""):gsub("%+.*$", ""):gsub("%-.*$", "")
	local parts = vim.split(s, ".", { plain = true })
	return { tonumber(parts[1]) or 0, tonumber(parts[2]) or 0, tonumber(parts[3]) or 0 }
end

local function compare_versions(a, b)
	local na = to_version(a)
	local nb = to_version(b)
	for i = 1, 3 do
		local va, vb = na[i] or 0, nb[i] or 0
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

local function go_module_path_for_version(name, version)
	if not name or name == "" then
		return name
	end

	if name:match("/v%d+$") then
		return name
	end

	if name:match("%.v%d+$") then
		return name
	end

	local major = (to_version(version) or {})[1] or 0
	if major >= 2 then
		return name .. "/v" .. tostring(major)
	end

	return name
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

-- SAFE json parser wrapper to avoid crashing async callbacks
local function safe_parse_json(body)
	local ok, parsed = pcall(decoder.parse_json, body)
	if not ok then
		return nil
	end
	return parsed
end

local function parse_pubdev_latest_slow(body)
	local parsed = safe_parse_json(body)
	if type(parsed) ~= "table" then
		return nil
	end

	if type(parsed.latest) == "table" and parsed.latest.version then
		return tostring(parsed.latest.version)
	end

	if type(parsed.versions) == "table" and parsed.versions[1] and parsed.versions[1].version then
		return tostring(parsed.versions[1].version)
	end

	return nil
end

-- -------------------------
-- host / negative caches
-- -------------------------
local host_failures = {}
local negative_cache = {}

local function host_from_url(url)
	return url:match("^https?://([^/]+)")
end

local function is_host_blackouted(host)
	local rec = host_failures[host]
	return rec and rec.blackout_until and rec.blackout_until > now_ms()
end

local function record_host_failure(host)
	local rec = host_failures[host] or { count = 0, blackout_until = nil, last_failed = 0 }
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
	host_failures[host] = rec
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
	return rec and ((now_ms() - rec.ts) < config.network.negative_cache_ttl_ms)
end

local function set_negative_cache(manifest, name, reason)
	negative_cache[negative_cache_key(manifest, name)] = { ts = now_ms(), reason = reason }
end

local function clear_negative_cache(manifest, name)
	negative_cache[negative_cache_key(manifest, name)] = nil
end

local function backoff_delay(attempt)
	local base = config.network.request_retry_base_ms
	local jitter = math.random(0, config.network.request_retry_jitter_ms)
	local mult = 2 ^ (attempt - 1)
	return base * mult + jitter
end

-- -------------------------
-- perform request with retries
-- -------------------------
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

	local max_retries = config.network.request_max_retries or 2
	local attempt = 0

	local function try_once()
		attempt = attempt + 1
		curl.get({
			url = url,
			timeout = (config.network.per_request_timeout_ms or 5000) / 1000,
			callback = function(response)
				if not response then
					if attempt <= max_retries then
						defer_fn(try_once, backoff_delay(attempt))
						return
					end
					record_host_failure(host)
					set_negative_cache(manifest_key, name, "no response")
					on_error(fmt("no response from %s for %s (attempt=%d)", tostring(url), tostring(name), attempt))
					return
				end

				local body = response.body or ""
				local body_len = #body
				local status = response.status or 0

				if body_len == 0 then
					if attempt <= max_retries then
						defer_fn(try_once, backoff_delay(attempt))
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
						defer_fn(try_once, backoff_delay(attempt))
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

				-- Guard: npm registry (and others) sometimes return HTML when blocked/rate-limited.
				-- Avoid regex fallbacks returning garbage.
				if body:sub(1, 1) == "<" then
					if attempt <= max_retries then
						defer_fn(try_once, backoff_delay(attempt))
						return
					end
					record_host_failure(host)
					set_negative_cache(manifest_key, name, "html response")
					on_error("registry returned HTML (blocked/rate-limited?)")
					return
				end

				-- Ensure parser cannot crash the async callback
				local okp, parsed = pcall(parser_fn, body)
				if not okp then
					record_host_failure(host)
					set_negative_cache(manifest_key, name, "parser error: " .. tostring(parsed))
					on_error(fmt("parser error for %s: %s", tostring(name), tostring(parsed)))
					return
				end

				if parsed == nil then
					record_host_failure(host)
					set_negative_cache(manifest_key, name, "parser returned nil")
					on_error(fmt("parse error for %s", tostring(name)))
					return
				end

				-- success
				clear_host_failures(host)
				clear_negative_cache(manifest_key, name)
				on_success(parsed)
			end,
		})
	end

	try_once()
end

-- -------------------------
-- parsers
-- -------------------------
local function parser_pub(body)
	local m = extract_latest_from_pub_body(body)
	if m and m ~= "" then
		return clean(m)
	end
	local latest2 = parse_pubdev_latest_slow(body)
	if latest2 and latest2 ~= "" then
		return clean(latest2)
	end
	return nil
end

local function parser_crates(body)
	local parsed = safe_parse_json(body)
	if type(parsed) == "table" then
		if parsed.crate then
			if parsed.crate.max_stable_version then
				return clean(parsed.crate.max_stable_version)
			end
			if parsed.crate.max_version then
				return clean(parsed.crate.max_version)
			end
		end
		if parsed.versions and type(parsed.versions) == "table" and parsed.versions[1] and parsed.versions[1].num then
			return clean(parsed.versions[1].num)
		end
	end
	return nil
end

local function parser_npm(body)
	local parsed = safe_parse_json(body)
	if type(parsed) ~= "table" then
		return nil
	end
	if parsed["dist-tags"] and parsed["dist-tags"].latest then
		return clean(parsed["dist-tags"].latest)
	end
	return nil
end

local function parser_packagist(body)
	local parsed = safe_parse_json(body)
	if type(parsed) == "table" and parsed.packages then
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
	return nil
end

local function parser_go(body)
	local parsed = safe_parse_json(body)
	if type(parsed) == "table" and parsed.Version then
		return tostring(parsed.Version)
	end
	return nil
end

-- -------------------------
-- fetchers
-- -------------------------
local function url_encode_npm(name)
	return (name and name:gsub("@", "%%40"):gsub("/", "%%2F")) or ""
end

local function url_encode_module(s)
	if not s then
		return ""
	end
	return (s:gsub("([^A-Za-z0-9_~%.%-])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function fetch_pub_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local url = fmt("%s/packages/%s", config.network.pubspec_uri, name)
	perform_request_with_retries(url, name, "pubspec", parser_pub, on_success, on_error)
end

local function fetch_crates_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local url = fmt("%s/%s", config.network.crates_uri, name)
	perform_request_with_retries(url, name, "crates", parser_crates, on_success, on_error)
end

local function fetch_npm_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local enc = url_encode_npm(name)
	local url = fmt("%s/%s", config.network.package_uri, enc)
	perform_request_with_retries(url, name, "package", parser_npm, on_success, on_error)
end

local function fetch_packagist_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local url = fmt("%s/%s.json", config.network.composer_uri, name)
	perform_request_with_retries(url, name, "composer", parser_packagist, on_success, on_error)
end

local function fetch_go_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	local base = tostring(config.network.go_uri):gsub("/+$", "")
	local enc = url_encode_module(name)
	local url = fmt("%s/%s/@latest", base, enc)
	perform_request_with_retries(url, name, "go", parser_go, on_success, on_error)
end

local FETCHERS = {
	pubspec = fetch_pub_async,
	crates = fetch_crates_async,
	package = fetch_npm_async,
	composer = fetch_packagist_async,
	go = fetch_go_async,
}

-- -------------------------
-- publish/cache helpers
-- -------------------------
local function stop_watchdog(w)
	if not w then
		return
	end
	w:stop()
	w:close()
end

local function schedule_publish(bufnr, manifest_key)
	manifest_key = manifest_key or "pubspec"
	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	local cache = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil, last_fetched_at = nil }
	versions_cache[manifest_key][bufnr] = cache

	if cache.publish_timer then
		return
	end

	cache.publish_timer = defer_fn(function()
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

		local deps_state = state.get_dependencies(manifest_key)
		local installed_table = deps_state.installed or {}
		local final = {}

		for name, info in pairs(cache.data or {}) do
			local inst = installed_table[name]
			local inst_cur = nil
			if type(inst) == "table" then
				inst_cur = inst.current
			elseif type(inst) == "string" then
				inst_cur = inst
			end

			if info and info.latest and inst and inst_cur and inst_cur ~= "" then
				local latest = info.latest
				local cmp = compare_versions(inst_cur, latest)

				if manifest_key == "composer" then
					local inst_clean = clean(inst_cur) or inst_cur
					local latest_clean = clean(latest) or latest
					cmp = compare_versions(inst_clean, latest_clean)
					latest = latest_clean
					inst_cur = inst_clean
				end

				if cmp == 1 then
					final[name] = { current = inst_cur, latest = latest, constraint_newer = true }
				elseif cmp == 0 then
					final[name] = { current = inst_cur, latest = latest, up_to_date = true }
				else
					final[name] = { current = inst_cur, latest = latest }
				end
			elseif info and info.latest and inst then
				final[name] = { current = inst_cur, latest = info.latest }
			end
		end

		schedule(function()
			state.set_outdated(manifest_key, final)
			cache.last_fetched_at = now_ms()
			ui.display(bufnr, manifest_key)
		end)
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
			return on_failure()
		end
		local cmd = cmds[idx]
		idx = idx + 1
		job:new({
			command = cmd[1],
			args = list_slice(cmd, 2),
			cwd = cwd,
			on_exit = function(j, code)
				schedule(function()
					local raw = j:result()
					if code ~= 0 then
						raw = j:stderr_result()
					end
					if raw and #raw > 0 then
						local parsed = safe_parse_json(table.concat(raw, "\n"))
						if type(parsed) == "table" and next(parsed) then
							local filtered = {}
							for name, info in pairs(parsed) do
								if scalar_deps[name] then
									filtered[name] = info
								end
							end
							if next(filtered) then
								return on_success(filtered)
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

-- -------------------------
-- main check function
-- -------------------------
function M.check_manifest_outdated(bufnr, manifest_key)
	bufnr = bufnr or api.nvim_get_current_buf()
	if bufnr == -1 then
		return
	end

	local filename = api.nvim_buf_get_name(bufnr) or ""
	local basename = fn.fnamemodify(filename, ":t")

	manifest_key = manifest_key
		or state.get_manifest_key_from_filename(basename)
		or (basename == "package.json" and "package")
		or (basename == "Cargo.toml" and "crates")
		or (basename == "pubspec.yaml" and "pubspec")
		or (basename == "composer.json" and "composer")
		or manifest_key
	if not manifest_key then
		return
	end

	local deps_state = state.get_dependencies(manifest_key)
	local installed_table = deps_state.installed or {}
	local scalar_deps = {}
	local go_fetch_names = nil

	for name, info in pairs(installed_table) do
		local cur = nil
		if type(info) == "table" then
			cur = info.current
		elseif type(info) == "string" then
			cur = info
		end
		if cur and cur ~= "" then
			if manifest_key == "composer" then
				if is_packagist_candidate(name) then
					scalar_deps[name] = true
				end
			else
				scalar_deps[name] = true
			end

			if manifest_key == "go" then
				go_fetch_names = go_fetch_names or {}
				go_fetch_names[name] = go_module_path_for_version(name, cur)
			end
		end
	end

	if tbl_isempty(scalar_deps) then
		schedule(function()
			state.set_outdated(manifest_key, {})
		end)
		return
	end

	local cwd = utils.get_buffer_dir(bufnr) or fn.getcwd()

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}
	state.buffers[bufnr].is_loading = true

	schedule(function()
		ui.display(bufnr, manifest_key)
	end)

	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil, last_fetched_at = nil }
	local cache = versions_cache[manifest_key][bufnr]

	local now = now_ms()
	if
		cache.last_fetched_at
		and config.performance.cache_ttl_ms
		and config.performance.cache_ttl_ms > 0
		and (now - cache.last_fetched_at) < config.performance.cache_ttl_ms
	then
		schedule(function()
			state.set_outdated(manifest_key, state.get_dependencies(manifest_key).outdated or {})
			ui.display(bufnr, manifest_key)
		end)
		state.buffers[bufnr].is_loading = false
		return
	end

	if not (cache and cache.watchdog) then
		local ok_new, t = pcall(vim.loop.new_timer)
		if ok_new and t then
			local started_ok, start_err = pcall(function()
				t:start(
					config.network.overall_watchdog_ms,
					0,
					vim.schedule_wrap(function()
						if bufnr and state.buffers and state.buffers[bufnr] and state.buffers[bufnr].is_loading then
							state.buffers[bufnr].is_loading = false
							schedule(function()
								state.set_outdated(manifest_key, {})
							end)
							schedule(function()
								ui.display(bufnr, manifest_key)
							end)
						end

						pcall(function()
							t:stop()
						end)
						pcall(function()
							t:close()
						end)

						if versions_cache[manifest_key] and versions_cache[manifest_key][bufnr] then
							versions_cache[manifest_key][bufnr].watchdog = nil
						end
					end)
				)
			end)

			if started_ok then
				versions_cache[manifest_key] = versions_cache[manifest_key] or {}
				versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr] or {}
				versions_cache[manifest_key][bufnr].watchdog = t
			else
				pcall(function()
					t:close()
				end)
				utils.notify_safe(
					fmt(
						"Failed to start watchdog for %s (buf=%s): %s",
						tostring(manifest_key),
						tostring(bufnr),
						tostring(start_err)
					),
					L.WARN
				)
			end
		end
	end

	local names_to_fetch = {}
	for name in pairs(scalar_deps) do
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
		state.buffers[bufnr].is_loading = false
		schedule(function()
			state.set_outdated(manifest_key, {})
			ui.display(bufnr, manifest_key)
		end)
		return
	end

	if use_cli_fallback and not fetcher then
		local cmds = {}
		if has_flutter then
			cmds[#cmds + 1] = { "flutter", "pub", "outdated", "--format=json" }
			cmds[#cmds + 1] = { "flutter", "pub", "outdated", "--json" }
			cmds[#cmds + 1] = { "flutter", "pub", "outdated" }
		end
		if has_dart then
			cmds[#cmds + 1] = { "dart", "pub", "outdated", "--format=json" }
			cmds[#cmds + 1] = { "dart", "pub", "outdated", "--json" }
			cmds[#cmds + 1] = { "dart", "pub", "outdated" }
		end

		if #cmds == 0 then
			state.buffers[bufnr].is_loading = false
			schedule(function()
				state.set_outdated(manifest_key, {})
				ui.display(bufnr, manifest_key)
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

			schedule(function()
				local c2 = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
				if c2 then
					c2.last_changed = api.nvim_buf_get_changedtick(bufnr)
				end
				if c2 and c2.watchdog then
					stop_watchdog(c2.watchdog)
					c2.watchdog = nil
				end
				if state.buffers and state.buffers[bufnr] then
					state.buffers[bufnr].is_loading = false
				end
				schedule_publish(bufnr, manifest_key)
			end)
		end, function()
			local c = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
			if c and c.watchdog then
				stop_watchdog(c.watchdog)
				c.watchdog = nil
			end
			if state.buffers and state.buffers[bufnr] then
				state.buffers[bufnr].is_loading = false
			end
			schedule(function()
				state.set_outdated(manifest_key, {})
				ui.display(bufnr, manifest_key)
			end)
		end)

		return
	end

	local in_flight, idx, total = 0, 1, #names_to_fetch

	local function finish_phase_if_done()
		if idx > total and in_flight == 0 then
			schedule(function()
				local c2 = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
				if c2 then
					c2.last_changed = api.nvim_buf_get_changedtick(bufnr)
				end
				if c2 and c2.watchdog then
					stop_watchdog(c2.watchdog)
					c2.watchdog = nil
				end
				if state.buffers and state.buffers[bufnr] then
					state.buffers[bufnr].is_loading = false
				end
				schedule_publish(bufnr, manifest_key)
			end)
		end
	end

	local function try_next()
		while in_flight < concurrency and idx <= total do
			local name = names_to_fetch[idx]
			idx = idx + 1
			in_flight = in_flight + 1

			local fetch_name = name
			if manifest_key == "go" and go_fetch_names and go_fetch_names[name] then
				fetch_name = go_fetch_names[name]
			end

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
				finish_phase_if_done()
			end

			local on_error = function(err)
				in_flight = in_flight - 1
				utils.notify_safe(fmt("Error fetching %s: %s", fetch_name, tostring(err)), L.ERROR)
				local c = versions_cache[manifest_key] and versions_cache[manifest_key][bufnr]
				if c and c.data then
					c.data[name] = nil
				end
				add_pending_result(bufnr, name, nil, manifest_key)
				try_next()
				finish_phase_if_done()
			end

			fetcher(fetch_name, on_success, on_error)
		end
	end

	try_next()
end

-- -------------------------
-- cache clear
-- -------------------------
function M.clear_cache(bufnr, manifest_key)
	if manifest_key then
		local entry = versions_cache[manifest_key]
		if entry and entry[bufnr] and entry[bufnr].watchdog then
			stop_watchdog(entry[bufnr].watchdog)
		end
		if bufnr then
			entry[bufnr] = nil
		else
			versions_cache[manifest_key] = nil
		end
	else
		for mk, tbl in pairs(versions_cache) do
			for b, rec in pairs(tbl) do
				if bufnr and b == bufnr and rec.watchdog then
					stop_watchdog(rec.watchdog)
				end
				if bufnr then
					tbl[b] = nil
				else
					versions_cache[mk] = nil
				end
			end
		end
	end
end

-- -------------------------
-- invalidate cache for specific package
-- -------------------------
function M.invalidate_package_cache(bufnr, manifest_key, package_name)
	if not bufnr or not manifest_key or not package_name then
		return
	end

	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	local cache = versions_cache[manifest_key][bufnr]

	if not cache then
		return
	end

	if cache.data and cache.data[package_name] then
		cache.data[package_name] = nil
	end

	if cache.pending and cache.pending[package_name] then
		cache.pending[package_name] = nil
	end

	-- Clear negative cache for this package
	clear_negative_cache(manifest_key, package_name)

	cache.last_fetched_at = nil
end

-- -------------------------
-- invalidate cache for multiple packages
-- -------------------------
function M.invalidate_packages_cache(bufnr, manifest_key, package_names)
	if not package_names or type(package_names) ~= "table" then
		return
	end

	for _, name in ipairs(package_names) do
		M.invalidate_package_cache(bufnr, manifest_key, name)
	end
end

return M
