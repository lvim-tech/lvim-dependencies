local api = vim.api

local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local L = vim.log.levels

local M = {}

local function urlencode_module(str)
	if not str then
		return ""
	end
	str = tostring(str)
	return (str:gsub("([^%w%-._~/])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_go_mod_path()
	local cwd = vim.fn.getcwd()
	local manifest_files = const.MANIFEST_FILES.go or { "go.mod" }

	while true do
		for _, filename in ipairs(manifest_files) do
			local candidate = cwd .. "/" .. filename
			if vim.fn.filereadable(candidate) == 1 then
				return candidate
			end
		end

		local parent = vim.fn.fnamemodify(cwd, ":h")
		if parent == cwd or parent == "" then
			break
		end
		cwd = parent
	end
	return nil
end

local function read_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return nil
	end
	return lines
end

local function write_lines(path, lines)
	local ok, err = pcall(vim.fn.writefile, lines, path)
	if not ok then
		return false, tostring(err)
	end
	return true
end

local function parse_version(v)
	if not v then
		return nil
	end
	v = tostring(v)
	-- Handle Go version formats: v1.2.3, v0.0.0-20231201120000-abc123456789
	local major, minor, patch = v:match("^v?(%d+)%.(%d+)%.(%d+)")
	if major and minor and patch then
		return { tonumber(major), tonumber(minor), tonumber(patch) }
	end
	return nil
end

local function compare_versions(a, b)
	local pa = parse_version(a)
	local pb = parse_version(b)

	if not pa and not pb then
		return 0
	end
	if not pa then
		return -1
	end
	if not pb then
		return 1
	end

	for i = 1, 3 do
		local ai = pa[i] or 0
		local bi = pb[i] or 0
		if ai > bi then
			return 1
		end
		if ai < bi then
			return -1
		end
	end
	return 0
end

function M.fetch_versions(name, _)
	if not name or name == "" then
		return nil
	end

	local current = nil
	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.get_installed_version) == "function" then
		current = state.get_installed_version("go", name)
	end

	local encoded_name = urlencode_module(name)
	local url = ("https://proxy.golang.org/%s/@v/list"):format(encoded_name)

	local ok_http, body = pcall(function()
		return vim.fn.system({ "curl", "-fsS", "--max-time", "10", url })
	end)

	if not ok_http or not body or body == "" then
		return nil
	end

	-- Parse version list (one per line)
	local versions = {}
	for line in body:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			table.insert(versions, trimmed)
		end
	end

	if #versions == 0 then
		return nil
	end

	-- Sort versions (newest first)
	table.sort(versions, function(a, b)
		local cmp = compare_versions(a, b)
		if cmp == 0 then
			return a > b
		end
		return cmp == 1
	end)

	return { versions = versions, current = current }
end

local function find_require_block(lines)
	local start_idx, end_idx = nil, nil
	local in_require = false

	for i, line in ipairs(lines) do
		-- Single-line require
		if line:match("^require%s+") and not line:match("^require%s*%(") then
			return nil, nil -- Single-line format, not block
		end

		-- Multi-line require block start
		if line:match("^require%s*%(") then
			start_idx = i
			in_require = true
		end

		-- End of require block
		if in_require and line:match("^%)") then
			end_idx = i
			break
		end
	end

	return start_idx, end_idx
end

local function find_module_in_require(lines, start_idx, end_idx, module_name)
	if not start_idx or not end_idx then
		return nil
	end

	for i = start_idx + 1, end_idx - 1 do
		local line = lines[i]
		-- Match: module_name v1.2.3
		local mod, ver = line:match("^%s*([^%s]+)%s+([^%s]+)")
		if mod and tostring(mod) == tostring(module_name) then
			return i, ver
		end
	end

	return nil, nil
end

local function refresh_buffer(path, fresh_lines)
	local bufnr = vim.fn.bufnr(path)
	if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
		return
	end

	local cur_buf = api.nvim_get_current_buf()
	local cur_win = api.nvim_get_current_win()
	local saved_cursor = nil

	if cur_buf == bufnr then
		saved_cursor = api.nvim_win_get_cursor(cur_win)
	end

	---@diagnostic disable-next-line: deprecated
	pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, fresh_lines)

	if saved_cursor then
		pcall(api.nvim_win_set_cursor, cur_win, saved_cursor)
	end

	---@diagnostic disable-next-line: deprecated
	pcall(api.nvim_buf_set_option, bufnr, "modified", false)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.get_updating) == "function" then
		local is_updating = state.get_updating()
		if is_updating then
			return
		end
	end

	pcall(function()
		local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
		if ok_vt and type(vt.display) == "function" then
			pcall(vt.display, bufnr)
		end
	end)
end

local function run_go_get(path, name, version)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("go") == 0 then
		utils.notify_safe("go CLI not found", L.ERROR, {})
		return
	end

	local pkg_spec = version and (name .. "@" .. version) or name
	local cmd = { "go", "get", pkg_spec }

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.set_updating) == "function" then
		pcall(state.set_updating, true)
	end

	local out, err = {}, {}

	vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data, _)
			if data then
				for _, ln in ipairs(data) do
					out[#out + 1] = ln
				end
			end
		end,
		on_stderr = function(_, data, _)
			if data then
				for _, ln in ipairs(data) do
					err[#err + 1] = ln
				end
			end
		end,
		on_exit = function(_, code, _)
			vim.schedule(function()
				if code == 0 then
					utils.notify_safe(("%s@%s installed"):format(name, tostring(version)), L.INFO, {})

					-- Run go mod tidy to clean up
					vim.fn.jobstart({ "go", "mod", "tidy" }, {
						cwd = cwd,
						on_exit = function(_, _, _)
							vim.schedule(function()
								local fresh_lines = read_lines(path)
								if fresh_lines then
									refresh_buffer(path, fresh_lines)
								end

								if name and version then
									local ok_st, st = pcall(require, "lvim-dependencies.state")
									if ok_st and type(st.add_installed_dependency) == "function" then
										pcall(st.add_installed_dependency, "go", name, version, "require")
									end

									vim.defer_fn(function()
										local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.go")
										if ok_parser and type(parser.parse_buffer) == "function" then
											local buf = vim.fn.bufnr(path)
											if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
												local ok_s, s = pcall(require, "lvim-dependencies.state")
												if ok_s and type(s.set_updating) == "function" then
													pcall(s.set_updating, false)
												end

												pcall(parser.parse_buffer, buf)

												vim.defer_fn(function()
													local ok_chk, chk =
														pcall(require, "lvim-dependencies.actions.check_manifests")

													if ok_chk and type(chk.invalidate_package_cache) == "function" then
														pcall(chk.invalidate_package_cache, buf, "go", name)
													end

													if ok_chk and type(chk.check_manifest_outdated) == "function" then
														pcall(chk.check_manifest_outdated, buf, "go")
													end
												end, 300)
											end
										end
									end, 1500)

									pcall(function()
										vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
										---@diagnostic disable-next-line: deprecated
										vim.api.nvim_exec("doautocmd User LvimDepsPackageUpdated", false)
									end)
								end
							end)
						end,
					})
				else
					local ok_s, s = pcall(require, "lvim-dependencies.state")
					if ok_s and type(s.set_updating) == "function" then
						pcall(s.set_updating, false)
					end

					local msg = table.concat(err, "\n")
					if msg == "" then
						msg = "go get exited with code " .. tostring(code)
					end
					utils.notify_safe(("go get failed: %s"):format(msg), L.ERROR, {})
				end
			end)
		end,
	})
end

local function run_go_remove(path, name)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("go") == 0 then
		utils.notify_safe("go CLI not found", L.ERROR, {})
		return
	end

	-- Remove from go.mod manually, then run go mod tidy
	local lines = read_lines(path)
	if not lines then
		utils.notify_safe("unable to read go.mod", L.ERROR, {})
		return
	end

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.set_updating) == "function" then
		pcall(state.set_updating, true)
	end

	local start_idx, end_idx = find_require_block(lines)
	if not start_idx or not end_idx then
		utils.notify_safe("require block not found in go.mod", L.ERROR, {})
		local ok_s, s = pcall(require, "lvim-dependencies.state")
		if ok_s and type(s.set_updating) == "function" then
			pcall(s.set_updating, false)
		end
		return
	end

	local mod_idx, _ = find_module_in_require(lines, start_idx, end_idx, name)
	if not mod_idx then
		utils.notify_safe(("module %s not found in go.mod"):format(name), L.WARN, {})
		local ok_s, s = pcall(require, "lvim-dependencies.state")
		if ok_s and type(s.set_updating) == "function" then
			pcall(s.set_updating, false)
		end
		return
	end

	-- Remove the line
	local new_lines = {}
	for i, line in ipairs(lines) do
		if i ~= mod_idx then
			table.insert(new_lines, line)
		end
	end

	local ok_write, werr = write_lines(path, new_lines)
	if not ok_write then
		utils.notify_safe(("failed to write go.mod: %s"):format(tostring(werr)), L.ERROR, {})
		local ok_s, s = pcall(require, "lvim-dependencies.state")
		if ok_s and type(s.set_updating) == "function" then
			pcall(s.set_updating, false)
		end
		return
	end

	-- Run go mod tidy
	vim.fn.jobstart({ "go", "mod", "tidy" }, {
		cwd = cwd,
		on_exit = function(_, code, _)
			vim.schedule(function()
				if code == 0 then
					utils.notify_safe(("%s removed"):format(name), L.INFO, {})

					local fresh_lines = read_lines(path)
					if fresh_lines then
						refresh_buffer(path, fresh_lines)
					end

					local ok_st, st = pcall(require, "lvim-dependencies.state")
					if ok_st and type(st.remove_installed_dependency) == "function" then
						pcall(st.remove_installed_dependency, "go", name)
					end

					vim.defer_fn(function()
						local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.go")
						if ok_parser and type(parser.parse_buffer) == "function" then
							local buf = vim.fn.bufnr(path)
							if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
								local ok_s, s = pcall(require, "lvim-dependencies.state")
								if ok_s and type(s.set_updating) == "function" then
									pcall(s.set_updating, false)
								end

								pcall(parser.parse_buffer, buf)

								vim.defer_fn(function()
									local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")

									if ok_chk and type(chk.invalidate_package_cache) == "function" then
										pcall(chk.invalidate_package_cache, buf, "go", name)
									end

									if ok_chk and type(chk.check_manifest_outdated) == "function" then
										pcall(chk.check_manifest_outdated, buf, "go")
									end
								end, 300)
							end
						end
					end, 1500)

					pcall(function()
						vim.g.lvim_deps_last_updated = name .. "@removed"
						---@diagnostic disable-next-line: deprecated
						vim.api.nvim_exec("doautocmd User LvimDepsPackageUpdated", false)
					end)
				else
					local ok_s, s = pcall(require, "lvim-dependencies.state")
					if ok_s and type(s.set_updating) == "function" then
						pcall(s.set_updating, false)
					end
					utils.notify_safe("go mod tidy failed after removal", L.ERROR, {})
				end
			end)
		end,
	})
end

function M.update(name, opts)
	if not name or name == "" then
		return { ok = false, msg = "module name required" }
	end
	opts = opts or {}
	local version = opts.version
	if not version or version == "" then
		return { ok = false, msg = "version is required" }
	end

	local path = find_go_mod_path()
	if not path then
		return { ok = false, msg = "go.mod not found in project tree" }
	end

	if opts.from_ui then
		utils.notify_safe(("updating %s to %s..."):format(name, tostring(version)), L.INFO, {})
		run_go_get(path, name, version)
		return { ok = true, msg = "started" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read go.mod" }
	end

	local start_idx, end_idx = find_require_block(lines)
	if not start_idx or not end_idx then
		return { ok = false, msg = "require block not found in go.mod" }
	end

	local mod_idx, _ = find_module_in_require(lines, start_idx, end_idx, name)

	local new_line = string.format("\t%s %s", name, version)

	if mod_idx then
		-- Replace existing
		lines[mod_idx] = new_line
	else
		-- Insert new (before closing paren)
		table.insert(lines, end_idx, new_line)
	end

	local ok_write, werr = write_lines(path, lines)
	if not ok_write then
		return { ok = false, msg = "failed to write go.mod: " .. tostring(werr) }
	end

	refresh_buffer(path, lines)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.add_installed_dependency) == "function" then
		pcall(state.add_installed_dependency, "go", name, version, "require")
	end

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
		---@diagnostic disable-next-line: deprecated
		vim.api.nvim_exec("doautocmd User LvimDepsPackageUpdated", false)
	end)

	utils.notify_safe(("%s -> %s"):format(name, tostring(version)), L.INFO, {})

	return { ok = true, msg = "written" }
end

function M.add(_, _)
	return { ok = true }
end

function M.delete(name, opts)
	if not name or name == "" then
		return { ok = false, msg = "module name required" }
	end
	opts = opts or {}

	local path = find_go_mod_path()
	if not path then
		return { ok = false, msg = "go.mod not found in project tree" }
	end

	if opts.from_ui then
		run_go_remove(path, name)
		utils.notify_safe(("removing %s..."):format(name), L.INFO, {})
		return { ok = true, msg = "started" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read go.mod" }
	end

	local start_idx, end_idx = find_require_block(lines)
	if not start_idx or not end_idx then
		return { ok = false, msg = "require block not found in go.mod" }
	end

	local mod_idx, _ = find_module_in_require(lines, start_idx, end_idx, name)
	if not mod_idx then
		return { ok = false, msg = "module " .. name .. " not found in require block" }
	end

	-- Remove the line
	local new_lines = {}
	for i, line in ipairs(lines) do
		if i ~= mod_idx then
			table.insert(new_lines, line)
		end
	end

	local ok_write, werr = write_lines(path, new_lines)
	if not ok_write then
		return { ok = false, msg = "failed to write go.mod: " .. tostring(werr) }
	end

	refresh_buffer(path, new_lines)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.remove_installed_dependency) == "function" then
		pcall(state.remove_installed_dependency, "go", name)
	end

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@removed"
		---@diagnostic disable-next-line: deprecated
		vim.api.nvim_exec("doautocmd User LvimDepsPackageUpdated", false)
	end)

	utils.notify_safe(("%s removed"):format(name), L.INFO, {})

	return { ok = true, msg = "removed" }
end

function M.install(_)
	return { ok = true }
end

function M.check_outdated(_)
	return { ok = true }
end

return M
