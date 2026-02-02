local api = vim.api

local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local L = vim.log.levels

local M = {}

local function urlencode(str)
	if not str then
		return ""
	end
	str = tostring(str)
	return (str:gsub("[^%w%-._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_cargo_toml_path()
	local cwd = vim.fn.getcwd()
	local manifest_files = const.MANIFEST_FILES.cargo or { "Cargo.toml" }

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
	-- Remove Cargo version constraints (^, ~, >=, etc.)
	v = v:gsub("^[%^~><=]+", "")
	-- Remove quotes
	v = v:gsub("[\"']", "")
	-- Extract semantic version
	local major, minor, patch = v:match("^(%d+)%.(%d+)%.(%d+)")
	if major and minor and patch then
		return { tonumber(major), tonumber(minor), tonumber(patch) }
	end
	local maj_min = v:match("^(%d+)%.(%d+)")
	if maj_min then
		local ma, mi = v:match("^(%d+)%.(%d+)")
		return { tonumber(ma), tonumber(mi), 0 }
	end
	local single = v:match("^(%d+)")
	if single then
		return { tonumber(single), 0, 0 }
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
		current = state.get_installed_version("cargo", name)
	end

	-- crates.io API endpoint
	local encoded_name = urlencode(name)
	local url = ("https://crates.io/api/v1/crates/%s"):format(encoded_name)

	local ok_http, body = pcall(function()
		return vim.fn.system({ "curl", "-fsS", "--max-time", "10", "-H", "User-Agent: lvim-dependencies", url })
	end)

	if not ok_http or not body or body == "" then
		return nil
	end

	local ok_json, parsed = pcall(vim.fn.json_decode, body)
	if not ok_json or type(parsed) ~= "table" then
		return nil
	end

	-- Extract versions from crate.versions array
	local crate_data = parsed.crate
	if not crate_data or type(crate_data) ~= "table" then
		return nil
	end

	local versions_data = parsed.versions
	if not versions_data or type(versions_data) ~= "table" then
		return nil
	end

	local versions = {}
	for _, entry in ipairs(versions_data) do
		if type(entry) == "table" and entry.num then
			local ver = tostring(entry.num)
			local yanked = entry.yanked or false
			-- Skip yanked versions
			if not yanked then
				table.insert(versions, ver)
			end
		end
	end

	if #versions == 0 then
		return nil
	end

	-- Remove duplicates
	local seen = {}
	local unique = {}
	for _, v in ipairs(versions) do
		if not seen[v] then
			seen[v] = true
			table.insert(unique, v)
		end
	end

	-- Sort versions (newest first)
	table.sort(unique, function(a, b)
		local cmp = compare_versions(a, b)
		if cmp == 0 then
			return a > b
		end
		return cmp == 1
	end)

	return { versions = unique, current = current }
end

local function find_section_index(lines, section_name)
	for i, ln in ipairs(lines) do
		if ln:match("^%[" .. vim.pesc(section_name) .. "%]") then
			return i
		end
	end
	return nil
end

local function find_section_end(lines, section_idx)
	local section_end = #lines
	for i = section_idx + 1, #lines do
		local ln = lines[i]
		-- Next section starts
		if ln:match("^%[") then
			section_end = i - 1
			break
		end
	end
	return section_end
end

local function find_dependency_in_section(lines, section_idx, section_end, pkg_name)
	for i = section_idx + 1, section_end do
		local ln = lines[i]
		-- Match: package_name = "version" or package_name = { version = "..." }
		local name = ln:match("^([%w%-%_]+)%s*=")
		if name and tostring(name) == tostring(pkg_name) then
			return i
		end
	end
	return nil
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

	-- Refresh virtual text
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

local function run_cargo_add(path, name, version, scope)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("cargo") == 0 then
		utils.notify_safe("cargo not found", L.ERROR, {})
		return
	end

	local cmd
	local pkg_spec = version and (name .. "@" .. version) or name

	if scope == "dev-dependencies" then
		cmd = { "cargo", "add", "--dev", pkg_spec }
	elseif scope == "build-dependencies" then
		cmd = { "cargo", "add", "--build", pkg_spec }
	else
		cmd = { "cargo", "add", pkg_spec }
	end

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

					local fresh_lines = read_lines(path)
					if fresh_lines then
						refresh_buffer(path, fresh_lines)
					end

					if name and version and scope then
						local ok_st, st = pcall(require, "lvim-dependencies.state")
						if ok_st and type(st.add_installed_dependency) == "function" then
							pcall(st.add_installed_dependency, "cargo", name, version, scope)
						end

						vim.defer_fn(function()
							local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.cargo")
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
											pcall(chk.invalidate_package_cache, buf, "cargo", name)
										end

										if ok_chk and type(chk.check_manifest_outdated) == "function" then
											pcall(chk.check_manifest_outdated, buf, "cargo")
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
				else
					local ok_s, s = pcall(require, "lvim-dependencies.state")
					if ok_s and type(s.set_updating) == "function" then
						pcall(s.set_updating, false)
					end

					local msg = table.concat(err, "\n")
					if msg == "" then
						msg = "cargo add exited with code " .. tostring(code)
					end
					utils.notify_safe(("cargo add failed: %s"):format(msg), L.ERROR, {})
				end
			end)
		end,
	})
end

local function run_cargo_remove(path, name)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("cargo") == 0 then
		utils.notify_safe("cargo not found", L.ERROR, {})
		return
	end

	local cmd = { "cargo", "remove", name }

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
					utils.notify_safe(("%s removed"):format(name), L.INFO, {})

					local fresh_lines = read_lines(path)
					if fresh_lines then
						refresh_buffer(path, fresh_lines)
					end

					local ok_st, st = pcall(require, "lvim-dependencies.state")
					if ok_st and type(st.remove_installed_dependency) == "function" then
						pcall(st.remove_installed_dependency, "cargo", name)
					end

					vim.defer_fn(function()
						local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.cargo")
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
										pcall(chk.invalidate_package_cache, buf, "cargo", name)
									end

									if ok_chk and type(chk.check_manifest_outdated) == "function" then
										pcall(chk.check_manifest_outdated, buf, "cargo")
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

					local msg = table.concat(err, "\n")
					if msg == "" then
						msg = "cargo remove exited with code " .. tostring(code)
					end
					utils.notify_safe(("cargo remove failed: %s"):format(msg), L.ERROR, {})
				end
			end)
		end,
	})
end

function M.update(name, opts)
	if not name or name == "" then
		return { ok = false, msg = "crate name required" }
	end
	opts = opts or {}
	local version = opts.version
	if not version or version == "" then
		return { ok = false, msg = "version is required" }
	end

	local scope = opts.scope or "dependencies"
	local valid_scopes = const.SECTION_NAMES.cargo or { "dependencies", "dev-dependencies", "build-dependencies" }
	local scope_valid = false
	for _, s in ipairs(valid_scopes) do
		if scope == s then
			scope_valid = true
			break
		end
	end
	if not scope_valid then
		scope = "dependencies"
	end

	local path = find_cargo_toml_path()
	if not path then
		return { ok = false, msg = "Cargo.toml not found in project tree" }
	end

	if opts.from_ui then
		utils.notify_safe(("updating %s to %s..."):format(name, tostring(version)), L.INFO, {})
		run_cargo_add(path, name, version, scope)
		return { ok = true, msg = "started" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read Cargo.toml" }
	end

	-- Find or create the section
	local section_idx = find_section_index(lines, scope)
	if not section_idx then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "[" .. scope .. "]"
		section_idx = #lines
	end

	local section_end = find_section_end(lines, section_idx)
	local dep_idx = find_dependency_in_section(lines, section_idx, section_end, name)

	local new_line = string.format('%s = "%s"', name, version)

	if dep_idx then
		-- Replace existing
		lines[dep_idx] = new_line
	else
		-- Insert new (after section header)
		table.insert(lines, section_idx + 1, new_line)
	end

	local ok_write, werr = write_lines(path, lines)
	if not ok_write then
		return { ok = false, msg = "failed to write Cargo.toml: " .. tostring(werr) }
	end

	refresh_buffer(path, lines)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.add_installed_dependency) == "function" then
		pcall(state.add_installed_dependency, "cargo", name, version, scope)
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
		return { ok = false, msg = "crate name required" }
	end
	opts = opts or {}

	local scope = opts.scope or "dependencies"
	local valid_scopes = const.SECTION_NAMES.cargo or { "dependencies", "dev-dependencies", "build-dependencies" }
	local scope_valid = false
	for _, s in ipairs(valid_scopes) do
		if scope == s then
			scope_valid = true
			break
		end
	end
	if not scope_valid then
		scope = "dependencies"
	end

	local path = find_cargo_toml_path()
	if not path then
		return { ok = false, msg = "Cargo.toml not found in project tree" }
	end

	if opts.from_ui then
		run_cargo_remove(path, name)
		utils.notify_safe(("removing %s..."):format(name), L.INFO, {})
		return { ok = true, msg = "started" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read Cargo.toml" }
	end

	local section_idx = find_section_index(lines, scope)
	if not section_idx then
		return { ok = false, msg = "section " .. scope .. " not found" }
	end

	local section_end = find_section_end(lines, section_idx)
	local dep_idx = find_dependency_in_section(lines, section_idx, section_end, name)

	if not dep_idx then
		return { ok = false, msg = "crate " .. name .. " not found in " .. scope }
	end

	-- Remove the line
	local new_lines = {}
	for i, line in ipairs(lines) do
		if i ~= dep_idx then
			table.insert(new_lines, line)
		end
	end

	local ok_write, werr = write_lines(path, new_lines)
	if not ok_write then
		return { ok = false, msg = "failed to write Cargo.toml: " .. tostring(werr) }
	end

	refresh_buffer(path, new_lines)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.remove_installed_dependency) == "function" then
		pcall(state.remove_installed_dependency, "cargo", name)
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
