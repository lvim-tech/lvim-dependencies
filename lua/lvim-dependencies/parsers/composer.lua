local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local M = {}

local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end
	local ok, parsed = pcall(function()
		return decoder.parse_json(content)
	end)
	if not ok or type(parsed) ~= "table" then
		return nil
	end

	local versions = {}

	local function collect(tbl)
		if not tbl or type(tbl) ~= "table" then
			return
		end
		for _, pkg in ipairs(tbl) do
			if pkg and type(pkg) == "table" and pkg.name and pkg.version then
				versions[pkg.name] = tostring(pkg.version)
			end
		end
	end

	collect(parsed.packages)
	collect(parsed["packages-dev"])

	return versions
end

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

local function parse_composer_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}
	end

	local function strip_comments_and_trim(s)
		if not s then
			return nil
		end

		local t = s:gsub("//.*$", "")

		t = t:gsub("/%*.-%*/", "")

		t = t:gsub(",%s*$", ""):match("^%s*(.-)%s*$")
		if t == "" then
			return nil
		end
		return t
	end

	local function collect_block(start_idx)
		local tbl = {}
		local brace_level = 0
		local started = false
		local last_idx = start_idx

		for i = start_idx, #lines do
			local raw_line = lines[i]
			local line = strip_comments_and_trim(raw_line)
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

	local req = {}
	local reqdev = {}
	local i = 1
	while i <= #lines do
		local raw = lines[i]
		if raw ~= nil then
			local lower = raw:lower()
			if lower:match('%s*"?require"?%s*:') then
				local parsed, last = collect_block(i)
				for k, v in pairs(parsed) do
					if not is_platform_dependency(k) then
						req[k] = v
					end
				end
				if last and last > i then
					i = last
				end
			elseif lower:match('%s*"?require%-dev"?%s*:') then
				local parsed, last = collect_block(i)
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

local function parse_with_decoder(content, lines)
	local ok, parsed = pcall(function()
		if decoder and type(decoder.parse_json) == "function" then
			return decoder.parse_json(content)
		end
		return vim.fn.json_decode(content)
	end)

	if ok and parsed and type(parsed) == "table" then
		local req = parsed.require or {}
		local reqdev = parsed["require-dev"] or {}
		local deps = {}
		local dev_deps = {}

		if req and type(req) == "table" then
			for name, val in pairs(req) do
				if not is_platform_dependency(name) then
					local raw = nil
					if type(val) == "string" then
						raw = val
					else
						raw = tostring(val)
					end
					local cur = clean_version(raw) or tostring(raw)
					deps[name] = { raw = raw, current = cur }
				end
			end
		end

		if reqdev and type(reqdev) == "table" then
			for name, val in pairs(reqdev) do
				if not is_platform_dependency(name) then
					local raw = nil
					if type(val) == "string" then
						raw = val
					else
						raw = tostring(val)
					end
					local cur = clean_version(raw) or tostring(raw)
					dev_deps[name] = { raw = raw, current = cur }
				end
			end
		end

		return { require = deps, require_dev = dev_deps }
	end

	local fb_req, fb_reqdev = parse_composer_fallback_lines(lines or vim.split(content, "\n"))
	local deps = {}
	local dev_deps = {}
	for k, v in pairs(fb_req) do
		if not is_platform_dependency(k) then
			deps[k] = { raw = v, current = clean_version(v) or tostring(v) }
		end
	end
	for k, v in pairs(fb_reqdev) do
		if not is_platform_dependency(k) then
			dev_deps[k] = { raw = v, current = clean_version(v) or tostring(v) }
		end
	end

	return { require = deps, require_dev = dev_deps }
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not vim.api.nvim_buf_is_valid(bufnr) then
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
				_source = source,
			}
		end
	end

	add(req, "require")
	add(reqdev, "require-dev")

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			pcall(state.save_buffer, bufnr, "composer", vim.api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		if state.set_installed then
			pcall(state.set_installed, "composer", installed_dependencies)
		elseif state.set_dependencies and type(state.set_dependencies) == "function" then
			local result = {
				lines = buffer_lines,
				installed = installed_dependencies,
				outdated = {},
				invalid = invalid_dependencies,
			}
			pcall(state.set_dependencies, "composer", result)
		end

		if state.set_invalid then
			pcall(state.set_invalid, "composer", invalid_dependencies)
		end
		if state.set_outdated then
			pcall(state.set_outdated, "composer", state.get_dependencies("composer").outdated or {})
		end

		if state.update_buffer_lines then
			pcall(state.update_buffer_lines, bufnr, buffer_lines)
		end
		if state.update_last_run then
			pcall(state.update_last_run, bufnr)
		end

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_composer_parsed =
			{ installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false
		local ok_hash, h = pcall(function()
			return vim.fn.sha256(content)
		end)
		if ok_hash then
			state.buffers[bufnr].last_composer_hash = h
		end
		state.buffers[bufnr].last_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

		pcall(function()
			local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
			if ok_vt and vt and type(vt.display) == "function" then
				vt.display(bufnr, "composer")
			end
		end)

		pcall(function()
			local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
			if ok_chk and chk and type(chk.check_manifest_outdated) == "function" then
				pcall(chk.check_manifest_outdated, bufnr, "composer")
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
		if state.buffers[bufnr].last_composer_parsed then
			vim.defer_fn(function()
				pcall(function()
					local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok_vt and vt and type(vt.display) == "function" then
						vt.display(bufnr, "composer")
					end
				end)
			end, 10)
			return state.buffers[bufnr].last_composer_parsed
		end
	end

	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(buffer_lines, "\n")

	local ok_hash, current_hash = pcall(function()
		return vim.fn.sha256(content)
	end)
	if
		ok_hash
		and state.buffers[bufnr].last_composer_hash
		and state.buffers[bufnr].last_composer_hash == current_hash
	then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_composer_parsed then
			vim.defer_fn(function()
				pcall(function()
					local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok_vt and vt and type(vt.display) == "function" then
						vt.display(bufnr, "composer")
					end
				end)
			end, 10)
			return state.buffers[bufnr].last_composer_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_composer_parsed
	end

	state.buffers[bufnr].parse_scheduled = true

	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		local fresh_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table.concat(fresh_lines, "\n")

		local ok_decode, parsed = pcall(function()
			return parse_with_decoder(fresh_content, fresh_lines)
		end)
		if ok_decode and parsed then
			local lock_path = utils.find_lock_for_manifest(bufnr, "composer")
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
				for name, info in pairs(parsed.require_dev or {}) do
					if lock_versions[name] then
						info.current = lock_versions[name]
					end
				end
			end

			do_parse_and_update(bufnr, parsed, fresh_lines, fresh_content)
		else
			local fb_req, fb_reqdev = parse_composer_fallback_lines(fresh_lines)
			local conv = { require = fb_req or {}, require_dev = fb_reqdev or {} }

			local lock_path = utils.find_lock_for_manifest(bufnr, "composer")
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
				for name in pairs(conv.require_dev or {}) do
					if lock_versions[name] then
						conv.require_dev[name].current = lock_versions[name]
					end
				end
			end

			do_parse_and_update(bufnr, conv, fresh_lines, fresh_content)
		end
	end, 20)

	return state.buffers[bufnr].last_composer_parsed
end

M.parse_lock_file_content = function(content)
	return parse_lock_file_from_content(content)
end

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "composer.json"
M.manifest_key = "composer"

return M
