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
	return (str:gsub("([^%w%-._~/])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_go_mod_path()
	local manifest_files = const.MANIFEST_FILES.go or { "go.mod" }
	local cwd = vim.fn.getcwd()
	local found = vim.fs.find(manifest_files, { upward = true, path = cwd, type = "file" })
	return found and found[1] or nil
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

local function apply_buffer_change(path, change)
	if not change then
		return
	end
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

	local start0 = change.start0 or 0
	local end0 = change.end0 or 0
	local replacement = change.lines or {}

	pcall(api.nvim_buf_set_lines, bufnr, start0, end0, false, replacement)

	if saved_cursor then
		local row = saved_cursor[1]
		if start0 < row - 1 then
			local removed = end0 - start0
			local added = #replacement
			local delta = added - removed
			row = math.max(1, row + delta)
		end
		pcall(api.nvim_win_set_cursor, cur_win, { row, saved_cursor[2] })
	end

	vim.bo[bufnr].modified = false
end

local function parse_version(v)
	if not v then
		return nil
	end
	v = tostring(v)
	local major, minor, patch = v:match("^v?(%d+)%.(%d+)%.(%d+)")
	if major and minor and patch then
		return { tonumber(major), tonumber(minor), tonumber(patch) }
	end
	return nil
end

local function normalize_version(version)
	if not version or version == "" then
		return version
	end
	local v = tostring(version)
	if v:sub(1, 1) ~= "v" and v:match("^%d") then
		return "v" .. v
	end
	return v
end

local function version_has_incompatible(v)
	if not v then
		return false
	end
	return tostring(v):find("+incompatible", 1, true) ~= nil
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

local function strip_major_path(name)
	if not name then
		return name
	end
	return name:gsub("/v%d+$", "")
end

local function is_gopkg_in(name)
	return name and name:match("%.v%d+$") ~= nil
end

local function go_module_path_for_version(name, version)
	if not name or name == "" then
		return name
	end

	if name:match("/v%d+$") then
		return name
	end

	if name:match("%.v%d+$") then
		return name
	end

	local major = (parse_version(version) or {})[1] or 0
	if major >= 2 then
		return name .. "/v" .. tostring(major)
	end

	return name
end

local function resolve_update_module_name(name, version)
	if not name or name == "" then
		return name
	end

	if is_gopkg_in(name) then
		return name
	end

	if version_has_incompatible(version) then
		return strip_major_path(name)
	end

	return go_module_path_for_version(name, version)
end

local function fetch_go_proxy_versions(module_name)
	local encoded_name = urlencode(module_name)
	local url = ("https://proxy.golang.org/%s/@v/list"):format(encoded_name)

	local res = vim.system({ "curl", "-fsS", "--max-time", "10", url }, { text = true }):wait()
	if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
		return nil
	end

	local versions = {}
	for line in res.stdout:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			versions[#versions + 1] = trimmed
		end
	end

	if #versions == 0 then
		return nil
	end
	return versions
end

local function should_migrate_imports(name, module_name)
	if not name or not module_name then
		return false
	end
	if name == module_name then
		return false
	end
	if is_gopkg_in(name) or is_gopkg_in(module_name) then
		return false
	end
	return true
end

local function resolve_import_migration(name, module_name)
	if not should_migrate_imports(name, module_name) then
		return nil, nil
	end
	local old_import = name
	local new_import = module_name
	if old_import == new_import then
		return nil, nil
	end
	return old_import, new_import
end

local function find_go_files_with_import(cwd, old_import)
	if vim.fn.executable("rg") == 1 then
		local res = vim.fn.systemlist({ "rg", "-l", "--no-messages", "--glob", "*.go", old_import, cwd })
		if type(res) == "table" then
			return res
		end
	end

	local files = vim.fs.find(function(p)
		return p:sub(-3) == ".go"
	end, { path = cwd, type = "file", limit = math.huge })

	local hits = {}
	for _, f in ipairs(files or {}) do
		local lines = read_lines(f)
		if lines then
			for _, line in ipairs(lines) do
				if line:find(old_import, 1, true) then
					hits[#hits + 1] = f
					break
				end
			end
		end
	end

	return hits
end

local function migrate_imports(cwd, old_import, new_import)
	if not old_import or not new_import or old_import == new_import then
		return 0, 0
	end

	local files = find_go_files_with_import(cwd, old_import)
	if not files or #files == 0 then
		return 0, 0
	end

	local changed_files = 0
	local changed_lines = 0

	for _, path in ipairs(files) do
		local lines = read_lines(path)
		if lines then
			local changed = false
			for i, line in ipairs(lines) do
				local new_line = line
				new_line = new_line:gsub('"' .. old_import .. '/"', '"' .. new_import .. '/"')
				new_line = new_line:gsub('"' .. old_import .. "/", '"' .. new_import .. "/")
				new_line = new_line:gsub('"' .. old_import .. '"', '"' .. new_import .. '"')
				if new_line ~= line then
					lines[i] = new_line
					changed = true
					changed_lines = changed_lines + 1
				end
			end
			if changed then
				local ok = write_lines(path, lines)
				if ok then
					changed_files = changed_files + 1
				end
			end
		end
	end

	return changed_files, changed_lines
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

	local targets = {}
	local target_set = {}

	local function add_target(t)
		if t and t ~= "" and not target_set[t] then
			target_set[t] = true
			targets[#targets + 1] = t
		end
	end

	local has_path_major = name:match("/v%d+$") ~= nil
	local has_dot_major = name:match("%.v%d+$") ~= nil

	if has_path_major then
		add_target(name)
		add_target(strip_major_path(name))
	elseif has_dot_major then
		add_target(name)
	else
		add_target(name)
	end

	local base_versions = fetch_go_proxy_versions(name)
	if not has_dot_major and base_versions then
		local max_major = 0
		for _, v in ipairs(base_versions) do
			local pv = parse_version(v)
			if pv and pv[1] and pv[1] > max_major then
				max_major = pv[1]
			end
		end
		if max_major >= 2 then
			add_target(name .. "/v" .. tostring(max_major))
		end
	end

	if current and not has_dot_major then
		add_target(go_module_path_for_version(name, current))
	end

	local versions = {}
	local seen = {}

	for _, t in ipairs(targets) do
		local list = fetch_go_proxy_versions(t)
		if list then
			for _, v in ipairs(list) do
				if v and not seen[v] then
					seen[v] = true
					versions[#versions + 1] = v
				end
			end
		end
	end

	if #versions == 0 then
		return nil
	end

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
		if line:match("^require%s+") and not line:match("^require%s*%(") then
			return nil, nil
		end

		if line:match("^require%s*%(") then
			start_idx = i
			in_require = true
		end

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
		local mod, ver = line:match("^%s*([^%s]+)%s+([^%s]+)")
		if mod and tostring(mod) == tostring(module_name) then
			return i, ver
		end
	end

	return nil, nil
end

local function find_module_in_require_any(lines, start_idx, end_idx, names)
	for _, n in ipairs(names) do
		local idx, ver = find_module_in_require(lines, start_idx, end_idx, n)
		if idx then
			return idx, ver, n
		end
	end
	return nil, nil, nil
end

local function reparse_and_check_debounced(path, updated_module_name)
	local bufnr = vim.fn.bufnr(path)
	if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
		return
	end

	vim.defer_fn(function()
		local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.go")
		if ok_parser and type(parser.parse_buffer) == "function" then
			pcall(parser.parse_buffer, bufnr)
		end
	end, 250)

	vim.defer_fn(function()
		local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
		if ok_chk and type(chk.invalidate_package_cache) == "function" and updated_module_name then
			pcall(chk.invalidate_package_cache, bufnr, "go", updated_module_name)
		end
		if ok_chk and type(chk.check_manifest_outdated) == "function" then
			pcall(chk.check_manifest_outdated, bufnr, "go")
		end
	end, 1200)
end

local function set_updating_flag(v)
	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.set_updating) == "function" then
		pcall(st.set_updating, v)
	end
end

local function trigger_package_updated()
	api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function apply_go_update(path, name, version, original_name)
	local lines = read_lines(path)
	if not lines then
		return false, "unable to read go.mod"
	end

	local start_idx, end_idx = find_require_block(lines)
	if not start_idx or not end_idx then
		return false, "require block not found in go.mod"
	end

	local module_name = resolve_update_module_name(name, version)
	local candidates = { name, strip_major_path(name), module_name, original_name }

	local mod_idx, existing_ver = find_module_in_require_any(lines, start_idx, end_idx, candidates)
	local new_line = string.format("\t%s %s", module_name, version)

	if mod_idx and existing_ver and tostring(existing_ver) == tostring(version) then
		return false, "version unchanged"
	end

	if mod_idx then
		lines[mod_idx] = new_line
		local ok_write, werr = write_lines(path, lines)
		if not ok_write then
			return false, "failed to write go.mod: " .. tostring(werr)
		end
		apply_buffer_change(path, { start0 = mod_idx - 1, end0 = mod_idx, lines = { new_line } })
		return true
	end

	table.insert(lines, end_idx, new_line)
	local ok_write, werr = write_lines(path, lines)
	if not ok_write then
		return false, "failed to write go.mod: " .. tostring(werr)
	end
	apply_buffer_change(path, { start0 = end_idx - 1, end0 = end_idx - 1, lines = { new_line } })
	return true
end

local function apply_go_remove(path, name)
	local lines = read_lines(path)
	if not lines then
		return false, "unable to read go.mod"
	end

	local start_idx, end_idx = find_require_block(lines)
	if not start_idx or not end_idx then
		return false, "require block not found in go.mod"
	end

	local candidates = { name, strip_major_path(name) }
	local mod_idx, _, found_name = find_module_in_require_any(lines, start_idx, end_idx, candidates)
	if not mod_idx then
		return false, "module " .. name .. " not found in require block"
	end

	local new_lines = {}
	for i, line in ipairs(lines) do
		if i ~= mod_idx then
			new_lines[#new_lines + 1] = line
		end
	end

	local ok_write, werr = write_lines(path, new_lines)
	if not ok_write then
		return false, "failed to write go.mod: " .. tostring(werr)
	end

	apply_buffer_change(path, { start0 = mod_idx - 1, end0 = mod_idx, lines = {} })
	return true, found_name or name
end

local function run_go_get(path, name, version, original_name)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("go") == 0 then
		utils.notify_safe("go CLI not found", L.ERROR, {})
		return
	end

	version = normalize_version(version)

	if version_has_incompatible(version) and name:match("/v%d+$") then
		name = strip_major_path(name)
	end

	local module_name = resolve_update_module_name(name, version)

	local old_import, new_import
	if original_name and original_name ~= name and version_has_incompatible(version) then
		old_import, new_import = original_name, module_name
	else
		old_import, new_import = resolve_import_migration(name, module_name)
	end

	if old_import and new_import then
		local changed_files, changed_lines = migrate_imports(cwd, old_import, new_import)
		if changed_files > 0 then
			utils.notify_safe(
				("Migrated %d file(s) / %d line(s) imports to %s"):format(changed_files, changed_lines, new_import),
				L.INFO,
				{}
			)
		else
			utils.notify_safe(
				("No imports updated. If your code still imports %s, go.mod may revert."):format(old_import),
				L.WARN,
				{}
			)
		end
	end

	local pkg_spec = version and (module_name .. "@" .. version) or module_name
	local cmd = { "go", "get", pkg_spec }

	set_updating_flag(true)

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			if not res or res.code ~= 0 then
				set_updating_flag(false)

				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "go get exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("go get failed: %s"):format(msg), L.ERROR, {})
				return
			end

			utils.notify_safe(("%s@%s installed"):format(module_name, tostring(version)), L.INFO, {})

			vim.system({ "go", "mod", "tidy" }, { cwd = cwd, text = true }, function(res2)
				vim.schedule(function()
					set_updating_flag(false)

					if not res2 or res2.code ~= 0 then
						local msg = (res2 and res2.stderr) or ""
						if msg == "" then
							msg = "go mod tidy exited with code " .. tostring(res2 and res2.code or "unknown")
						end
						utils.notify_safe(("go mod tidy failed: %s"):format(msg), L.ERROR, {})
						return
					end

					apply_go_update(path, module_name, version, original_name)
					reparse_and_check_debounced(path, module_name)

					pcall(function()
						vim.g.lvim_deps_last_updated = module_name .. "@" .. tostring(version)
						trigger_package_updated()
					end)
				end)
			end)
		end)
	end)
end

local function run_go_remove(path, name)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("go") == 0 then
		utils.notify_safe("go CLI not found", L.ERROR, {})
		return
	end

	local ok, found_name = apply_go_remove(path, name)
	if not ok then
		utils.notify_safe(("module %s not found in go.mod"):format(name), L.WARN, {})
		return
	end

	set_updating_flag(true)
	vim.system({ "go", "mod", "tidy" }, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			set_updating_flag(false)

			if not res or res.code ~= 0 then
				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "go mod tidy exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("go mod tidy failed after removal: %s"):format(msg), L.ERROR, {})
				return
			end

			utils.notify_safe(("%s removed"):format(found_name or name), L.INFO, {})

			reparse_and_check_debounced(path, found_name or name)

			pcall(function()
				vim.g.lvim_deps_last_updated = (found_name or name) .. "@removed"
				trigger_package_updated()
			end)
		end)
	end)
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

	version = normalize_version(version)

	local original_name = name

	if version_has_incompatible(version) and name:match("/v%d+$") then
		name = strip_major_path(name)
	end

	local path = find_go_mod_path()
	if not path then
		return { ok = false, msg = "go.mod not found in project tree" }
	end

	if opts.from_ui then
		utils.notify_safe(("updating %s to %s..."):format(name, tostring(version)), L.INFO, {})
		run_go_get(path, name, version, original_name)
		return { ok = true, msg = "started" }
	end

	local ok_apply, err = apply_go_update(path, name, version, original_name)
	if not ok_apply and err == "version unchanged" then
		return { ok = true, msg = "unchanged" }
	end
	if not ok_apply then
		return { ok = false, msg = err }
	end

	reparse_and_check_debounced(path, resolve_update_module_name(name, version))

	pcall(function()
		vim.g.lvim_deps_last_updated = resolve_update_module_name(name, version) .. "@" .. tostring(version)
		trigger_package_updated()
	end)

	utils.notify_safe(("%s -> %s"):format(resolve_update_module_name(name, version), tostring(version)), L.INFO, {})

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
		utils.notify_safe(("removing %s..."):format(name), L.INFO, {})
		run_go_remove(path, name)
		return { ok = true, msg = "started" }
	end

	local ok_remove, found_name = apply_go_remove(path, name)
	if not ok_remove then
		return { ok = false, msg = "module " .. name .. " not found in require block" }
	end

	reparse_and_check_debounced(path, found_name or name)

	pcall(function()
		vim.g.lvim_deps_last_updated = (found_name or name) .. "@removed"
		trigger_package_updated()
	end)

	utils.notify_safe(("%s removed"):format(found_name or name), L.INFO, {})

	return { ok = true, msg = "removed" }
end

function M.install(_)
	return { ok = true }
end

function M.check_outdated(_)
	return { ok = true }
end

return M
