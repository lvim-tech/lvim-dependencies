local api = vim.api
local fn = vim.fn
local schedule = vim.schedule
local defer_fn = vim.defer_fn
local split = vim.split
local table_concat = table.concat
local tostring = tostring

local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local vt = require("lvim-dependencies.ui.virtual_text")
local checker = require("lvim-dependencies.actions.check_manifests")

local M = {}

-- ------------------------------------------------------------
-- Lock parse cache (per lock_path + mtime + size)
-- ------------------------------------------------------------
local lock_cache = {
	-- [lock_path] = { mtime=..., size=..., versions=table }
}

-- ------------------------------------------------------------
-- Lock parsing
-- ------------------------------------------------------------
local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	local ok, parsed = pcall(decoder.parse_json, content)
	if not ok or type(parsed) ~= "table" then
		return nil
	end

	local versions = {}
	local function collect(tbl)
		if type(tbl) ~= "table" then
			return
		end
		for _, pkg in ipairs(tbl) do
			if type(pkg) == "table" and pkg.name and pkg.version then
				versions[pkg.name] = tostring(pkg.version)
			end
		end
	end

	collect(parsed.packages)
	collect(parsed["packages-dev"])

	if next(versions) ~= nil then
		return versions
	end
	return nil
end

local function get_lock_versions(lock_path)
	if not lock_path then
		return nil
	end

	local content, mtime, size = utils.read_file_cached(lock_path)
	if content == nil then
		lock_cache[lock_path] = nil
		return nil
	end

	local cached = lock_cache[lock_path]
	if cached and cached.mtime == mtime and cached.size == size and type(cached.versions) == "table" then
		return cached.versions
	end

	local versions = parse_lock_file_from_content(content)
	lock_cache[lock_path] = { mtime = mtime, size = size, versions = versions }
	return versions
end

-- ------------------------------------------------------------
-- Composer parsing helpers
-- ------------------------------------------------------------
local function is_platform_dependency(name)
	if not name or name == "" then
		return true
	end
	if name == "php" then
		return true
	end
	if name:match("^ext%-") or name:match("^lib%-") then
		return true
	end
	if not name:find("/", 1, true) then
		return true
	end
	return false
end

local function strip_comments_and_trim(s)
	if not s then
		return nil
	end
	local t = s:gsub("//.*$", ""):gsub("/%*.-%*/", ""):gsub(",%s*$", ""):match("^%s*(.-)%s*$")
	if t == "" then
		return nil
	end
	return t
end

local function collect_block(start_idx, lines)
	local tbl = {}
	local brace_level = 0
	local started = false
	local last_idx = start_idx

	for i = start_idx, #lines do
		local raw = lines[i]
		local line = strip_comments_and_trim(raw)
		if not line then
			last_idx = i
		else
			if not started and line:find("{", 1, true) then
				started = true
			end

			for c in line:gmatch(".") do
				if c == "{" then
					brace_level = brace_level + 1
				elseif c == "}" then
					brace_level = brace_level - 1
				end
			end

			for name, ver in line:gmatch('%s*"(.-)"%s*:%s*"(.-)"%s*,?') do
				if name and ver then
					tbl[name] = ver
				end
			end

			last_idx = i
			if started and brace_level <= 0 then
				break
			end
		end
	end

	return tbl, last_idx
end

local function parse_composer_fallback_lines(lines)
	if type(lines) ~= "table" then
		return {}, {}
	end

	local req = {}
	local reqdev = {}

	local i = 1
	while i <= #lines do
		local raw = lines[i]
		if raw ~= nil then
			local lower = raw:lower()
			if lower:match('%s*"?require"?%s*:') then
				local parsed, last = collect_block(i, lines)
				for k, v in pairs(parsed) do
					if not is_platform_dependency(k) then
						req[k] = v
					end
				end
				if last and last > i then
					i = last
				end
			elseif lower:match('%s*"?require%-dev"?%s*:') then
				local parsed, last = collect_block(i, lines)
				for k, v in pairs(parsed) do
					if not is_platform_dependency(k) then
						reqdev[k] = v
					end
				end
				if last and last > i then
					i = last
				end
			end
		end
		i = i + 1
	end

	return req, reqdev
end

local function normalize_dep_map(raw_tbl)
	local out = {}
	if type(raw_tbl) ~= "table" then
		return out
	end
	for name, val in pairs(raw_tbl) do
		if not is_platform_dependency(name) then
			local raw = (type(val) == "string") and val or tostring(val)
			local cur = clean_version(raw) or tostring(raw)
			out[name] = { raw = raw, current = cur }
		end
	end
	return out
end

local function parse_with_decoder(content, lines)
	local ok, parsed = pcall(decoder.parse_json, content)
	if ok and type(parsed) == "table" then
		local req = parsed.require or {}
		local reqdev = parsed["require-dev"] or {}
		return {
			require = normalize_dep_map(req),
			require_dev = normalize_dep_map(reqdev),
		}
	end

	local fb_req, fb_reqdev = parse_composer_fallback_lines(lines or split(content, "\n"))
	return {
		require = normalize_dep_map(fb_req),
		require_dev = normalize_dep_map(fb_reqdev),
	}
end

local function apply_lock_versions(parsed, lock_versions)
	if not lock_versions or type(lock_versions) ~= "table" then
		return
	end
	for name, info in pairs(parsed.require or {}) do
		if lock_versions[name] then
			info.current = lock_versions[name]
			info.in_lock = true
		else
			info.in_lock = false
		end
	end
	for name, info in pairs(parsed.require_dev or {}) do
		if lock_versions[name] then
			info.current = lock_versions[name]
			info.in_lock = true
		else
			info.in_lock = false
		end
	end
end

-- ------------------------------------------------------------
-- Parse + state update
-- ------------------------------------------------------------
local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	parsed_tables = parsed_tables or {}

	local req = parsed_tables.require or {}
	local reqdev = parsed_tables.require_dev or {}

	local installed_dependencies = {}
	local invalid_dependencies = {}

	local function add(tbl, source)
		for name, info in pairs(tbl or {}) do
			if installed_dependencies[name] then
				invalid_dependencies[name] = { diagnostic = "DUPLICATED" }
			end
			installed_dependencies[name] = {
				current = info.current,
				raw = info.raw,
				in_lock = info.in_lock,
				_source = source,
			}
		end
	end

	add(req, "require")
	add(reqdev, "require-dev")

	schedule(function()
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			state.save_buffer(bufnr, "composer", api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		state.ensure_manifest("composer")
		state.clear_manifest("composer")

		-- UNIVERSAL INSTALLED SHAPE
		local bulk = {}
		for name, info in pairs(installed_dependencies) do
			local scope = info._source or "require"
			bulk[name] = {
				current = info.current,
				raw = info.raw,
				in_lock = info.in_lock == true,
				scopes = { [scope] = true },
			}
		end
		state.set_installed("composer", bulk)

		state.set_invalid("composer", invalid_dependencies)
		state.set_outdated("composer", state.get_dependencies("composer").outdated or {})

		state.update_buffer_lines(bufnr, buffer_lines)
		state.update_last_run(bufnr)

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_composer_parsed =
			{ installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		state.buffers[bufnr].last_composer_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		vt.display(bufnr, "composer")
		checker.check_manifest_outdated(bufnr, "composer")
	end)
end

-- ------------------------------------------------------------
-- Public API
-- ------------------------------------------------------------
M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_composer_parsed then
			defer_fn(function()
				vt.display(bufnr, "composer")
			end, 10)
			return state.buffers[bufnr].last_composer_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_composer_hash and state.buffers[bufnr].last_composer_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_composer_parsed then
			defer_fn(function()
				vt.display(bufnr, "composer")
			end, 10)
			return state.buffers[bufnr].last_composer_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_composer_parsed
	end

	state.buffers[bufnr].parse_scheduled = true

	defer_fn(function()
		if not api.nvim_buf_is_valid(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		local fresh_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table_concat(fresh_lines, "\n")

		local ok_decode, parsed = pcall(parse_with_decoder, fresh_content, fresh_lines)
		if not (ok_decode and parsed) then
			local fb_req, fb_reqdev = parse_composer_fallback_lines(fresh_lines)
			parsed = {
				require = normalize_dep_map(fb_req),
				require_dev = normalize_dep_map(fb_reqdev),
			}
		end

		local lock_path = utils.find_lock_for_manifest(bufnr, "composer")
		local lock_versions = lock_path and get_lock_versions(lock_path) or nil
		apply_lock_versions(parsed, lock_versions)

		do_parse_and_update(bufnr, parsed, fresh_lines, fresh_content)
	end, 20)

	return state.buffers[bufnr].last_composer_parsed
end

M.parse_lock_file_content = parse_lock_file_from_content

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "composer.json"
M.manifest_key = "composer"

return M
