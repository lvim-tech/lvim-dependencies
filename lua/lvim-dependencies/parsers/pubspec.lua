local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local M = {}

local function trim(s)
	if not s then
		return s
	end
	return s:match("^%s*(.-)%s*$")
end

local function strip_quotes(s)
	if not s then
		return s
	end
	return s:gsub("^%s*[\"'](.-)[\"']%s*$", "%1")
end

local function is_top_level_line(line)
	if not line then
		return false
	end
	return line:match("^%S.*:$") ~= nil
end

local function parse_section_fallback(lines, start_idx)
	local result = {}
	local n = #lines

	for i = start_idx + 1, n do
		local line = lines[i]
		if not line then
			break
		end

		if is_top_level_line(line) then
			return result, i - 1
		end

		if line:match("^%s*$") or line:match("^%s*#") then
			-- skip blank or comment lines
		else
			local name, val = line:match("^%s*([^:%s]+)%s*:%s*(.-)%s*$")
			if name then
				if val then
					val = val:gsub("%s*#.*$", "")
					val = trim(val)
					val = strip_quotes(val)
				end

				local raw = val
				local current = nil

				if not raw or raw == "" or raw:match("^%{") or raw:match("^%[") then
					local nested_version = nil
					local this_indent = line:match("^(%s*)") or ""
					for j = i + 1, math.min(n, i + 8) do
						local child = lines[j]
						if not child then
							break
						end
						local child_indent = child:match("^(%s*)") or ""
						if #child_indent <= #this_indent then
							break
						end
						local v = child:match("^%s*version%s*:%s*(.-)%s*$")
						if v then
							v = v:gsub("%s*#.*$", "")
							v = trim(v)
							v = strip_quotes(v)
							if v ~= "" then
								nested_version = v
								break
							end
						end
					end
					if nested_version and nested_version ~= "" then
						raw = nested_version
						current = clean_version(raw) or tostring(raw)
					else
						raw = ""
						current = nil
					end
				else
					current = clean_version(raw) or tostring(raw or "")
				end

				result[name] = { raw = raw, current = current }
			end
		end
	end

	return result, n
end

local function parse_with_decoder(content, lines)
	local ok, yaml_parsed = pcall(function()
		return decoder.parse_yaml(content)
	end)
	if ok and yaml_parsed and type(yaml_parsed) == "table" then
		local deps = {}
		local dev_deps = {}
		local overrides = {}

		local raw_deps = yaml_parsed["dependencies"] or yaml_parsed["dependency_overrides"] or yaml_parsed["deps"]
		local raw_dev = yaml_parsed["dev_dependencies"] or yaml_parsed["devDependencies"] or yaml_parsed["dev-dependencies"]
		local raw_overrides = yaml_parsed["dependency_overrides"] or yaml_parsed["overrides"]

		local function normalize_entry_val(val)
			if type(val) == "string" then
				local s = strip_quotes(trim(val))
				return s, (s ~= "")
			elseif type(val) == "table" then
				if val.version and type(val.version) == "string" then
					local s = strip_quotes(trim(val.version))
					return s, (s ~= "")
				end

				if #val >= 1 and type(val[1]) == "string" then
					local s = strip_quotes(trim(val[1]))
					return s, (s ~= "")
				end

				return "", false
			else
				return "", false
			end
		end

		if raw_deps and type(raw_deps) == "table" then
			for name, val in pairs(raw_deps) do
				local raw, has_scalar = normalize_entry_val(val)
				local current = nil
				if has_scalar then
					current = clean_version(raw) or tostring(raw or "")
				end
				deps[name] = { raw = raw, current = current }
			end
		end

		if raw_dev and type(raw_dev) == "table" then
			for name, val in pairs(raw_dev) do
				local raw, has_scalar = normalize_entry_val(val)
				local current = nil
				if has_scalar then
					current = clean_version(raw) or tostring(raw or "")
				end
				dev_deps[name] = { raw = raw, current = current }
			end
		end

		if raw_overrides and type(raw_overrides) == "table" then
			for name, val in pairs(raw_overrides) do
				local raw, has_scalar = normalize_entry_val(val)
				local current = nil
				if has_scalar then
					current = clean_version(raw) or tostring(raw or "")
				end
				overrides[name] = { raw = raw, current = current }
			end
		end

		return deps, dev_deps, overrides
	end

	local deps = {}
	local dev_deps = {}
	local overrides = {}
	local i = 1
	local n = #lines
	while i <= n do
		local line = lines[i]
		if line and line:match("^%s*dependencies%s*:%s*$") then
			local section, last = parse_section_fallback(lines, i)
			if section then
				for k, v in pairs(section) do
					deps[k] = v
				end
			end
			i = last
		elseif line and line:match("^%s*dev_dependencies%s*:%s*$") then
			local section, last = parse_section_fallback(lines, i)
			if section then
				for k, v in pairs(section) do
					dev_deps[k] = v
				end
			end
			i = last
		elseif line and line:match("^%s*dependency_overrides%s*:%s*$") then
			local section, last = parse_section_fallback(lines, i)
			if section then
				for k, v in pairs(section) do
					overrides[k] = v
				end
			end
			i = last
		else
			i = i + 1
		end
	end

	return deps, dev_deps, overrides
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(buffer_lines, "\n")

	local deps, dev_deps, overrides = parse_with_decoder(content, buffer_lines)

	local installed_dependencies = {}
	local invalid_dependencies = {}

	local function add_to_installed(tbl, source)
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

	add_to_installed(deps, "dependencies")
	add_to_installed(dev_deps, "dev_dependencies")
	add_to_installed(overrides, "dependency_overrides")

	if state.save_buffer then
		state.save_buffer(bufnr, "pubspec", vim.api.nvim_buf_get_name(bufnr), buffer_lines)
	end

	-- prefer to NOT mutate state.ensure_manifest; just call if available
	if state.ensure_manifest then
		state.ensure_manifest("pubspec")
	end

	if state.set_installed then
		state.set_installed("pubspec", installed_dependencies)
	end
	if state.set_invalid then
		state.set_invalid("pubspec", invalid_dependencies)
	end
	if state.set_outdated then
		state.set_outdated("pubspec", state.get_dependencies("pubspec").outdated or {})
	end

	if state.update_buffer_lines then
		state.update_buffer_lines(bufnr, buffer_lines)
	end
	if state.update_last_run then
		state.update_last_run(bufnr)
	end

	pcall(function()
		local bufn = bufnr
		state.buffers = state.buffers or {}
		state.buffers[bufn] = state.buffers[bufn] or {}
		local last_check = state.buffers[bufn].last_pubspec_check or 0
		local now = vim.loop.now()

		if now - last_check < 1500 then
			return
		end
		state.buffers[bufn].last_pubspec_check = now
		vim.defer_fn(function()
			local ok_unified, unified = pcall(require, "lvim-dependencies.actions.check_manifests")
			if ok_unified and unified and type(unified.check_manifest_outdated) == "function" then
				pcall(function()
					unified.check_manifest_outdated(bufn, "pubspec")
				end)
			end
		end, 150)
	end)

	return {
		installed = installed_dependencies,
		invalid = invalid_dependencies,
	}
end

return M
