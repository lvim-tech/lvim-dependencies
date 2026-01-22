local M = {}

local api = vim.api
local fn = vim.fn
local fmt = string.format
local notify = vim.notify
local job = require("plenary.job")
local curl = require("plenary.curl")
local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local fs = require("lvim-dependencies.utils.fs")

local L = vim.log.levels

local BASE_PUB_URI = "https://pub.dartlang.org/api"
local BASE_CRATES_URI = "https://crates.io/api/v1/crates"
local BASE_NPM_URI = "https://registry.npmjs.org"

local PUBLISH_DEBOUNCE_MS = 120
local PER_REQUEST_TIMEOUT_MS = 10000
local OVERALL_WATCHDOG_MS = 30000

-- versions_cache organized by manifest_key -> bufnr -> cache
-- cache: { last_changed, data = {name->{latest}}, pending = {name->{latest}}, publish_timer, watchdog }
local versions_cache = {}

--
-- Utilities: version parsing/comparison and cleaning
--
local function to_version(str)
	if not str then
		return { 0, 0, 0 }
	end
	local s = tostring(str):gsub("%^", "")
	local parts = vim.tbl_map(tonumber, vim.split(s, ".", { plain = true }))
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
	return utils.clean_version and utils.clean_version(v) or v
end

--
-- Extract latest helpers (pub.dev fallback regex)
--
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

--
-- Fetchers for different registries. They follow same signature:
--   fetcher(name, on_success(latest_or_nil), on_error(err_string_or_nil))
--

local function fetch_pub_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	curl.get({
		url = fmt("%s/packages/%s", BASE_PUB_URI, name),
		timeout = PER_REQUEST_TIMEOUT_MS / 1000,
		callback = function(response)
			if not response then
				return on_error("no response")
			end
			if response.status ~= 200 then
				return on_error(fmt("HTTP %d for %s", response.status, name))
			end
			local latest = extract_latest_from_pub_body(response.body)
			if not latest then
				latest = parse_pubdev_latest_slow(response.body)
			end
			on_success(latest and clean(latest) or nil)
		end,
	})
end

local function fetch_crates_async(name, on_success, on_error)
	if not name then
		return on_error("missing name")
	end
	curl.get({
		url = fmt("%s/%s", BASE_CRATES_URI, name),
		timeout = PER_REQUEST_TIMEOUT_MS / 1000,
		callback = function(response)
			if not response then
				return on_error("no response")
			end
			if response.status ~= 200 then
				return on_error(fmt("HTTP %d for %s", response.status, name))
			end
			local ok, parsed = pcall(function()
				return decoder.parse_json(response.body)
			end)
			if ok and type(parsed) == "table" then
				if parsed.crate and parsed.crate.max_stable_version then
					return on_success(clean(parsed.crate.max_stable_version))
				end
				if parsed.crate and parsed.crate.max_version then
					return on_success(clean(parsed.crate.max_version))
				end
				if parsed.versions and type(parsed.versions) == "table" and parsed.versions[1] and parsed.versions[1].num then
					return on_success(clean(parsed.versions[1].num))
				end
			end
			-- fallback: try regex for max_stable_version or max_version
			local v = response.body:match('"max_stable_version"%s*:%s*"(.-)"') or response.body:match('"max_version"%s*:%s*"(.-)"')
			if v and v ~= "" then
				return on_success(clean(v))
			end
			return on_success(nil)
		end,
	})
end

local function url_encode_npm(name)
	-- minimal encoding for scoped packages: @scope/name -> %40scope%2Fname
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
	curl.get({
		url = fmt("%s/%s", BASE_NPM_URI, enc),
		timeout = PER_REQUEST_TIMEOUT_MS / 1000,
		callback = function(response)
			if not response then
				return on_error("no response")
			end
			if response.status ~= 200 then
				return on_error(fmt("HTTP %d for %s", response.status, name))
			end
			local ok, parsed = pcall(function()
				return decoder.parse_json(response.body)
			end)
			if ok and type(parsed) == "table" then
				if parsed["dist-tags"] and parsed["dist-tags"].latest then
					return on_success(clean(parsed["dist-tags"].latest))
				end
			end
			-- fallback regex
			local m = response.body:match('"dist%-tags"%s*:%s*{.-"latest"%s*:%s*"(.-)"')
			if m and m ~= "" then
				return on_success(clean(m))
			end
			return on_success(nil)
		end,
	})
end

local FETCHERS = {
	pubspec = fetch_pub_async,
	crates = fetch_crates_async,
	package = fetch_npm_async,
}

--
-- schedule_publish / add_pending_result now accept manifest_key
-- schedule_publish aggregates pending -> data, builds `final` using state.get_dependencies(manifest_key)
-- then calls state.set_outdated(manifest_key, final) and ui.display(bufnr, manifest_key)
--
local function schedule_publish(bufnr, manifest_key)
	manifest_key = manifest_key or "pubspec"
	if not bufnr then
		return
	end

	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil }

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
					end
				end

				final[name] = { current = installed_table[name] and installed_table[name].current or nil, latest = info.latest }
			end
			::continue_entry::
		end

		if type(state.set_outdated) == "function" then
			vim.schedule(function()
				pcall(state.set_outdated, manifest_key, final)

				pcall(function()
					local ok, ui = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok and ui and type(ui.display) == "function" then
						pcall(ui.display, bufnr, manifest_key)
					end
				end)
			end)
		end
	end, PUBLISH_DEBOUNCE_MS)
end

local function add_pending_result(bufnr, name, latest, manifest_key)
	manifest_key = manifest_key or "pubspec"
	if not bufnr then
		return
	end
	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil }

	local cache = versions_cache[manifest_key][bufnr]
	cache.pending = cache.pending or {}
	cache.pending[name] = { latest = latest }
	schedule_publish(bufnr, manifest_key)
end

--
-- try_cli_commands_async unchanged but calls on_success/on_failure as before
--
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
						local ok, parsed = pcall(function()
							return decoder.parse_json(table.concat(raw, "\n"))
						end)
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

--
-- Generic check function for any manifest_key. It limits concurrency and uses the appropriate fetcher.
-- It mirrors the previous pubspec behavior but is generalized.
--
function M.check_manifest_outdated(bufnr, manifest_key)
	bufnr = bufnr or api.nvim_get_current_buf()
	if bufnr == -1 then
		return
	end

	-- manifest discovery: prefer state.get_manifest_key_from_filename if provided
	local filename = api.nvim_buf_get_name(bufnr) or ""
	local basename = fn.fnamemodify(filename, ":t")
	manifest_key = manifest_key
		or (state.get_manifest_key_from_filename and state.get_manifest_key_from_filename(basename))
		or (basename == "package.json" and "package")
		or (basename == "Cargo.toml" and "crates")
		or (basename == "pubspec.yaml" and "pubspec")
		or manifest_key
	if not manifest_key then
		-- unknown manifest, nothing to do
		return
	end

	local deps_state = state.get_dependencies and state.get_dependencies(manifest_key) or {}
	local installed_table = deps_state and deps_state.installed or {}
	local scalar_deps = {}
	for name, info in pairs(installed_table) do
		if info and info.current and info.current ~= "" then
			scalar_deps[name] = true
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

	-- determine working directory from buffer if possible, fallback to cwd
	local cwd = (fs and fs.get_buffer_dir and fs.get_buffer_dir(bufnr)) or fn.getcwd()

	-- mark loading and show UI immediately
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

	-- ensure cache for this manifest/buffer
	versions_cache[manifest_key] = versions_cache[manifest_key] or {}
	versions_cache[manifest_key][bufnr] = versions_cache[manifest_key][bufnr]
		or { last_changed = 0, data = {}, pending = {}, publish_timer = nil, watchdog = nil }
	local cache = versions_cache[manifest_key][bufnr]

	-- watchdog as before (keeps same semantics)
	if not (cache and cache.watchdog) then
		local t = nil
		local ok_new, maybe_t = pcall(function()
			return vim.loop.new_timer()
		end)
		if ok_new and maybe_t then
			t = maybe_t
			local started_ok = pcall(function()
				t:start(
					OVERALL_WATCHDOG_MS,
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
			end, OVERALL_WATCHDOG_MS)
		end
	end

	-- build names list
	local names_to_fetch = {}
	for name, _ in pairs(scalar_deps) do
		names_to_fetch[#names_to_fetch + 1] = name
	end

	-- concurrency heuristics reused from original
	local n = #names_to_fetch
	local BASE_CONCURRENCY = 6
	local MAX_CONCURRENCY = 8
	local concurrency = math.min(MAX_CONCURRENCY, math.max(1, math.floor(n / 6) + 1, BASE_CONCURRENCY))
	if n > 80 then
		concurrency = 1
	elseif n > 30 then
		concurrency = math.min(concurrency, 2)
	end

	-- pick fetcher for this manifest_key and decide CLI fallback properly
	local fetcher = FETCHERS[manifest_key]
	local has_flutter = (fn.executable("flutter") == 1)
	local has_dart = (fn.executable("dart") == 1)
	local use_cli_fallback = (not fetcher) and (has_flutter or has_dart)

	-- If no fetcher and no CLI fallback, just clear loading and display empty
	if not fetcher and not use_cli_fallback then
		-- nothing can fetch versions for this manifest
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

	-- If we will use CLI fallback, run it once and process results
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
			-- unlikely, but guard
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
			-- success: parsed_cli is table of name->info
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
			-- finalize
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
			-- failure
			if versions_cache[manifest_key] and versions_cache[manifest_key][bufnr] and versions_cache[manifest_key][bufnr].watchdog then
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

	-- Otherwise use registry fetcher with limited concurrency
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

				-- finalize if done
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
				notify(fmt("Error fetching %s: %s", name, tostring(err)), L.ERROR)
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

			-- call fetcher protected
			pcall(function()
				fetcher(name, on_success, on_error)
			end)
		end
	end

	-- start
	try_next()
end

-- clear cache optionally by manifest_key and/or bufnr
function M.clear_cache(bufnr, manifest_key)
	if manifest_key then
		if versions_cache[manifest_key] and versions_cache[manifest_key][bufnr] and versions_cache[manifest_key][bufnr].watchdog then
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
		-- clear all manifests for this buffer
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

-- compatibility wrapper for original name
function M.check_pubspec_outdated(bufnr)
	return M.check_manifest_outdated(bufnr, "pubspec")
end

return M
