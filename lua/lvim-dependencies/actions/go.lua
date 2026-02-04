local api = vim.api

local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local state = require("lvim-dependencies.state")
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
	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.get_installed_version) == "function" then
		current = st.get_installed_version("go", name)
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

local function find_all_require_blocks(lines)
	local blocks = {}
	local i = 1

	while i <= #lines do
		local line = lines[i]

		-- Single line require: require module/name v1.2.3
		if line:match("^require%s+[^(]") then
			blocks[#blocks + 1] = { start_idx = i, end_idx = i, single = true }
		end

		-- Block require: require (
		if line:match("^require%s*%(") then
			local start_idx = i
			local end_idx = nil

			for j = i + 1, #lines do
				if lines[j]:match("^%)") then
					end_idx = j
					break
				end
			end

			if end_idx then
				blocks[#blocks + 1] = { start_idx = start_idx, end_idx = end_idx, single = false }
				i = end_idx
			end
		end

		i = i + 1
	end

	return blocks
end

local function find_require_block(lines)
	local blocks = find_all_require_blocks(lines)
	if #blocks > 0 and not blocks[1].single then
		return blocks[1].start_idx, blocks[1].end_idx
	end
	return nil, nil
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

local function find_module_in_all_require_blocks(lines, module_name)
	local blocks = find_all_require_blocks(lines)

	for _, block in ipairs(blocks) do
		if block.single then
			-- Single line require
			local line = lines[block.start_idx]
			local mod, ver = line:match("^require%s+([^%s]+)%s+([^%s]+)")
			if mod and (mod == module_name or strip_major_path(mod) == strip_major_path(module_name)) then
				return block.start_idx, ver, mod
			end
		else
			-- Block require
			for i = block.start_idx + 1, block.end_idx - 1 do
				local line = lines[i]
				local mod, ver = line:match("^%s*([^%s]+)%s+([^%s]+)")
				if mod and (mod == module_name or strip_major_path(mod) == strip_major_path(module_name)) then
					return i, ver, mod
				end
			end
		end
	end

	return nil, nil, nil
end

local function find_module_in_require_any(lines, start_idx, end_idx, names)
	-- First try the specific block
	for _, n in ipairs(names) do
		local idx, ver = find_module_in_require(lines, start_idx, end_idx, n)
		if idx then
			return idx, ver, n
		end
	end

	-- Then search all blocks
	for _, n in ipairs(names) do
		local idx, ver, found_name = find_module_in_all_require_blocks(lines, n)
		if idx then
			return idx, ver, found_name or n
		end
	end

	return nil, nil, nil
end

local function find_package_lnum_in_require(buf_lines, pkg_name)
	if type(buf_lines) ~= "table" or not pkg_name or pkg_name == "" then
		return nil
	end

	local idx, _, _ = find_module_in_all_require_blocks(buf_lines, pkg_name)
	return idx
end

local function ensure_deps_namespace()
	state.namespace = state.namespace or {}
	state.namespace.id = state.namespace.id or api.nvim_create_namespace("lvim_dependencies")
	return tonumber(state.namespace.id) or 0
end

local function set_pending_anchor(bufnr, lnum1)
	if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	if type(lnum1) ~= "number" or lnum1 < 1 then
		return nil
	end
	local ns = ensure_deps_namespace()
	local id = api.nvim_buf_set_extmark(bufnr, ns, lnum1 - 1, 0, {
		right_gravity = false,
	})
	return id
end

local function clear_pending_anchor(bufnr)
	if not (bufnr and bufnr ~= -1) then
		return
	end
	local rec = state.buffers and state.buffers[bufnr]
	if not rec or not rec.pending_anchor_id then
		return
	end
	local ns = ensure_deps_namespace()
	pcall(api.nvim_buf_del_extmark, bufnr, ns, rec.pending_anchor_id)
	rec.pending_anchor_id = nil
end

local function clear_all_caches()
	local ok_utils, u = pcall(require, "lvim-dependencies.utils")
	if ok_utils and type(u.clear_file_cache) == "function" then
		u.clear_file_cache()
	end

	local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.go")
	if ok_parser and type(parser.clear_lock_cache) == "function" then
		parser.clear_lock_cache()
	end
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

local function apply_single_line_version_edit(bufnr, lnum1, dep_name, new_version)
	if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
		return false
	end
	if type(lnum1) ~= "number" or lnum1 < 1 then
		return false
	end
	if not dep_name or dep_name == "" then
		return false
	end
	if not new_version or new_version == "" then
		return false
	end

	local line = api.nvim_buf_get_lines(bufnr, lnum1 - 1, lnum1, false)[1]
	if not line then
		return false
	end

	-- go.mod format: \tmodule/name v1.2.3 or \tmodule/name v1.2.3 // indirect
	local mod_name = line:match("^%s*([^%s]+)%s+")
	if not mod_name then
		return false
	end

	-- Check if this is the right module
	local base_mod = strip_major_path(mod_name)
	local base_dep = strip_major_path(dep_name)
	if mod_name ~= dep_name and base_mod ~= base_dep and mod_name ~= base_dep and base_mod ~= dep_name then
		return false
	end

	-- Find version position
	local space_pos = line:find("%s+v")
	if not space_pos then
		space_pos = line:find("%s+%d")
	end
	if not space_pos then
		return false
	end

	local ver_start = space_pos
	while ver_start <= #line and line:sub(ver_start, ver_start):match("%s") do
		ver_start = ver_start + 1
	end

	-- Find end of version (before // comment or end of line)
	local ver_end = ver_start
	while ver_end <= #line do
		local ch = line:sub(ver_end, ver_end)
		if ch:match("%s") or ch == "/" then
			break
		end
		ver_end = ver_end + 1
	end
	ver_end = ver_end - 1

	local version_to_set = normalize_version(new_version)

	pcall(api.nvim_buf_set_text, bufnr, lnum1 - 1, ver_start - 1, lnum1 - 1, ver_end, { version_to_set })
	vim.bo[bufnr].modified = false
	return true
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
			local bufnr = vim.fn.bufnr(path)

			if not res or res.code ~= 0 then
				set_updating_flag(false)

				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "go get exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("go get failed: %s"):format(msg), L.ERROR, {})

				-- Clear loading on failure
				if bufnr and bufnr ~= -1 then
					state.buffers = state.buffers or {}
					state.buffers[bufnr] = state.buffers[bufnr] or {}
					clear_pending_anchor(bufnr)

					state.buffers[bufnr].is_loading = false
					state.buffers[bufnr].pending_dep = nil
					state.buffers[bufnr].pending_lnum = nil
					state.buffers[bufnr].pending_scope = nil
					state.buffers[bufnr].checking_single_package = nil
				end

				local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
				if ok_vt and type(vt.display) == "function" then
					vt.display(bufnr, "go", { force_full = true })
				end
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

						-- Clear loading on failure
						if bufnr and bufnr ~= -1 then
							state.buffers = state.buffers or {}
							state.buffers[bufnr] = state.buffers[bufnr] or {}
							clear_pending_anchor(bufnr)

							state.buffers[bufnr].is_loading = false
							state.buffers[bufnr].pending_dep = nil
							state.buffers[bufnr].pending_lnum = nil
							state.buffers[bufnr].pending_scope = nil
							state.buffers[bufnr].checking_single_package = nil
						end

						local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
						if ok_vt and type(vt.display) == "function" then
							vt.display(bufnr, "go", { force_full = true })
						end
						return
					end

					clear_all_caches()

					-- Update installed version in state
					local ok_st, st2 = pcall(require, "lvim-dependencies.state")
					if ok_st and module_name and version then
						local deps = st2.get_dependencies("go")
						if deps then
							deps.installed = deps.installed or {}
							deps.installed[module_name] = { current = version, in_lock = true }
							if type(st2.set_installed) == "function" then
								st2.set_installed("go", deps.installed)
							end
						end

						if type(st2.add_installed_dependency) == "function" then
							pcall(st2.add_installed_dependency, "go", module_name, version, "require")
						end
					end

					if bufnr and bufnr ~= -1 then
						state.buffers = state.buffers or {}
						state.buffers[bufnr] = state.buffers[bufnr] or {}
						state.buffers[bufnr].last_go_hash = nil
						state.buffers[bufnr].last_changedtick = nil
						state.buffers[bufnr].last_go_parsed = nil
					end

					-- Start fresh outdated check
					vim.defer_fn(function()
						clear_all_caches()

						-- Clear is_loading so check_manifest_outdated runs, but set checking flag
						if bufnr and bufnr ~= -1 then
							state.buffers = state.buffers or {}
							state.buffers[bufnr] = state.buffers[bufnr] or {}
							state.buffers[bufnr].is_loading = false
							state.buffers[bufnr].pending_dep = nil
							state.buffers[bufnr].checking_single_package = module_name
						end

						local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
						if ok_chk and type(chk.invalidate_package_cache) == "function" then
							pcall(chk.invalidate_package_cache, bufnr, "go", module_name)
						end
						if ok_chk and type(chk.check_manifest_outdated) == "function" then
							pcall(chk.check_manifest_outdated, bufnr, "go")
						end
					end, 300)

					-- Poll until outdated data is ready
					local poll_count = 0
					local max_polls = 30
					local function poll_for_outdated()
						poll_count = poll_count + 1

						local deps = state.get_dependencies("go")
						local outdated = deps and deps.outdated
						local pkg_outdated = outdated and outdated[module_name]
						local has_fresh_data = pkg_outdated and pkg_outdated.latest ~= nil

						if has_fresh_data or poll_count >= max_polls then
							if bufnr and bufnr ~= -1 then
								state.buffers = state.buffers or {}
								state.buffers[bufnr] = state.buffers[bufnr] or {}
								clear_pending_anchor(bufnr)

								state.buffers[bufnr].is_loading = false
								state.buffers[bufnr].pending_dep = nil
								state.buffers[bufnr].pending_lnum = nil
								state.buffers[bufnr].pending_scope = nil
								state.buffers[bufnr].checking_single_package = nil

								-- Mark when update completed for cooldown
								state.buffers[bufnr].last_update_completed_at = vim.loop.now()
							end

							local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
							if ok_vt and type(vt.display) == "function" then
								vt.display(bufnr, "go", { force_full = true })
							end
						else
							vim.defer_fn(poll_for_outdated, 200)
						end
					end

					vim.defer_fn(poll_for_outdated, 500)

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

			local bufnr = vim.fn.bufnr(path)

			if not res or res.code ~= 0 then
				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "go mod tidy exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("go mod tidy failed after removal: %s"):format(msg), L.ERROR, {})
				return
			end

			utils.notify_safe(("%s removed"):format(found_name or name), L.INFO, {})

			clear_all_caches()

			if bufnr and bufnr ~= -1 then
				state.buffers = state.buffers or {}
				state.buffers[bufnr] = state.buffers[bufnr] or {}
				state.buffers[bufnr].last_go_hash = nil
				state.buffers[bufnr].last_changedtick = nil
				state.buffers[bufnr].last_go_parsed = nil

				-- Mark when update completed for cooldown
				state.buffers[bufnr].last_update_completed_at = vim.loop.now()
			end

			vim.defer_fn(function()
				local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
				if ok_chk and type(chk.invalidate_package_cache) == "function" then
					pcall(chk.invalidate_package_cache, bufnr, "go", found_name or name)
				end
				if ok_chk and type(chk.check_manifest_outdated) == "function" then
					pcall(chk.check_manifest_outdated, bufnr, "go")
				end
			end, 300)

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
		local bufnr = vim.fn.bufnr(path)

		local pending_lnum = nil
		if bufnr and bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
			local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
			pending_lnum = find_package_lnum_in_require(buf_lines, name)
			if not pending_lnum then
				pending_lnum = find_package_lnum_in_require(buf_lines, original_name)
			end
		end

		if bufnr and bufnr ~= -1 then
			state.buffers = state.buffers or {}
			state.buffers[bufnr] = state.buffers[bufnr] or {}

			state.buffers[bufnr].is_loading = true
			state.buffers[bufnr].pending_dep = name
			state.buffers[bufnr].pending_lnum = pending_lnum
			state.buffers[bufnr].pending_scope = "require"

			clear_pending_anchor(bufnr)
			if pending_lnum then
				state.buffers[bufnr].pending_anchor_id = set_pending_anchor(bufnr, pending_lnum)
			end

			-- 1. Update version in buffer
			if pending_lnum then
				local applied = apply_single_line_version_edit(bufnr, pending_lnum, name, version)
				if not applied then
					apply_single_line_version_edit(bufnr, pending_lnum, original_name, version)
				end
			end

			-- 2. Clear extmark on this line and show Loading...
			local ns = ensure_deps_namespace()
			if pending_lnum then
				local marks = api.nvim_buf_get_extmarks(
					bufnr,
					ns,
					{ pending_lnum - 1, 0 },
					{ pending_lnum - 1, -1 },
					{}
				)
				for _, mark in ipairs(marks) do
					pcall(api.nvim_buf_del_extmark, bufnr, ns, mark[1])
				end

				api.nvim_buf_set_extmark(bufnr, ns, pending_lnum - 1, 0, {
					virt_text = { { "Loading...", "LvimDepsLoading" } },
					virt_text_pos = "eol",
					priority = 1000,
				})
			end

			-- 3. Force redraw
			vim.cmd("redraw")
		end

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

	local module_name = resolve_update_module_name(name, version)

	vim.defer_fn(function()
		local bufnr = vim.fn.bufnr(path)
		local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
		if ok_chk and type(chk.invalidate_package_cache) == "function" then
			pcall(chk.invalidate_package_cache, bufnr, "go", module_name)
		end
		if ok_chk and type(chk.check_manifest_outdated) == "function" then
			pcall(chk.check_manifest_outdated, bufnr, "go")
		end
	end, 300)

	pcall(function()
		vim.g.lvim_deps_last_updated = module_name .. "@" .. tostring(version)
		trigger_package_updated()
	end)

	utils.notify_safe(("%s -> %s"):format(module_name, tostring(version)), L.INFO, {})

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

	vim.defer_fn(function()
		local bufnr = vim.fn.bufnr(path)
		local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
		if ok_chk and type(chk.invalidate_package_cache) == "function" then
			pcall(chk.invalidate_package_cache, bufnr, "go", found_name or name)
		end
		if ok_chk and type(chk.check_manifest_outdated) == "function" then
			pcall(chk.check_manifest_outdated, bufnr, "go")
		end
	end, 300)

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
