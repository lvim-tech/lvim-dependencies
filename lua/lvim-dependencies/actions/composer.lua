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

	-- Pretty print with 4-space indent (Composer convention)
	if vim.fn.executable("jq") == 1 then
		local esc = formatted:gsub("'", [['"'"']])
		local jq_result = vim.fn.system("printf '%s' '" .. esc .. "' | jq --indent 4 .")
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

-- ------------------------------------------------------------
-- Semver compare (handles v prefix + prerelease)
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

-- ------------------------------------------------------------
-- Fetch versions
-- ------------------------------------------------------------
function M.fetch_versions(name, _)
	if not name or name == "" then
		return nil
	end

	local current = nil
	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.get_installed_version) == "function" then
		current = state.get_installed_version("composer", name)
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

-- ------------------------------------------------------------
-- Buffer refresh
-- ------------------------------------------------------------
local function refresh_buffer(path, data)
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

	local ok, json_str = pcall(vim.json.encode, data)
	if not ok then
		return
	end

	local formatted = json_str
	if vim.fn.executable("jq") == 1 then
		local esc = formatted:gsub("'", [['"'"']])
		local jq_result = vim.fn.system("printf '%s' '" .. esc .. "' | jq --indent 4 .")
		if vim.v.shell_error == 0 and jq_result ~= "" then
			formatted = jq_result
		end
	end

	local lines = vim.split(formatted, "\n", { plain = true })
	pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)

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

-- ------------------------------------------------------------
-- Composer commands
-- ------------------------------------------------------------
local function run_composer_require(path, name, version, scope)
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

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.set_updating) == "function" then
		pcall(state.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			if res and res.code == 0 then
				utils.notify_safe(("%s@%s installed"):format(name, tostring(version)), L.INFO, {})

				local data = read_json(path)
				if data then
					refresh_buffer(path, data)
				end

				if name and version and scope then
					local ok_st, st = pcall(require, "lvim-dependencies.state")
					if ok_st and type(st.add_installed_dependency) == "function" then
						pcall(st.add_installed_dependency, "composer", name, version, scope)
					end

					vim.defer_fn(function()
						local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.composer")
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
										pcall(chk.invalidate_package_cache, buf, "composer", name)
									end
									if ok_chk and type(chk.check_manifest_outdated) == "function" then
										pcall(chk.check_manifest_outdated, buf, "composer")
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
					msg = "composer require exited with code " .. tostring(res and res.code or "unknown")
				end
				utils.notify_safe(("composer require failed: %s"):format(msg), L.ERROR, {})
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

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.set_updating) == "function" then
		pcall(state.set_updating, true)
	end

	vim.system(cmd, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			if res and res.code == 0 then
				utils.notify_safe(("%s removed"):format(name), L.INFO, {})

				local data = read_json(path)
				if data then
					refresh_buffer(path, data)
				end

				local ok_st, st = pcall(require, "lvim-dependencies.state")
				if ok_st and type(st.remove_installed_dependency) == "function" then
					pcall(st.remove_installed_dependency, "composer", name)
				end

				vim.defer_fn(function()
					local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.composer")
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
									pcall(chk.invalidate_package_cache, buf, "composer", name)
								end
								if ok_chk and type(chk.check_manifest_outdated) == "function" then
									pcall(chk.check_manifest_outdated, buf, "composer")
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

	local data = read_json(path)
	if not data then
		return { ok = false, msg = "unable to read composer.json" }
	end

	if not data[scope] then
		data[scope] = {}
	end

	data[scope][name] = "^" .. version

	if opts.from_ui then
		utils.notify_safe(("updating %s to %s..."):format(name, tostring(version)), L.INFO, {})
		run_composer_require(path, name, version, scope)
		return { ok = true, msg = "started" }
	end

	local ok_write, werr = write_json(path, data)
	if not ok_write then
		return { ok = false, msg = "failed to write composer.json: " .. tostring(werr) }
	end

	refresh_buffer(path, data)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.add_installed_dependency) == "function" then
		pcall(state.add_installed_dependency, "composer", name, version, scope)
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
		run_composer_remove(path, name)
		utils.notify_safe(("removing %s..."):format(name), L.INFO, {})
		return { ok = true, msg = "started" }
	end

	local data = read_json(path)
	if not data then
		return { ok = false, msg = "unable to read composer.json" }
	end

	if not data[scope] or not data[scope][name] then
		return { ok = false, msg = "package " .. name .. " not found in " .. scope }
	end

	data[scope][name] = nil

	local ok_write, werr = write_json(path, data)
	if not ok_write then
		return { ok = false, msg = "failed to write composer.json: " .. tostring(werr) }
	end

	refresh_buffer(path, data)

	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.remove_installed_dependency) == "function" then
		pcall(state.remove_installed_dependency, "composer", name)
	end

	pcall(function()
		vim.g.lvim_deps_last_updated = name .. "@removed"
		trigger_package_updated()
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
