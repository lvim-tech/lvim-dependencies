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

local function find_pubspec_path()
	local manifest_files = const.MANIFEST_FILES.pubspec or { "pubspec.yaml" }
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

local function find_section_index(lines, section_name)
	for i, ln in ipairs(lines) do
		if ln:match("^%s*" .. vim.pesc(section_name) .. "%s*:") then
			return i
		end
	end
	return nil
end

local function find_section_end(lines, section_idx)
	local section_end = #lines
	for i = section_idx + 1, #lines do
		local ln = lines[i]
		if ln:match("^%S") then
			section_end = i - 1
			break
		end
	end
	return section_end
end

local function replace_package_in_section(lines, section_idx, section_end, pkg_name, new_line)
	for i = section_idx + 1, section_end do
		local ln = lines[i]
		local m_name = ln:match("^%s*([%w%-%_%.]+)%s*:")
		if m_name and tostring(m_name) == tostring(pkg_name) then
			local pkg_indent = ln:match("^(%s*)") or ""
			local pkg_indent_len = #pkg_indent
			local block_end = i
			for j = i + 1, section_end do
				local next_ln = lines[j]
				if not next_ln then
					break
				end
				if next_ln:match("^%S") then
					break
				end
				local next_indent = next_ln:match("^(%s*)") or ""
				if #next_indent > pkg_indent_len then
					block_end = j
				else
					break
				end
			end

			local out = {}
			for k = 1, i - 1 do
				out[#out + 1] = lines[k]
			end
			out[#out + 1] = new_line
			for k = block_end + 1, #lines do
				out[#out + 1] = lines[k]
			end
			return out, true
		end
	end
	return nil, false
end

local function insert_package_in_section(lines, section_idx, new_line)
	local out = {}
	for k = 1, section_idx do
		out[#out + 1] = lines[k]
	end
	out[#out + 1] = new_line
	for k = section_idx + 1, #lines do
		out[#out + 1] = lines[k]
	end
	return out, true
end

local function remove_package_from_section(lines, section_idx, section_end, pkg_name)
	for i = section_idx + 1, section_end do
		local ln = lines[i]
		local m_name = ln:match("^%s*([%w%-%_%.]+)%s*:")
		if m_name and tostring(m_name) == tostring(pkg_name) then
			local pkg_indent = ln:match("^(%s*)") or ""
			local pkg_indent_len = #pkg_indent
			local block_end = i
			for j = i + 1, section_end do
				local next_ln = lines[j]
				if not next_ln then
					break
				end
				if next_ln:match("^%S") then
					break
				end
				local next_indent = next_ln:match("^(%s*)") or ""
				if #next_indent > pkg_indent_len then
					block_end = j
				else
					break
				end
			end

			local out = {}
			for k = 1, i - 1 do
				out[#out + 1] = lines[k]
			end
			for k = block_end + 1, #lines do
				out[#out + 1] = lines[k]
			end
			return out
		end
	end
	return nil
end

local function version_parts(v)
	if not v then
		return nil
	end
	v = tostring(v)
	v = v:gsub("[\"',]", ""):gsub("^%s*", ""):gsub("%s*$", "")
	v = v:gsub("^[%s%~%^><=]+", "")
	local main = v:match("^(%d+%.%d+%.%d+)") or v:match("^(%d+%.%d+)") or v:match("^(%d+)")
	if not main then
		return nil
	end
	local major, minor, patch = main:match("^(%d+)%.(%d+)%.(%d+)")
	if major and minor and patch then
		return { tonumber(major), tonumber(minor), tonumber(patch) }
	end
	local maj_min = main:match("^(%d+)%.(%d+)")
	if maj_min then
		local ma, mi = maj_min:match("^(%d+)%.(%d+)")
		return { tonumber(ma), tonumber(mi), 0 }
	end
	local single = main:match("^(%d+)")
	if single then
		return { tonumber(single), 0, 0 }
	end
	return nil
end

local function compare_version_parts(a, b)
	if not a and not b then
		return 0
	end
	if not a then
		return -1
	end
	if not b then
		return 1
	end
	for i = 1, 3 do
		local ai = a[i] or 0
		local bi = b[i] or 0
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
		current = state.get_installed_version("pubspec", name)
	end

	local pkg = urlencode(name)
	local url = ("https://pub.dev/api/packages/%s"):format(pkg)

	local res = vim.system({ "curl", "-fsS", "--max-time", "10", url }, { text = true }):wait()
	if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
		return nil
	end

	local ok_json, parsed = pcall(vim.json.decode, res.stdout)
	if not ok_json or type(parsed) ~= "table" then
		return nil
	end

	local raw_versions = parsed.versions
	if not raw_versions or type(raw_versions) ~= "table" then
		return nil
	end

	local seen, uniq = {}, {}
	for _, v in ipairs(raw_versions) do
		local ver = nil
		local is_retracted = false

		if type(v) == "table" then
			ver = v.version and tostring(v.version)
			is_retracted = v.retracted == true
		elseif type(v) == "string" then
			ver = tostring(v)
		end

		if ver and not seen[ver] and not is_retracted then
			seen[ver] = true
			uniq[#uniq + 1] = ver
		end
	end

	table.sort(uniq, function(a, b)
		local pa = version_parts(a)
		local pb = version_parts(b)
		local cmp = compare_version_parts(pa, pb)
		if cmp == 0 then
			return a > b
		end
		return cmp == 1
	end)

	return { versions = uniq, current = current }
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

	pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, fresh_lines)

	if saved_cursor then
		pcall(api.nvim_win_set_cursor, cur_win, saved_cursor)
	end

	vim.bo[bufnr].modified = false

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

local function trigger_package_updated()
	api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

-- Run pub get to sync lockfile with pubspec.yaml changes
local function run_pub_get(path, name, version, scope, on_success_msg)
	local lines = read_lines(path)
	local has_flutter = false
	if lines then
		for _, l in ipairs(lines) do
			if l:match("^%s*flutter%s*:") then
				has_flutter = true
				break
			end
		end
	end

	local cmd
	local cwd = vim.fn.fnamemodify(path, ":h")

	if has_flutter and vim.fn.executable("flutter") == 1 then
		cmd = { "flutter", "pub", "get" }
	elseif vim.fn.executable("dart") == 1 then
		cmd = { "dart", "pub", "get" }
	else
		utils.notify_safe("pubspec: neither flutter nor dart CLI available", L.ERROR, {})
		return
	end

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.set_updating) == "function" then
		pcall(state.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			if res and res.code == 0 then
				utils.notify_safe(
					on_success_msg or ("pubspec: %s@%s installed"):format(name, tostring(version)),
					L.INFO,
					{}
				)

				local fresh_lines = read_lines(path)
				if fresh_lines then
					refresh_buffer(path, fresh_lines)
				end

				if name and version and scope then
					local ok_st, st = pcall(require, "lvim-dependencies.state")
					if ok_st and type(st.add_installed_dependency) == "function" then
						pcall(st.add_installed_dependency, "pubspec", name, version, scope)
					end

					vim.defer_fn(function()
						local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.pubspec")
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
										pcall(chk.invalidate_package_cache, buf, "pubspec", name)
									end
									if ok_chk and type(chk.check_manifest_outdated) == "function" then
										pcall(chk.check_manifest_outdated, buf, "pubspec")
									end
								end, 300)
							end
						end
					end, 1500)

					pcall(function()
						vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
						trigger_package_updated()
					end)
				end
			else
				local ok_s, s = pcall(require, "lvim-dependencies.state")
				if ok_s and type(s.set_updating) == "function" then
					pcall(s.set_updating, false)
				end

				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "pub get exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("pubspec: pub get failed. Error: %s"):format(msg), L.ERROR, {})
			end
		end)
	end)
end

-- Run pub remove to remove a package
local function run_pub_remove(path, name)
	local lines = read_lines(path)
	local has_flutter = false
	if lines then
		for _, l in ipairs(lines) do
			if l:match("^%s*flutter%s*:") then
				has_flutter = true
				break
			end
		end
	end

	local cmd
	local cwd = vim.fn.fnamemodify(path, ":h")

	if has_flutter and vim.fn.executable("flutter") == 1 then
		cmd = { "flutter", "pub", "remove", name }
	elseif vim.fn.executable("dart") == 1 then
		cmd = { "dart", "pub", "remove", name }
	else
		utils.notify_safe("pubspec: neither flutter nor dart CLI available", L.ERROR, {})
		return
	end

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.set_updating) == "function" then
		pcall(state.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			if res and res.code == 0 then
				utils.notify_safe(("pubspec: %s removed"):format(name), L.INFO, {})

				local fresh_lines = read_lines(path)
				if fresh_lines then
					refresh_buffer(path, fresh_lines)
				end

				local ok_st, st = pcall(require, "lvim-dependencies.state")
				if ok_st and type(st.remove_installed_dependency) == "function" then
					pcall(st.remove_installed_dependency, "pubspec", name)
				end

				vim.defer_fn(function()
					local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.pubspec")
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
									pcall(chk.invalidate_package_cache, buf, "pubspec", name)
								end
								if ok_chk and type(chk.check_manifest_outdated) == "function" then
									pcall(chk.check_manifest_outdated, buf, "pubspec")
								end
							end, 300)
						end
					end
				end, 1500)

				pcall(function()
					vim.g.lvim_deps_last_updated = name .. "@removed"
					trigger_package_updated()
				end)
			else
				local ok_s, s = pcall(require, "lvim-dependencies.state")
				if ok_s and type(s.set_updating) == "function" then
					pcall(s.set_updating, false)
				end

				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = "pub remove exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("pubspec: pub remove failed. Error: %s"):format(msg), L.ERROR, {})
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

	local scope = opts.scope or "dependencies"
	local valid_scopes = const.SECTION_NAMES.pubspec or { "dependencies", "dev_dependencies" }
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

	local path = find_pubspec_path()
	if not path then
		return { ok = false, msg = "pubspec.yaml not found in project tree" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read pubspec.yaml from disk" }
	end

	local section_idx = find_section_index(lines, scope)
	if not section_idx then
		lines[#lines + 1] = ""
		lines[#lines + 1] = scope .. ":"
		section_idx = #lines - 1
	end

	local section_end = find_section_end(lines, section_idx)
	local pkg_indent = "  "
	local sample_ln = lines[section_idx + 1]
	if sample_ln then
		local s_indent = sample_ln:match("^(%s*)") or ""
		if #s_indent > 0 then
			pkg_indent = s_indent
		end
	end
	local new_line = string.format("%s%s: %s", pkg_indent, name, tostring(version))

	local new_lines, replaced = replace_package_in_section(lines, section_idx, section_end, name, new_line)
	if not replaced then
		new_lines, _ = insert_package_in_section(lines, section_idx, new_line)
	end

	local okw, werr = write_lines(path, new_lines)
	if not okw then
		return { ok = false, msg = "failed to write pubspec.yaml: " .. tostring(werr) }
	end

	if opts.from_ui then
		utils.notify_safe(("pubspec: updating %s to %s..."):format(name, tostring(version)), L.INFO, {})
		run_pub_get(path, name, version, scope)
		return { ok = true, msg = "started" }
	end

	refresh_buffer(path, new_lines)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.add_installed_dependency) == "function" then
		pcall(state.add_installed_dependency, "pubspec", name, version, scope)
	end

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
		trigger_package_updated()
	end)

	utils.notify_safe(("pubspec: %s -> %s"):format(name, tostring(version)), L.INFO, {})

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

	local scope = opts.scope or "dependencies"
	local valid_scopes = const.SECTION_NAMES.pubspec or { "dependencies", "dev_dependencies" }
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

	local path = find_pubspec_path()
	if not path then
		return { ok = false, msg = "pubspec.yaml not found in project tree" }
	end

	if opts.from_ui then
		run_pub_remove(path, name)
		utils.notify_safe(("pubspec: removing %s..."):format(name), L.INFO, {})
		return { ok = true, msg = "started" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read pubspec.yaml from disk" }
	end

	local section_idx = find_section_index(lines, scope)
	if not section_idx then
		return { ok = false, msg = "section " .. scope .. " not found" }
	end

	local section_end = find_section_end(lines, section_idx)
	local new_lines = remove_package_from_section(lines, section_idx, section_end, name)
	if not new_lines then
		return { ok = false, msg = "package " .. name .. " not found in " .. scope }
	end

	local okw, werr = write_lines(path, new_lines)
	if not okw then
		return { ok = false, msg = "failed to write pubspec.yaml: " .. tostring(werr) }
	end

	refresh_buffer(path, new_lines)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.remove_installed_dependency) == "function" then
		pcall(state.remove_installed_dependency, "pubspec", name)
	end

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@removed"
		trigger_package_updated()
	end)

	utils.notify_safe(("pubspec: %s removed"):format(name), L.INFO, {})

	return { ok = true, msg = "removed" }
end

function M.install(_)
	return { ok = true }
end

function M.check_outdated(_)
	return { ok = true }
end

return M
