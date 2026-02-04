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
	return (str:gsub("[^%w%-._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_composer_json_path()
	local manifest_files = const.MANIFEST_FILES.composer or { "composer.json" }
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

local function find_section_index(lines, section_name)
	local patt = '^%s*"' .. vim.pesc(section_name) .. '"%s*:%s*{'
	for i, ln in ipairs(lines) do
		if ln:match(patt) then
			return i
		end
	end
	return nil
end

local function find_section_end(lines, section_idx)
	local depth = 0
	local started = false
	for i = section_idx, #lines do
		local ln = lines[i]
		local open_count = select(2, ln:gsub("{", ""))
		local close_count = select(2, ln:gsub("}", ""))
		if open_count > 0 then
			started = true
		end
		depth = depth + open_count - close_count
		if started and depth == 0 then
			return i
		end
	end
	return #lines
end

local function find_entry_indent(lines, section_idx, section_end)
	for i = section_idx + 1, section_end - 1 do
		local ln = lines[i]
		if ln:match('^%s*".-"%s*:') then
			return ln:match("^(%s*)") or "    "
		end
	end
	local section_indent = lines[section_idx]:match("^(%s*)") or ""
	return section_indent .. "    "
end

local function find_last_entry_index(lines, section_idx, section_end)
	local last = nil
	for i = section_idx + 1, section_end - 1 do
		local ln = lines[i]
		if ln:match('^%s*".-"%s*:') then
			last = i
		end
	end
	return last
end

local function ensure_trailing_comma(line)
	if line:match(",%s*$") then
		return line
	end
	return line:gsub("%s*$", ",")
end

local function remove_trailing_comma(line)
	return line:gsub(",%s*$", "")
end

local function find_package_line(lines, section_idx, section_end, pkg_name)
	for i = section_idx + 1, section_end - 1 do
		local ln = lines[i]
		local m_name = ln:match('^%s*"(.-)"%s*:')
		if m_name and tostring(m_name) == tostring(pkg_name) then
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

	for i = section_idx + 1, section_end - 1 do
		local ln = buf_lines[i]
		local m = ln and ln:match('^%s*"(.-)"%s*:')
		if m == pkg_name then
			return i
		end
	end

	return nil
end

local function find_root_end(lines)
	for i = #lines, 1, -1 do
		if lines[i]:match("^%s*}%s*,?%s*$") then
			return i
		end
	end
	return #lines
end

local function find_top_level_indent(lines)
	for _, ln in ipairs(lines) do
		if ln:match('^%s*".-"%s*:') then
			return ln:match("^(%s*)") or "    "
		end
	end
	return "    "
end

local function find_last_top_level_entry(lines, root_end)
	for i = root_end - 1, 1, -1 do
		if lines[i]:match('^%s*".-"%s*:') then
			return i
		end
	end
	return nil
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

	local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.composer")
	if ok_parser and type(parser.clear_lock_cache) == "function" then
		parser.clear_lock_cache()
	end
end

local function parse_semver(v)
	if not v then
		return nil
	end
	v = tostring(v)
	v = v:gsub("^%s*", ""):gsub("%s*$", "")
	v = v:gsub("^v", "")
	v = v:gsub("^[%^~><=]+", "")
	v = v:gsub("%+.*$", "")
	local major, minor, patch, pre = v:match("^(%d+)%.(%d+)%.(%d+)%-(.+)$")
	if not major then
		major, minor, patch = v:match("^(%d+)%.(%d+)%.(%d+)$")
	end
	if major then
		return {
			major = tonumber(major) or 0,
			minor = tonumber(minor) or 0,
			patch = tonumber(patch) or 0,
			pre = pre,
		}
	end

	local ma, mi = v:match("^(%d+)%.(%d+)$")
	if ma then
		return { major = tonumber(ma) or 0, minor = tonumber(mi) or 0, patch = 0, pre = nil }
	end
	local m1 = v:match("^(%d+)$")
	if m1 then
		return { major = tonumber(m1) or 0, minor = 0, patch = 0, pre = nil }
	end
	return nil
end

local function split_pre(pre)
	if not pre or pre == "" then
		return {}
	end
	return vim.split(pre, ".", { plain = true })
end

local function cmp_ident(a, b)
	local na = tonumber(a)
	local nb = tonumber(b)
	if na and nb then
		if na == nb then
			return 0
		end
		return na < nb and -1 or 1
	end
	if na and not nb then
		return -1
	end
	if not na and nb then
		return 1
	end
	if a == b then
		return 0
	end
	return a < b and -1 or 1
end

local function compare_semver(a, b)
	if not a and not b then
		return 0
	end
	if not a then
		return -1
	end
	if not b then
		return 1
	end

	if a.major ~= b.major then
		return a.major < b.major and -1 or 1
	end
	if a.minor ~= b.minor then
		return a.minor < b.minor and -1 or 1
	end
	if a.patch ~= b.patch then
		return a.patch < b.patch and -1 or 1
	end

	if not a.pre and not b.pre then
		return 0
	end
	if not a.pre and b.pre then
		return 1
	end
	if a.pre and not b.pre then
		return -1
	end

	local ap = split_pre(a.pre)
	local bp = split_pre(b.pre)
	local n = math.max(#ap, #bp)
	for i = 1, n do
		local ai = ap[i]
		local bi = bp[i]
		if ai == nil and bi == nil then
			return 0
		end
		if ai == nil then
			return -1
		end
		if bi == nil then
			return 1
		end
		local c = cmp_ident(ai, bi)
		if c ~= 0 then
			return c
		end
	end
	return 0
end

function M.fetch_versions(name, _)
	if not name or name == "" then
		return nil
	end

	local current = nil
	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.get_installed_version) == "function" then
		current = st.get_installed_version("composer", name)
	end

	local encoded_name = urlencode(name)
	local url = ("https://repo.packagist.org/p2/%s.json"):format(encoded_name)

	local res = vim.system({ "curl", "-fsS", "--max-time", "10", url }, { text = true }):wait()
	if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
		return nil
	end

	local ok_json, parsed = pcall(vim.json.decode, res.stdout)
	if not ok_json or type(parsed) ~= "table" then
		return nil
	end

	local packages = parsed.packages
	if not packages or type(packages) ~= "table" then
		return nil
	end

	local pkg_data = packages[name]
	if not pkg_data or type(pkg_data) ~= "table" then
		return nil
	end

	local versions = {}
	for _, entry in ipairs(pkg_data) do
		if type(entry) == "table" and entry.version then
			local ver = tostring(entry.version)
			if not ver:match("^dev%-") then
				versions[#versions + 1] = ver
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
			unique[#unique + 1] = v
		end
	end

	table.sort(unique, function(a, b)
		local pa = parse_semver(a)
		local pb = parse_semver(b)
		local cmp = compare_semver(pa, pb)
		if cmp == 0 then
			return tostring(a) > tostring(b)
		end
		return cmp == 1
	end)

	return { versions = unique, current = current }
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

	local m = line:match('^%s*"(.-)"%s*:')
	if m ~= dep_name then
		return false
	end

	local colon_pos = line:find(":", 1, true)
	if not colon_pos then
		return false
	end

	local first_quote = line:find('"', colon_pos + 1, true)
	if not first_quote then
		return false
	end

	local second_quote = line:find('"', first_quote + 1, true)
	if not second_quote then
		return false
	end

	local start0 = first_quote
	local end0 = second_quote - 1

	local version_spec = "^" .. tostring(new_version)
	pcall(api.nvim_buf_set_text, bufnr, lnum1 - 1, start0, lnum1 - 1, end0, { version_spec })
	vim.bo[bufnr].modified = false
	return true
end

local function trigger_package_updated()
	api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function run_composer_require(path, name, version, scope, pending_lnum)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("composer") == 0 then
		utils.notify_safe("composer not found", L.ERROR, {})
		return
	end

	local pkg_spec = version and (name .. ":" .. version) or name
	local cmd
	if scope == "require-dev" then
		cmd = { "composer", "require", "--dev", pkg_spec }
	else
		cmd = { "composer", "require", pkg_spec }
	end

	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.set_updating) == "function" then
		pcall(st.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			local bufnr = vim.fn.bufnr(path)

			if res and res.code == 0 then
				clear_all_caches()

				local applied = false
				if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) and type(pending_lnum) == "number" then
					applied = apply_single_line_version_edit(bufnr, pending_lnum, name, version)
				end

				if not applied then
					local fresh_lines = read_lines(path)
					if fresh_lines then
						pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, fresh_lines)
						vim.bo[bufnr].modified = false
					end
				end

				utils.notify_safe(("%s@%s installed"):format(name, tostring(version)), L.INFO, {})

				clear_all_caches()

				-- Update installed version in state
				local ok_st, st2 = pcall(require, "lvim-dependencies.state")
				if ok_st and name and version then
					local deps = st2.get_dependencies("composer")
					if deps then
						deps.installed = deps.installed or {}
						deps.installed[name] = { current = version, in_lock = true }
						if type(st2.set_installed) == "function" then
							st2.set_installed("composer", deps.installed)
						end
					end

					if type(st2.add_installed_dependency) == "function" then
						pcall(st2.add_installed_dependency, "composer", name, version, scope)
					end
				end

				local ok_s, s2 = pcall(require, "lvim-dependencies.state")
				if ok_s and type(s2.set_updating) == "function" then
					pcall(s2.set_updating, false)
				end

				if bufnr and bufnr ~= -1 then
					state.buffers = state.buffers or {}
					state.buffers[bufnr] = state.buffers[bufnr] or {}
					state.buffers[bufnr].last_composer_hash = nil
					state.buffers[bufnr].last_changedtick = nil
					state.buffers[bufnr].last_composer_parsed = nil
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
						pcall(chk.invalidate_package_cache, bufnr, "composer", name)
					end
					if ok_chk and type(chk.check_manifest_outdated) == "function" then
						pcall(chk.check_manifest_outdated, bufnr, "composer")
					end
				end, 300)

				-- Poll until outdated data is ready
				local poll_count = 0
				local max_polls = 30
				local function poll_for_outdated()
					poll_count = poll_count + 1

					local deps = state.get_dependencies("composer")
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

							-- ВАЖНО: Това трябва да е добавено!
							state.buffers[bufnr].last_update_completed_at = vim.loop.now()
						end

						local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
						if ok_vt and type(vt.display) == "function" then
							vt.display(bufnr, "composer", { force_full = true })
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
				return
			end

			-- FAIL
			local ok_s, s2 = pcall(require, "lvim-dependencies.state")
			if ok_s and type(s2.set_updating) == "function" then
				pcall(s2.set_updating, false)
			end

			local msg = (res and res.stderr) or ""
			if msg == "" then
				msg = "composer require exited with code " .. tostring(res and res.code or "unknown")
			end
			utils.notify_safe(("composer require failed: %s"):format(msg), L.ERROR, {})

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
				vt.display(bufnr, "composer", { force_full = true })
			end
		end)
	end)
end

local function run_composer_remove(path, name)
	local cwd = vim.fn.fnamemodify(path, ":h")

	if vim.fn.executable("composer") == 0 then
		utils.notify_safe("composer not found", L.ERROR, {})
		return
	end

	local cmd = { "composer", "remove", name }

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
					pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, fresh_lines)
					vim.bo[bufnr].modified = false
				end

				local ok_st, st2 = pcall(require, "lvim-dependencies.state")
				if ok_st and type(st2.remove_installed_dependency) == "function" then
					pcall(st2.remove_installed_dependency, "composer", name)
				end

				local ok_s, s2 = pcall(require, "lvim-dependencies.state")
				if ok_s and type(s2.set_updating) == "function" then
					pcall(s2.set_updating, false)
				end

				if bufnr and bufnr ~= -1 then
					state.buffers = state.buffers or {}
					state.buffers[bufnr] = state.buffers[bufnr] or {}
					state.buffers[bufnr].last_composer_hash = nil
					state.buffers[bufnr].last_changedtick = nil
					state.buffers[bufnr].last_composer_parsed = nil

					-- Mark when update completed for cooldown
					state.buffers[bufnr].last_update_completed_at = vim.loop.now()
				end

				vim.defer_fn(function()
					local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
					if ok_chk and type(chk.invalidate_package_cache) == "function" then
						pcall(chk.invalidate_package_cache, bufnr, "composer", name)
					end
					if ok_chk and type(chk.check_manifest_outdated) == "function" then
						pcall(chk.check_manifest_outdated, bufnr, "composer")
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
					msg = "composer remove exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("composer remove failed: %s"):format(msg), L.ERROR, {})
			end
		end)
	end)
end

function M.update(name, opts)
	if not name or name == "" then
		return { ok = false, msg = "package name required" }
	end
	opts = opts or {}
	local version = opts.version
	if not version or version == "" then
		return { ok = false, msg = "version is required" }
	end

	local scope = opts.scope or "require"
	local valid_scopes = const.SECTION_NAMES.composer or { "require", "require-dev" }
	local scope_valid = false
	for _, s in ipairs(valid_scopes) do
		if scope == s then
			scope_valid = true
			break
		end
	end
	if not scope_valid then
		scope = "require"
	end

	local path = find_composer_json_path()
	if not path then
		return { ok = false, msg = "composer.json not found in project tree" }
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

			-- 1. Update version in buffer
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
		run_composer_require(path, name, version, scope, pending_lnum)
		return { ok = true, msg = "started" }
	end

	-- Non-UI update (direct write)
	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read composer.json" }
	end

	local version_spec = "^" .. tostring(version)
	local section_idx = find_section_index(lines, scope)

	if not section_idx then
		-- Create new section
		local root_end = find_root_end(lines)
		local indent = find_top_level_indent(lines)
		local entry_indent = indent .. "    "

		local prev_idx = find_last_top_level_entry(lines, root_end)
		if prev_idx then
			lines[prev_idx] = ensure_trailing_comma(lines[prev_idx])
		end

		local out = {}
		for i = 1, root_end - 1 do
			out[#out + 1] = lines[i]
		end

		out[#out + 1] = indent .. '"' .. scope .. '": {'
		out[#out + 1] = entry_indent .. '"' .. name .. '": "' .. version_spec .. '"'
		out[#out + 1] = indent .. "}"

		for i = root_end, #lines do
			out[#out + 1] = lines[i]
		end

		local ok_write, werr = write_lines(path, out)
		if not ok_write then
			return { ok = false, msg = "failed to write composer.json: " .. tostring(werr) }
		end

		local bufnr = vim.fn.bufnr(path)
		if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
			pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, out)
			vim.bo[bufnr].modified = false
		end
	else
		local section_end = find_section_end(lines, section_idx)
		local i, ln = find_package_line(lines, section_idx, section_end, name)

		if i and ln then
			-- Replace existing
			local indent = ln:match("^(%s*)") or ""
			local has_comma = ln:match(",%s*$") ~= nil
			local new_line = indent .. '"' .. name .. '": "' .. version_spec .. '"'
			if has_comma then
				new_line = new_line .. ","
			end

			lines[i] = new_line
			local ok_write, werr = write_lines(path, lines)
			if not ok_write then
				return { ok = false, msg = "failed to write composer.json: " .. tostring(werr) }
			end

			apply_buffer_change(path, { start0 = i - 1, end0 = i, lines = { new_line } })
		else
			-- Insert new entry
			local indent = find_entry_indent(lines, section_idx, section_end)
			local new_line = indent .. '"' .. name .. '": "' .. version_spec .. '"'

			local last_idx = find_last_entry_index(lines, section_idx, section_end)
			if last_idx then
				lines[last_idx] = ensure_trailing_comma(lines[last_idx])
			end

			local out = {}
			for k = 1, section_end - 1 do
				out[#out + 1] = lines[k]
			end
			out[#out + 1] = new_line
			for k = section_end, #lines do
				out[#out + 1] = lines[k]
			end

			local ok_write, werr = write_lines(path, out)
			if not ok_write then
				return { ok = false, msg = "failed to write composer.json: " .. tostring(werr) }
			end

			local bufnr = vim.fn.bufnr(path)
			if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
				pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, out)
				vim.bo[bufnr].modified = false
			end
		end
	end

	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.add_installed_dependency) == "function" then
		pcall(st.add_installed_dependency, "composer", name, version, scope)
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
		return { ok = false, msg = "package name required" }
	end
	opts = opts or {}

	local path = find_composer_json_path()
	if not path then
		return { ok = false, msg = "composer.json not found in project tree" }
	end

	if opts.from_ui then
		run_composer_remove(path, name)
		utils.notify_safe(("removing %s..."):format(name), L.INFO, {})
		return { ok = true, msg = "started" }
	end

	-- Non-UI remove
	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read composer.json" }
	end

	local scopes = const.SECTION_NAMES.composer or { "require", "require-dev" }
	for _, scope in ipairs(scopes) do
		local section_idx = find_section_index(lines, scope)
		if section_idx then
			local section_end = find_section_end(lines, section_idx)
			local target_idx = nil
			for i = section_idx + 1, section_end - 1 do
				local ln = lines[i]
				local m_name = ln:match('^%s*"(.-)"%s*:')
				if m_name and tostring(m_name) == tostring(name) then
					target_idx = i
					break
				end
			end

			if target_idx then
				local out = {}
				for i, line in ipairs(lines) do
					if i ~= target_idx then
						out[#out + 1] = line
					end
				end

				local new_section_end = find_section_end(out, section_idx)
				local prev_idx = find_last_entry_index(out, section_idx, new_section_end)
				if prev_idx then
					local has_next = false
					for i = prev_idx + 1, new_section_end - 1 do
						if out[i]:match('^%s*".-"%s*:') then
							has_next = true
							break
						end
					end
					if not has_next then
						out[prev_idx] = remove_trailing_comma(out[prev_idx])
					end
				end

				local ok_write, werr = write_lines(path, out)
				if not ok_write then
					return { ok = false, msg = "failed to write composer.json: " .. tostring(werr) }
				end

				apply_buffer_change(path, { start0 = target_idx - 1, end0 = target_idx, lines = {} })

				local ok_state, st = pcall(require, "lvim-dependencies.state")
				if ok_state and type(st.remove_installed_dependency) == "function" then
					pcall(st.remove_installed_dependency, "composer", name)
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

	return { ok = false, msg = "package not found" }
end

function M.install(_)
	return { ok = true }
end

function M.check_outdated(_)
	return { ok = true }
end

return M
