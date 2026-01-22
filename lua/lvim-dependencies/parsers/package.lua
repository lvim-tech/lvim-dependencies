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

local function parse_fallback_lines(lines)
	local deps = {}
	local dev = {}
	local in_deps, in_dev = false, false

	for _, line in ipairs(lines) do
		local l = trim(line)

		if l:match('^"dependencies"%s*:%s*{') then
			in_deps = true
			in_dev = false
			goto continue
		end
		if l:match('^"devDependencies"%s*:%s*{') or l:match('^"devdependencies"%s*:%s*{') then
			in_dev = true
			in_deps = false
			goto continue
		end

		if in_deps and l:match("^}%s*,?$") then
			in_deps = false
			goto continue
		end
		if in_dev and l:match("^}%s*,?$") then
			in_dev = false
			goto continue
		end

		if in_deps or in_dev then
			local name, val = l:match('^"([^"]+)"%s*:%s*"(.-)"%s*,?$')
			if name and val then
				if in_deps then
					deps[name] = val
				end
				if in_dev then
					dev[name] = val
				end
			else
				local name2 = l:match('^"([^"]+)"%s*:%s*{')
				if name2 then
					if in_deps then
						deps[name2] = nil
					end
					if in_dev then
						dev[name2] = nil
					end
				end
			end
		end

		::continue::
	end

	return deps, dev
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(buffer_lines, "\n")

	local installed_dependencies = {}
	local invalid_dependencies = {}

	local ok_parse, parsed = pcall(function()
		return decoder.parse_json(content)
	end)
	if ok_parse and parsed and type(parsed) == "table" then
		local raw_deps = parsed["dependencies"] or {}
		local raw_dev = parsed["devDependencies"] or parsed["dev-dependencies"] or parsed["devdependencies"] or {}

		local function normalize_and_add(tbl, source)
			for name, val in pairs(tbl or {}) do
				if type(val) == "string" then
					local raw = trim(val)
					local cleaned = clean_version(raw)
					installed_dependencies[name] = {
						current = cleaned or tostring(raw or ""),
						raw = raw,
						_source = source,
					}
				else
					installed_dependencies[name] = {
						current = nil,
						raw = "",
						_source = source,
					}
				end
			end
		end

		normalize_and_add(raw_deps, "dependencies")
		normalize_and_add(raw_dev, "dev_dependencies")
	else
		local deps, dev = parse_fallback_lines(buffer_lines)
		local function add_from_tbl(tbl, source)
			for name, val in pairs(tbl or {}) do
				if val and type(val) == "string" then
					local raw = trim(val)
					local cleaned = clean_version(raw)
					installed_dependencies[name] = {
						current = cleaned or tostring(raw or ""),
						raw = raw,
						_source = source,
					}
				else
					installed_dependencies[name] = {
						current = nil,
						raw = "",
						_source = source,
					}
				end
			end
		end
		add_from_tbl(deps, "dependencies")
		add_from_tbl(dev, "dev_dependencies")
	end

	if state.save_buffer then
		state.save_buffer(bufnr, "package", vim.api.nvim_buf_get_name(bufnr), buffer_lines)
	end

	-- prefer to NOT mutate state.ensure_manifest; just call if available
	if state.ensure_manifest then
		state.ensure_manifest("package")
	end

	if state.set_installed then
		state.set_installed("package", installed_dependencies)
	end
	if state.set_invalid then
		state.set_invalid("package", invalid_dependencies)
	end
	if state.set_outdated then
		state.set_outdated("package", state.get_dependencies("package").outdated or {})
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
		local last_check = state.buffers[bufn].last_package_check or 0
		local now = vim.loop.now()

		if now - last_check < 1500 then
			return
		end
		state.buffers[bufn].last_package_check = now
		vim.defer_fn(function()
			local ok_unified, unified = pcall(require, "lvim-dependencies.actions.check_manifests")
			if ok_unified and unified and type(unified.check_manifest_outdated) == "function" then
				pcall(function()
					unified.check_manifest_outdated(bufn, "package")
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
