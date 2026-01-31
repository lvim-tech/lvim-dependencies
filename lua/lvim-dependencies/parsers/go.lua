local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local M = {}

local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	local versions = {}
	for _, ln in ipairs(vim.split(content, "\n")) do
		local name, ver = ln:match("^%s*([^%s]+)%s+([^%s]+)%s+")
		if name and ver then
			local clean_ver = tostring(ver):gsub("/go.mod$", "")

			if not versions[name] then
				versions[name] = clean_ver
			else
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

	local t = s:gsub("//.*$", "")
	t = t:gsub(",%s*$", ""):match("^%s*(.-)%s*$")
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
		local raw = tostring(ver or "")

		raw = raw:gsub("/go.mod$", "")
		local cur = clean_version(raw) or raw
		deps[name] = { raw = raw, current = cur }
	end

	local i = 1
	local in_require_block = false
	while i <= #lines do
		local raw = lines[i]
		local line = strip_comments_and_trim(raw)
		if not line then
			i = i + 1
		else
			if line:match("^%s*require%s*%(%s*$") then
				in_require_block = true
				i = i + 1
			elseif in_require_block then
				if line:match("^%s*%)%s*$") then
					in_require_block = false
					i = i + 1
				else
					local name, ver = line:match("^%s*([^%s]+)%s+([^%s]+)")
					if name and ver then
						add_dep(name, ver)
					end
					i = i + 1
				end
			else
				local name, ver = line:match("^%s*require%s+([^%s]+)%s+([^%s]+)")
				if name and ver then
					add_dep(name, ver)
					i = i + 1
				else
					local n, v = line:match("^%s*([^%s]+)%s+([^%s]+)")
					if n and v and line:match("%/") then
						add_dep(n, v)
					end
					i = i + 1
				end
			end
		end
	end

	return deps
end

local function parse_with_decoder(content, lines)
	return { require = parse_go_fallback_lines(lines or vim.split(content, "\n")) }
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not vim.api.nvim_buf_is_valid(bufnr) then
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

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			pcall(state.save_buffer, bufnr, "go", vim.api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		if state.set_installed then
			pcall(state.set_installed, "go", installed_dependencies)
		elseif state.set_dependencies and type(state.set_dependencies) == "function" then
			local result = {
				lines = buffer_lines,
				installed = installed_dependencies,
				outdated = {},
				invalid = invalid_dependencies,
			}
			pcall(state.set_dependencies, "go", result)
		end

		if state.set_invalid then
			pcall(state.set_invalid, "go", invalid_dependencies)
		end
		if state.set_outdated then
			pcall(state.set_outdated, "go", state.get_dependencies("go").outdated or {})
		end

		if state.update_buffer_lines then
			pcall(state.update_buffer_lines, bufnr, buffer_lines)
		end
		if state.update_last_run then
			pcall(state.update_last_run, bufnr)
		end

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_go_parsed = { installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		local ok_hash, h = pcall(function()
			return vim.fn.sha256(content)
		end)
		if ok_hash then
			state.buffers[bufnr].last_go_hash = h
		end
		state.buffers[bufnr].last_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

		pcall(function()
			local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
			if ok_vt and vt and type(vt.display) == "function" then
				vt.display(bufnr, "go")
			end
		end)

		pcall(function()
			local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
			if ok_chk and chk and type(chk.check_manifest_outdated) == "function" then
				pcall(chk.check_manifest_outdated, bufnr, "go")
			end
		end)
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_go_parsed then
			vim.defer_fn(function()
				pcall(function()
					local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok_vt and vt and type(vt.display) == "function" then
						vt.display(bufnr, "go")
					end
				end)
			end, 10)
			return state.buffers[bufnr].last_go_parsed
		end
	end

	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(buffer_lines, "\n")

	local ok_hash, current_hash = pcall(function()
		return vim.fn.sha256(content)
	end)
	if ok_hash and state.buffers[bufnr].last_go_hash and state.buffers[bufnr].last_go_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_go_parsed then
			vim.defer_fn(function()
				pcall(function()
					local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok_vt and vt and type(vt.display) == "function" then
						vt.display(bufnr, "go")
					end
				end)
			end, 10)
			return state.buffers[bufnr].last_go_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_go_parsed
	end

	state.buffers[bufnr].parse_scheduled = true

	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		local fresh_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table.concat(fresh_lines, "\n")

		local parsed = nil
		local ok_parse = pcall(function()
			local p = parse_with_decoder(fresh_content, fresh_lines)
			parsed = p
		end)

		if ok_parse and parsed then
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
		else
			local fb = parse_go_fallback_lines(fresh_lines)
			local conv = { require = fb or {} }

			local lock_path = utils.find_lock_for_manifest(bufnr, "go")
			local lock_versions = nil
			if lock_path then
				local lock_content = utils.read_file(lock_path)
				lock_versions = parse_lock_file_from_content(lock_content)
			end
			if lock_versions and type(lock_versions) == "table" then
				for name in pairs(conv.require or {}) do
					if lock_versions[name] then
						conv.require[name].current = lock_versions[name]
					end
				end
			end

			do_parse_and_update(bufnr, conv, fresh_lines, fresh_content)
		end
	end, 20)

	return state.buffers[bufnr].last_go_parsed
end

M.parse_lock_file_content = function(content)
	return parse_lock_file_from_content(content)
end

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "go.mod"
M.manifest_key = "go"

return M
