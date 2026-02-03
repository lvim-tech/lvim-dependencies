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
	return (str:gsub("[^%w%-._~@/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_package_json_path()
	local manifest_files = const.MANIFEST_FILES.package or { "package.json" }
	local cwd = vim.fn.getcwd()
	local found = vim.fs.find(manifest_files, { upward = true, path = cwd, type = "file" })
	return found and found[1] or nil
end

local function read_json(path)
	local ok, content = pcall(vim.fn.readfile, path)
	if not ok or type(content) ~= "table" then
		return nil
	end
	local text = table.concat(content, "\n")
	local ok_json, data = pcall(vim.json.decode, text)
	if not ok_json or type(data) ~= "table" then
		return nil
	end
	return data
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

local function get_installed_version_from_node_modules(name)
	local cwd = vim.fn.getcwd()
	local pkg_path = cwd .. "/node_modules/" .. name .. "/package.json"

	if vim.fn.filereadable(pkg_path) ~= 1 then
		return nil
	end

	local data = read_json(pkg_path)
	if data and data.version then
		return tostring(data.version)
	end

	return nil
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
		return { major = tonumber(major) or 0, minor = tonumber(minor) or 0, patch = tonumber(patch) or 0, pre = pre }
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

local function sort_versions_desc(versions)
	table.sort(versions, function(a, b)
		local pa = parse_semver(a)
		local pb = parse_semver(b)
		local cmp = compare_semver(pa, pb)
		if cmp == 0 then
			return tostring(a) > tostring(b)
		end
		return cmp == 1
	end)
end

local function curl_get_json(url)
	local res = vim.system({ "curl", "-fsS", "--max-time", "10", url }, { text = true }):wait()
	if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
		return nil
	end
	local ok_json, parsed = pcall(vim.json.decode, res.stdout)
	if not ok_json or type(parsed) ~= "table" then
		return nil
	end
	return parsed
end

local function do_user_autocmd_package_updated()
	api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

function M.fetch_versions(name, _)
	if not name or name == "" then
		return nil
	end

	local current = get_installed_version_from_node_modules(name)

	if not current then
		local ok_state, st = pcall(require, "lvim-dependencies.state")
		if ok_state and type(st.get_installed_version) == "function" then
			current = st.get_installed_version("package", name)
		end
	end

	local encoded_name = urlencode(name)

	local parsed = curl_get_json(("https://registry.npmjs.org/%s?fields=versions"):format(encoded_name))
	if not parsed or type(parsed.versions) ~= "table" then
		parsed = curl_get_json(("https://registry.npmjs.org/%s"):format(encoded_name))
	end
	if not parsed or type(parsed.versions) ~= "table" then
		return nil
	end

	local uniq = {}
	for ver, _ in pairs(parsed.versions) do
		if type(ver) == "string" then
			uniq[#uniq + 1] = ver
		end
	end
	if #uniq == 0 then
		return nil
	end

	sort_versions_desc(uniq)
	return { versions = uniq, current = current }
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

local function extract_version_from_line(line)
	if not line then
		return nil
	end
	local v = line:match(':%s*"(.-)"')
	return v and vim.trim(v) or nil
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

local function replace_package_in_section(lines, section_idx, section_end, pkg_name, version_spec)
	local i, ln = find_package_line(lines, section_idx, section_end, pkg_name)
	if not i or not ln then
		return nil, false, nil
	end

	local indent = ln:match("^(%s*)") or ""
	local has_comma = ln:match(",%s*$") ~= nil
	local new_line = indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"'
	if has_comma then
		new_line = new_line .. ","
	end

	local out = {}
	for k = 1, i - 1 do
		out[#out + 1] = lines[k]
	end
	out[#out + 1] = new_line
	for k = i + 1, #lines do
		out[#out + 1] = lines[k]
	end

	local change = { start0 = i - 1, end0 = i, lines = { new_line } }
	return out, true, change
end

local function insert_package_in_section(lines, section_idx, section_end, pkg_name, version_spec)
	local indent = find_entry_indent(lines, section_idx, section_end)
	local new_line = indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"'

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

	local change = { start0 = section_end - 1, end0 = section_end - 1, lines = { new_line } }
	return out, true, change
end

local function remove_package_from_section(lines, section_idx, section_end, pkg_name)
	local target_idx = nil
	for i = section_idx + 1, section_end - 1 do
		local ln = lines[i]
		local m_name = ln:match('^%s*"(.-)"%s*:')
		if m_name and tostring(m_name) == tostring(pkg_name) then
			target_idx = i
			break
		end
	end
	if not target_idx then
		return nil, nil
	end

	local out = {}
	for k = 1, target_idx - 1 do
		out[#out + 1] = lines[k]
	end
	for k = target_idx + 1, #lines do
		out[#out + 1] = lines[k]
	end

	local new_section_end = find_section_end(out, section_idx)
	local prev_idx = find_last_entry_index(out, section_idx, new_section_end)
	if prev_idx and prev_idx < new_section_end - 1 then
		local next_idx = nil
		for i = prev_idx + 1, new_section_end - 1 do
			if out[i]:match('^%s*".-"%s*:') then
				next_idx = i
				break
			end
		end
		if not next_idx then
			out[prev_idx] = remove_trailing_comma(out[prev_idx])
		end
	end

	local change = { start0 = target_idx - 1, end0 = target_idx, lines = {} }
	return out, change
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

local function add_section_with_package(lines, section_name, pkg_name, version_spec)
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

	out[#out + 1] = indent .. '"' .. section_name .. '": {'
	out[#out + 1] = entry_indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"'
	out[#out + 1] = indent .. "}"

	for i = root_end, #lines do
		out[#out + 1] = lines[i]
	end

	local section_idx = root_end
	local section_end = root_end + 2
	local change = {
		start0 = section_idx - 1,
		end0 = section_idx - 1,
		lines = { indent .. '"' .. section_name .. '": {', entry_indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"', indent .. "}" },
	}
	return out, section_idx, section_end, change
end

local function apply_package_update(path, name, version, scope)
	local lines = read_lines(path)
	if not lines then
		return false, "unable to read package.json"
	end

	local version_spec = "^" .. tostring(version)
	local section_idx = find_section_index(lines, scope)
	local section_end = nil
	local change = nil
	local new_lines = nil

	if not section_idx then
		new_lines, section_idx, section_end, change = add_section_with_package(lines, scope, name, version_spec)
	else
		section_end = find_section_end(lines, section_idx)
		local i, ln = find_package_line(lines, section_idx, section_end, name)
		if i and ln then
			local current_version = extract_version_from_line(ln)
			if current_version and tostring(current_version) == tostring(version_spec) then
				return false, "version unchanged"
			end
		end

		local replaced = false
		new_lines, replaced, change = replace_package_in_section(lines, section_idx, section_end, name, version_spec)
		if not replaced then
			new_lines, _, change = insert_package_in_section(lines, section_idx, section_end, name, version_spec)
		end
	end

	local ok_write, werr = write_lines(path, new_lines)
	if not ok_write then
		return false, "failed to write package.json: " .. tostring(werr)
	end

	apply_buffer_change(path, change)
	return true
end

local function apply_package_remove(path, name)
	local lines = read_lines(path)
	if not lines then
		return false, "unable to read package.json"
	end

	local scopes = const.SECTION_NAMES.package or { "dependencies", "devDependencies" }
	local new_lines = nil
	local change = nil

	for _, scope in ipairs(scopes) do
		local section_idx = find_section_index(lines, scope)
		if section_idx then
			local section_end = find_section_end(lines, section_idx)
			new_lines, change = remove_package_from_section(lines, section_idx, section_end, name)
			if new_lines then
				break
			end
		end
	end

	if not new_lines then
		return false, "package not found"
	end

	local ok_write, werr = write_lines(path, new_lines)
	if not ok_write then
		return false, "failed to write package.json: " .. tostring(werr)
	end

	apply_buffer_change(path, change)
	return true
end

local function reparse_and_check_debounced(path, updated_package_name)
	local bufnr = vim.fn.bufnr(path)
	if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
		return
	end

	vim.defer_fn(function()
		local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.package")
		if ok_parser and type(parser.parse_buffer) == "function" then
			pcall(parser.parse_buffer, bufnr)
		end
	end, 250)

	vim.defer_fn(function()
		local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
		if ok_chk and type(chk.invalidate_package_cache) == "function" and updated_package_name then
			pcall(chk.invalidate_package_cache, bufnr, "package", updated_package_name)
		end
		if ok_chk and type(chk.check_manifest_outdated) == "function" then
			pcall(chk.check_manifest_outdated, bufnr, "package")
		end
	end, 1200)
end

local function set_updating_flag(v)
	local ok_state, st = pcall(require, "lvim-dependencies.state")
	if ok_state and type(st.set_updating) == "function" then
		pcall(st.set_updating, v)
	end
end

local function get_preferred_pm()
	if vim.fn.executable("pnpm") == 1 then
		return "pnpm"
	end
	if vim.fn.executable("yarn") == 1 then
		return "yarn"
	end
	if vim.fn.executable("npm") == 1 then
		return "npm"
	end
	return nil
end

local function pm_install_cmd(pm, pkg_spec, scope)
	if scope == "devDependencies" then
		if pm == "yarn" then
			return { "yarn", "add", "--dev", pkg_spec }
		elseif pm == "pnpm" then
			return { "pnpm", "add", "-D", pkg_spec }
		else
			return { "npm", "install", "--save-dev", pkg_spec }
		end
	end

	if pm == "yarn" then
		return { "yarn", "add", pkg_spec }
	elseif pm == "pnpm" then
		return { "pnpm", "add", pkg_spec }
	else
		return { "npm", "install", "--save", pkg_spec }
	end
end

local function pm_remove_cmd(pm, name)
	if pm == "yarn" then
		return { "yarn", "remove", name }
	elseif pm == "pnpm" then
		return { "pnpm", "remove", name }
	else
		return { "npm", "uninstall", name }
	end
end

local function run_pm_change(path, argv, kind, payload)
	local cwd = vim.fn.fnamemodify(path, ":h")

	set_updating_flag(true)
	utils.notify_safe(("Running %s..."):format(table.concat(argv, " ")), L.INFO, {})

	vim.system(argv, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			set_updating_flag(false)

			if not res or res.code ~= 0 then
				local msg = (res and res.stderr) or ""
				if msg == "" then
					msg = ("%s exited with code %s"):format(kind, tostring(res and res.code or "unknown"))
				end
				utils.notify_safe(msg, L.ERROR, {})
				return
			end

			if kind == "install" and payload and payload.name and payload.version and payload.scope then
				apply_package_update(path, payload.name, payload.version, payload.scope)
				reparse_and_check_debounced(path, payload.name)
				pcall(function()
					vim.g.lvim_deps_last_updated = payload.name .. "@" .. tostring(payload.version)
					do_user_autocmd_package_updated()
				end)
			elseif kind == "remove" and payload and payload.name then
				apply_package_remove(path, payload.name)
				reparse_and_check_debounced(path, payload.name)
				pcall(function()
					vim.g.lvim_deps_last_updated = payload.name .. "@removed"
					do_user_autocmd_package_updated()
				end)
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
	local valid_scopes = const.SECTION_NAMES.package or { "dependencies", "devDependencies" }
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

	local path = find_package_json_path()
	if not path then
		return { ok = false, msg = "package.json not found in project tree" }
	end

	if opts.from_ui then
		local pm = get_preferred_pm()
		if not pm then
			utils.notify_safe("npm/yarn/pnpm not found", L.ERROR, {})
			return { ok = false, msg = "pm not found" }
		end

		local pkg_spec = ("%s@%s"):format(name, tostring(version))
		local argv = pm_install_cmd(pm, pkg_spec, scope)
		run_pm_change(path, argv, "install", { name = name, version = version, scope = scope })
		return { ok = true, msg = "started" }
	end

	local ok_apply, err = apply_package_update(path, name, version, scope)
	if not ok_apply and err == "version unchanged" then
		return { ok = true, msg = "unchanged" }
	end
	if not ok_apply then
		return { ok = false, msg = err }
	end

	reparse_and_check_debounced(path, name)

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
		do_user_autocmd_package_updated()
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

	local path = find_package_json_path()
	if not path then
		return { ok = false, msg = "package.json not found in project tree" }
	end

	if opts.from_ui then
		local pm = get_preferred_pm()
		if not pm then
			utils.notify_safe("npm/yarn/pnpm not found", L.ERROR, {})
			return { ok = false, msg = "pm not found" }
		end

		local argv = pm_remove_cmd(pm, name)
		run_pm_change(path, argv, "remove", { name = name })
		return { ok = true, msg = "started" }
	end

	local ok_remove, err = apply_package_remove(path, name)
	if not ok_remove then
		return { ok = false, msg = err }
	end

	reparse_and_check_debounced(path, name)

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@removed"
		do_user_autocmd_package_updated()
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
