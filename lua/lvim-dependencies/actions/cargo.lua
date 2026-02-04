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
	return (str:gsub("[^%w%-._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_cargo_toml_path()
	local manifest_files = const.MANIFEST_FILES.cargo or { "Cargo.toml" }
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

local function force_refresh_buffer(path, fresh_lines)
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

	pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, fresh_lines)

	if saved_cursor then
		pcall(api.nvim_win_set_cursor, cur_win, saved_cursor)
	end

	vim.bo[bufnr].modified = false
end

local function parse_version(v)
	if not v then
		return nil
	end
	v = tostring(v)
	v = v:gsub("^[%^~><=]+", "")
	v = v:gsub("[\"']", "")
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

local function trigger_package_updated()
	api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function clear_all_caches()
	local ok_utils, u = pcall(require, "lvim-dependencies.utils")
	if ok_utils and type(u.clear_file_cache) == "function" then
		u.clear_file_cache()
	end

	local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.cargo")
	if ok_parser and type(parser.clear_lock_cache) == "function" then
		parser.clear_lock_cache()
	end
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

function M.fetch_versions(name, _)
	if not name or name == "" then
		return nil
	end

	local current = nil
	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.get_installed_version) == "function" then
		current = st.get_installed_version("crates", name)
	end

	local encoded_name = urlencode(name)
	local url = ("https://crates.io/api/v1/crates/%s"):format(encoded_name)

	local res = vim.system(
		{ "curl", "-fsS", "--max-time", "10", "-H", "User-Agent: lvim-dependencies", url },
		{ text = true }
	)
		:wait()
	if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
		return nil
	end

	local ok_json, parsed = pcall(vim.json.decode, res.stdout)
	if not ok_json or type(parsed) ~= "table" then
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
			if not yanked then
				table.insert(versions, ver)
			end
		end
	end

	if #versions == 0 then
		return nil
	end

	local seen = {}
	local unique = {}
	for _, v in ipairs(versions) do
		if not seen[v] then
			seen[v] = true
			table.insert(unique, v)
		end
	end

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
		local name = ln:match("^([%w%-%_]+)%s*=")
		if name and tostring(name) == tostring(pkg_name) then
			return i, ln
		end
	end
	return nil, nil
end

local function find_package_lnum_in_section(buf_lines, scope, pkg_name)
	if type(buf_lines) ~= "table" or not scope or scope == "" or not pkg_name or pkg_name == "" then
		return nil
	end

	local section_idx = find_section_index(buf_lines, scope)
	if not section_idx then
		return nil
	end
	local section_end = find_section_end(buf_lines, section_idx)

	for i = section_idx + 1, section_end do
		local ln = buf_lines[i]
		local name = ln and ln:match("^([%w%-%_]+)%s*=")
		if name == pkg_name then
			return i
		end
	end

	return nil
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

	local m = line:match("^([%w%-%_]+)%s*=")
	if m ~= dep_name then
		return false
	end

	local eq_pos = line:find("=", 1, true)
	if not eq_pos then
		return false
	end

	local first_quote = line:find('"', eq_pos + 1, true)
	if not first_quote then
		return false
	end

	local second_quote = line:find('"', first_quote + 1, true)
	if not second_quote then
		return false
	end

	local start0 = first_quote
	local end0 = second_quote - 1

	pcall(api.nvim_buf_set_text, bufnr, lnum1 - 1, start0, lnum1 - 1, end0, { tostring(new_version) })
	vim.bo[bufnr].modified = false
	return true
end

local function run_cargo_add(path, name, version, scope, pending_lnum)
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

	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.set_updating) == "function" then
		pcall(st.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			local bufnr = vim.fn.bufnr(path)

			if res and res.code == 0 then
				-- Run cargo update to lock the version
				vim.system(
					{ "cargo", "update", "-p", name, "--precise", tostring(version) },
					{ cwd = cwd, text = true },
					function(_)
						vim.schedule(function()
							clear_all_caches()

							local applied = false
							if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) and type(pending_lnum) == "number" then
								applied = apply_single_line_version_edit(bufnr, pending_lnum, name, version)
							end

							if not applied then
								local fresh_lines = read_lines(path)
								if fresh_lines then
									force_refresh_buffer(path, fresh_lines)
								end
							end

							utils.notify_safe(("%s@%s installed"):format(name, tostring(version)), L.INFO, {})

							clear_all_caches()

							-- Update installed version in state
							local ok_st, st2 = pcall(require, "lvim-dependencies.state")
							if ok_st and name and version then
								local deps = st2.get_dependencies("crates")
								if deps then
									deps.installed = deps.installed or {}
									deps.installed[name] = { current = version, in_lock = true }
									if type(st2.set_installed) == "function" then
										st2.set_installed("crates", deps.installed)
									end
								end

								if type(st2.add_installed_dependency) == "function" then
									pcall(st2.add_installed_dependency, "crates", name, version, scope)
								end
							end

							local ok_s, s2 = pcall(require, "lvim-dependencies.state")
							if ok_s and type(s2.set_updating) == "function" then
								pcall(s2.set_updating, false)
							end

							if bufnr and bufnr ~= -1 then
								state.buffers = state.buffers or {}
								state.buffers[bufnr] = state.buffers[bufnr] or {}
								state.buffers[bufnr].last_crates_hash = nil
								state.buffers[bufnr].last_changedtick = nil
								state.buffers[bufnr].last_crates_parsed = nil
							end

							-- Start fresh outdated check
							vim.defer_fn(function()
								clear_all_caches()

								if bufnr and bufnr ~= -1 then
									state.buffers = state.buffers or {}
									state.buffers[bufnr] = state.buffers[bufnr] or {}
									state.buffers[bufnr].is_loading = false
									state.buffers[bufnr].pending_dep = nil
									state.buffers[bufnr].checking_single_package = name
								end

								local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
								if ok_chk and type(chk.invalidate_package_cache) == "function" then
									pcall(chk.invalidate_package_cache, bufnr, "crates", name)
								end
								if ok_chk and type(chk.check_manifest_outdated) == "function" then
									pcall(chk.check_manifest_outdated, bufnr, "crates")
								end
							end, 300)

							-- Poll until outdated data is ready
							local poll_count = 0
							local max_polls = 30
							local function poll_for_outdated()
								poll_count = poll_count + 1

								local deps = state.get_dependencies("crates")
								local outdated = deps and deps.outdated
								local pkg_outdated = outdated and outdated[name]
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

										-- ВАЖНО: Mark when update completed for cooldown
										state.buffers[bufnr].last_update_completed_at = vim.loop.now()
									end

									local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
									if ok_vt and type(vt.display) == "function" then
										vt.display(bufnr, "crates", { force_full = true })
									end
								else
									vim.defer_fn(poll_for_outdated, 200)
								end
							end

							vim.defer_fn(poll_for_outdated, 500)

							pcall(function()
								vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
								trigger_package_updated()
							end)
						end)
					end
				)
				return
			end

			-- FAIL
			local ok_s, s2 = pcall(require, "lvim-dependencies.state")
			if ok_s and type(s2.set_updating) == "function" then
				pcall(s2.set_updating, false)
			end

			local msg = (res and res.stderr) or ""
			if msg == "" then
				msg = "cargo add exited with code " .. tostring(res and res.code or "unknown")
			end
			utils.notify_safe(("cargo add failed: %s"):format(msg), L.ERROR, {})

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
				vt.display(bufnr, "crates", { force_full = true })
			end
		end)
	end)
end

local function run_cargo_remove(path, name)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("cargo") == 0 then
		utils.notify_safe("cargo not found", L.ERROR, {})
		return
	end

	local cmd = { "cargo", "remove", name }

	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.set_updating) == "function" then
		pcall(st.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			local bufnr = vim.fn.bufnr(path)

			if res and res.code == 0 then
				clear_all_caches()

				utils.notify_safe(("%s removed"):format(name), L.INFO, {})

				local fresh_lines = read_lines(path)
				if fresh_lines and bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
					force_refresh_buffer(path, fresh_lines)
				end

				local ok_st, st2 = pcall(require, "lvim-dependencies.state")
				if ok_st and type(st2.remove_installed_dependency) == "function" then
					pcall(st2.remove_installed_dependency, "crates", name)
				end

				local ok_s, s2 = pcall(require, "lvim-dependencies.state")
				if ok_s and type(s2.set_updating) == "function" then
					pcall(s2.set_updating, false)
				end

				if bufnr and bufnr ~= -1 then
					state.buffers = state.buffers or {}
					state.buffers[bufnr] = state.buffers[bufnr] or {}
					state.buffers[bufnr].last_crates_hash = nil
					state.buffers[bufnr].last_changedtick = nil
					state.buffers[bufnr].last_crates_parsed = nil

					-- ВАЖНО: Mark when update completed for cooldown
					state.buffers[bufnr].last_update_completed_at = vim.loop.now()
				end

				vim.defer_fn(function()
					local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
					if ok_chk and type(chk.invalidate_package_cache) == "function" then
						pcall(chk.invalidate_package_cache, bufnr, "crates", name)
					end
					if ok_chk and type(chk.check_manifest_outdated) == "function" then
						pcall(chk.check_manifest_outdated, bufnr, "crates")
					end
				end, 300)

				pcall(function()
					vim.g.lvim_deps_last_updated = name .. "@removed"
					trigger_package_updated()
				end)
			else
				local ok_s, s2 = pcall(require, "lvim-dependencies.state")
				if ok_s and type(s2.set_updating) == "function" then
					pcall(s2.set_updating, false)
				end

				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "cargo remove exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("cargo remove failed: %s"):format(msg), L.ERROR, {})
			end
		end)
	end)
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
		local bufnr = vim.fn.bufnr(path)

		local pending_lnum = nil
		if bufnr and bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
			local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
			pending_lnum = find_package_lnum_in_section(buf_lines, scope, name)
		end

		if bufnr and bufnr ~= -1 then
			state.buffers = state.buffers or {}
			state.buffers[bufnr] = state.buffers[bufnr] or {}

			state.buffers[bufnr].is_loading = true
			state.buffers[bufnr].pending_dep = name
			state.buffers[bufnr].pending_lnum = pending_lnum
			state.buffers[bufnr].pending_scope = scope

			clear_pending_anchor(bufnr)
			if pending_lnum then
				state.buffers[bufnr].pending_anchor_id = set_pending_anchor(bufnr, pending_lnum)
			end

			-- 1. Update version in buffer first
			if pending_lnum then
				apply_single_line_version_edit(bufnr, pending_lnum, name, version)
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
		run_cargo_add(path, name, version, scope, pending_lnum)
		return { ok = true, msg = "started" }
	end

	-- Non-UI update
	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read Cargo.toml" }
	end

	local section_idx = find_section_index(lines, scope)
	if not section_idx then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "[" .. scope .. "]"
		section_idx = #lines
	end

	local section_end = find_section_end(lines, section_idx)
	local dep_idx, _ = find_dependency_in_section(lines, section_idx, section_end, name)

	local new_line = string.format('%s = "%s"', name, tostring(version))

	if dep_idx then
		lines[dep_idx] = new_line
	else
		table.insert(lines, section_idx + 1, new_line)
	end

	local ok_write, werr = write_lines(path, lines)
	if not ok_write then
		return { ok = false, msg = "failed to write Cargo.toml: " .. tostring(werr) }
	end

	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
		force_refresh_buffer(path, lines)
	end

	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.add_installed_dependency) == "function" then
		pcall(st.add_installed_dependency, "crates", name, version, scope)
	end

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
		trigger_package_updated()
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

	local path = find_cargo_toml_path()
	if not path then
		return { ok = false, msg = "Cargo.toml not found in project tree" }
	end

	if opts.from_ui then
		run_cargo_remove(path, name)
		utils.notify_safe(("removing %s..."):format(name), L.INFO, {})
		return { ok = true, msg = "started" }
	end

	-- Non-UI remove
	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read Cargo.toml" }
	end

	local scopes = const.SECTION_NAMES.cargo or { "dependencies", "dev-dependencies", "build-dependencies" }
	for _, scope in ipairs(scopes) do
		local section_idx = find_section_index(lines, scope)
		if section_idx then
			local section_end = find_section_end(lines, section_idx)
			local dep_idx = find_dependency_in_section(lines, section_idx, section_end, name)
			if dep_idx then
				local out = {}
				for i, line in ipairs(lines) do
					if i ~= dep_idx then
						table.insert(out, line)
					end
				end

				local ok_write, werr = write_lines(path, out)
				if not ok_write then
					return { ok = false, msg = "failed to write Cargo.toml: " .. tostring(werr) }
				end

				local bufnr = vim.fn.bufnr(path)
				if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
					force_refresh_buffer(path, out)
				end

				local ok_state, st = pcall(require, "lvim-dependencies.state")
				if ok_state and type(st.remove_installed_dependency) == "function" then
					pcall(st.remove_installed_dependency, "crates", name)
				end

				pcall(function()
					vim.g.lvim_deps_last_updated = name .. "@removed"
					trigger_package_updated()
				end)

				utils.notify_safe(("%s removed"):format(name), L.INFO, {})

				return { ok = true, msg = "removed" }
			end
		end
	end

	return { ok = false, msg = "crate not found" }
end

function M.install(_)
	return { ok = true }
end

function M.check_outdated(_)
	return { ok = true }
end

return M
