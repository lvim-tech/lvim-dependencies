local api = vim.api
local fn = vim.fn
local schedule = vim.schedule
local defer_fn = vim.defer_fn
local split = vim.split
local table_concat = table.concat
local tostring = tostring

local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local vt = require("lvim-dependencies.ui.virtual_text")
local checker = require("lvim-dependencies.actions.check_manifests")

local M = {}

local lock_cache = {}

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

local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	local versions = {}
	local lines = split(content, "\n")
	for _, ln in ipairs(lines) do
		local name, ver = ln:match("^%s*([^%s]+)%s+([^%s]+)%s+")
		if name and ver then
			local clean_ver = tostring(ver):gsub("/go%.mod$", "")

			if not versions[name] then
				versions[name] = clean_ver
			else
				local existing = versions[name]
				local cmp = compare_versions(clean_ver, existing)
				if cmp == 1 then
					versions[name] = clean_ver
				end
			end
		end
	end

	if next(versions) then
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

local function strip_comments_and_trim(s)
	if not s then
		return nil
	end
	local t = s:gsub("//.*$", ""):gsub(",%s*$", ""):match("^%s*(.-)%s*$")
	if t == "" then
		return nil
	end
	return t
end

local function parse_go_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}
	end

	local deps = {}

	local function add_dep(name, ver)
		if not name or name == "" then
			return
		end
		if name:find("/", 1, true) == nil then
			return
		end
		local raw = tostring(ver or ""):gsub("/go%.mod$", "")
		local cur = clean_version(raw) or raw
		deps[name] = { raw = raw, current = cur }
	end

	local in_require_block = false
	for i = 1, #lines do
		local raw = lines[i]
		local line = strip_comments_and_trim(raw)
		if not line then
			-- skip
		else
			if line:match("^%s*require%s*%(%s*$") then
				in_require_block = true
			elseif in_require_block then
				if line:match("^%s*%)%s*$") then
					in_require_block = false
				else
					local name, ver = line:match("^%s*([^%s]+)%s+([^%s]+)")
					if name and ver then
						add_dep(name, ver)
					end
				end
			else
				local name, ver = line:match("^%s*require%s+([^%s]+)%s+([^%s]+)")
				if name and ver then
					add_dep(name, ver)
				else
					local n, v = line:match("^%s*([^%s]+)%s+([^%s]+)")
					if n and v and n:match("%/") then
						add_dep(n, v)
					end
				end
			end
		end
	end

	return deps
end

local function parse_with_decoder(content, lines)
	return { require = parse_go_fallback_lines(lines or split(content, "\n")) }
end

local function is_update_loading(bufnr)
	return state.buffers
		and state.buffers[bufnr]
		and state.buffers[bufnr].is_loading == true
		and state.buffers[bufnr].pending_dep ~= nil
end

local function is_checking_single_package(bufnr)
	return state.buffers and state.buffers[bufnr] and state.buffers[bufnr].checking_single_package ~= nil
end

local function guarded_display(bufnr, manifest_key)
	if is_update_loading(bufnr) then
		return
	end
	vt.display(bufnr, manifest_key)
end

local function guarded_check_outdated(bufnr, manifest_key)
	if is_update_loading(bufnr) then
		return
	end
	checker.check_manifest_outdated(bufnr, manifest_key)
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	parsed_tables = parsed_tables or {}

	local req = parsed_tables.require or {}

	local installed_dependencies = {}
	local invalid_dependencies = {}

	for name, info in pairs(req or {}) do
		if installed_dependencies[name] then
			invalid_dependencies[name] = { diagnostic = "DUPLICATED" }
		end
		installed_dependencies[name] = {
			current = info.current,
			raw = info.raw,
			in_lock = info.in_lock,
			_source = "require",
		}
	end

	schedule(function()
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			state.save_buffer(bufnr, "go", api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		state.ensure_manifest("go")
		state.clear_manifest("go")

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
		state.set_installed("go", bulk)

		state.set_invalid("go", invalid_dependencies)
		state.set_outdated("go", state.get_dependencies("go").outdated or {})

		state.update_buffer_lines(bufnr, buffer_lines)
		state.update_last_run(bufnr)

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_go_parsed = { installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		state.buffers[bufnr].last_go_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		-- Don't display or check if we're in the middle of a single package update
		if not is_checking_single_package(bufnr) then
			guarded_display(bufnr, "go")
			guarded_check_outdated(bufnr, "go")
		end
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	-- Skip full parse if we're checking a single package (after update)
	if is_checking_single_package(bufnr) then
		return state.buffers[bufnr].last_go_parsed
	end

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_go_parsed then
			defer_fn(function()
				guarded_display(bufnr, "go")
			end, 10)
			return state.buffers[bufnr].last_go_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_go_hash and state.buffers[bufnr].last_go_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_go_parsed then
			defer_fn(function()
				guarded_display(bufnr, "go")
			end, 10)
			return state.buffers[bufnr].last_go_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_go_parsed
	end

	state.buffers[bufnr].parse_scheduled = true

	defer_fn(function()
		if not api.nvim_buf_is_valid(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		-- Skip if checking single package
		if is_checking_single_package(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		local fresh_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table_concat(fresh_lines, "\n")

		local parsed = parse_with_decoder(fresh_content, fresh_lines)

		local lock_path = utils.find_lock_for_manifest(bufnr, "go")
		local lock_versions = lock_path and get_lock_versions(lock_path) or nil

		local function apply_lock(tbl)
			for name, info in pairs(tbl or {}) do
				if lock_versions and lock_versions[name] then
					info.current = lock_versions[name]
					info.in_lock = true
				else
					info.in_lock = false
				end
			end
		end

		apply_lock(parsed.require)

		do_parse_and_update(bufnr, parsed, fresh_lines, fresh_content)
	end, 20)

	return state.buffers[bufnr].last_go_parsed
end

M.parse_lock_file_content = parse_lock_file_from_content

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "go.mod"
M.manifest_key = "go"

return M
