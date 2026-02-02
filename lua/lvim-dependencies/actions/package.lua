local api = vim.api

local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local L = vim.log.levels

local M = {}

-- ------------------------------------------------------------
-- small helpers
-- ------------------------------------------------------------
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

local function write_json(path, data)
	local ok, formatted = pcall(vim.json.encode, data)
	if not ok or not formatted then
		return false, "failed to encode JSON"
	end

	-- Pretty print with jq if available
	if vim.fn.executable("jq") == 1 then
		local esc = formatted:gsub("'", [['"'"']])
		local jq_result = vim.fn.system("printf '%s' '" .. esc .. "' | jq .")
		if vim.v.shell_error == 0 and jq_result ~= "" then
			formatted = jq_result
		end
	end

	local lines = vim.split(formatted, "\n", { plain = true })
	local ok_write, err = pcall(vim.fn.writefile, lines, path)
	if not ok_write then
		return false, tostring(err)
	end
	return true
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

-- ------------------------------------------------------------
-- semver-ish sorting with prerelease support
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- HTTP fetch (vim.system)
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- public API
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- Buffer reload (safe)
-- ------------------------------------------------------------
local function reload_manifest_buffer_if_safe(path)
	local bufnr = vim.fn.bufnr(path)
	if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
		return true
	end

	if vim.bo[bufnr].modified then
		utils.notify_safe(
			("package.json changed on disk, but buffer has unsaved changes. Please save or reload manually: %s"):format(
				path
			),
			L.WARN,
			{}
		)
		return false
	end

	local wins = vim.fn.win_findbuf(bufnr) or {}
	local views = {}
	for _, win in ipairs(wins) do
		if api.nvim_win_is_valid(win) then
			pcall(api.nvim_set_current_win, win)
			local ok, view = pcall(vim.fn.winsaveview)
			if ok and view then
				views[win] = view
			end
		end
	end

	local before_tick = api.nvim_buf_get_changedtick(bufnr)
	pcall(function()
		vim.cmd(("silent! checktime %d"):format(bufnr))
	end)
	local after_tick = api.nvim_buf_get_changedtick(bufnr)
	local changed = after_tick ~= before_tick

	if not changed and not vim.bo[bufnr].modified then
		for _, win in ipairs(wins) do
			if api.nvim_win_is_valid(win) then
				pcall(api.nvim_set_current_win, win)
				pcall(function()
					vim.cmd("silent! edit")
				end)
			end
		end
	end

	for win, view in pairs(views) do
		if api.nvim_win_is_valid(win) then
			pcall(api.nvim_set_current_win, win)
			pcall(vim.fn.winrestview, view)
		end
	end

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

local function run_pm_change(path, argv, kind, package_name_for_recheck)
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

			utils.notify_safe(("Done (%s). Reloading manifest..."):format(kind), L.INFO, {})

			local reloaded = reload_manifest_buffer_if_safe(path)
			if reloaded then
				reparse_and_check_debounced(path, package_name_for_recheck)
			end

			pcall(function()
				if kind == "install" then
					vim.g.lvim_deps_last_updated = package_name_for_recheck or ""
				else
					vim.g.lvim_deps_last_updated = (package_name_for_recheck or "") .. "@removed"
				end
				do_user_autocmd_package_updated()
			end)
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
		run_pm_change(path, argv, "install", name)
		return { ok = true, msg = "started" }
	end

	local data = read_json(path)
	if not data then
		return { ok = false, msg = "unable to read package.json" }
	end

	if not data[scope] then
		data[scope] = {}
	end

	data[scope][name] = "^" .. version

	local ok_write, werr = write_json(path, data)
	if not ok_write then
		return { ok = false, msg = "failed to write package.json: " .. tostring(werr) }
	end

	reload_manifest_buffer_if_safe(path)
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
		run_pm_change(path, argv, "remove", name)
		return { ok = true, msg = "started" }
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

	local data = read_json(path)
	if not data then
		return { ok = false, msg = "unable to read package.json" }
	end

	if not data[scope] or not data[scope][name] then
		return { ok = false, msg = "package " .. name .. " not found in " .. scope }
	end

	data[scope][name] = nil

	local ok_write, werr = write_json(path, data)
	if not ok_write then
		return { ok = false, msg = "failed to write package.json: " .. tostring(werr) }
	end

	reload_manifest_buffer_if_safe(path)
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
