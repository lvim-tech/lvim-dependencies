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

-- Try to extract versions from a go.sum-like lock content
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
				-- prefer non-go.mod entries over go.mod ones
				if tostring(versions[name]):match("/go%.mod$") and clean_ver then
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
		-- skip non-module lines
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
	-- keep a simple contract: return table with require=...
	return { require = parse_go_fallback_lines(lines or split(content, "\n")) }
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
			_source = "require",
		}
	end

	schedule(function()
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end

		-- save buffer meta
		state.save_buffer(bufnr, "go", api.nvim_buf_get_name(bufnr), buffer_lines)

		-- prefer set_installed API; fallback to set_dependencies if present
		if state.set_installed then
			state.set_installed("go", installed_dependencies)
		elseif state.set_dependencies then
			local result = {
				lines = buffer_lines,
				installed = installed_dependencies,
				outdated = {},
				invalid = invalid_dependencies,
			}
			state.set_dependencies("go", result)
		end

		-- invalids and outdated placeholder
		if state.set_invalid then state.set_invalid("go", invalid_dependencies) end
		if state.set_outdated then state.set_outdated("go", state.get_dependencies("go").outdated or {}) end

		-- update buffer cached lines/last run metadata
		if state.update_buffer_lines then state.update_buffer_lines(bufnr, buffer_lines) end
		if state.update_last_run then state.update_last_run(bufnr) end

		-- attach last parsed snapshot to buffer for caching
		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_go_parsed = { installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		-- compute and store hash
		state.buffers[bufnr].last_go_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		-- render virtual text and trigger checker
		vt.display(bufnr, "go")
		checker.check_manifest_outdated(bufnr, "go")
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_go_parsed then
			defer_fn(function()
				vt.display(bufnr, "go")
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
				vt.display(bufnr, "go")
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

		local fresh_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table_concat(fresh_lines, "\n")

		local parsed = parse_with_decoder(fresh_content, fresh_lines)

		local lock_path = utils.find_lock_for_manifest(bufnr, "go")
		local lock_versions = nil
		if lock_path then
			local lock_content = utils.read_file(lock_path)
			lock_versions = parse_lock_file_from_content(lock_content)
		end

		if lock_versions and type(lock_versions) == "table" and parsed then
			for name, info in pairs(parsed.require or {}) do
				if lock_versions[name] then
					info.current = lock_versions[name]
				end
			end
		end

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
