local api = vim.api
local fn = vim.fn
local schedule = vim.schedule
local defer_fn = vim.defer_fn
local split = vim.split
local table_concat = table.concat
local tostring = tostring

local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local vt = require("lvim-dependencies.ui.virtual_text")
local checker = require("lvim-dependencies.actions.check_manifests")

local M = {}

local lock_cache = {}

M.clear_lock_cache = function()
	lock_cache = {}
end

local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	-- Try TOML parsing first
	local ok, parsed = pcall(decoder.parse_toml, content)
	if ok and type(parsed) == "table" and parsed.package then
		local versions = {}
		for _, pkg in ipairs(parsed.package) do
			if type(pkg) == "table" and pkg.name and pkg.version then
				versions[pkg.name] = tostring(pkg.version)
			end
		end
		if next(versions) then
			return versions
		end
	end

	-- Fallback: parse [[package]] blocks manually
	local versions = {}
	local lines = split(content, "\n")
	local cur_name = nil
	local cur_version = nil

	for _, ln in ipairs(lines) do
		if ln:match("^%[%[package%]%]") then
			if cur_name and cur_version then
				versions[cur_name] = cur_version
			end
			cur_name = nil
			cur_version = nil
		else
			local name = ln:match('^name%s*=%s*"(.-)"')
			if name then
				cur_name = name
			end
			local ver = ln:match('^version%s*=%s*"(.-)"')
			if ver then
				cur_version = ver
			end
		end
	end

	if cur_name and cur_version then
		versions[cur_name] = cur_version
	end

	if next(versions) then
		return versions
	end

	return nil
end

local function find_cargo_lock_path(bufnr)
	local bufname = api.nvim_buf_get_name(bufnr)
	if not bufname or bufname == "" then
		return nil
	end

	local dir = fn.fnamemodify(bufname, ":h")

	local max_depth = 10
	local depth = 0
	while dir and dir ~= "" and dir ~= "/" and depth < max_depth do
		local lock_path = dir .. "/Cargo.lock"
		if fn.filereadable(lock_path) == 1 then
			return lock_path
		end
		local parent = fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
		depth = depth + 1
	end

	return nil
end

local function get_lock_versions(lock_path)
	if not lock_path then
		return nil
	end

	local stat = vim.loop.fs_stat(lock_path)
	if not stat then
		lock_cache[lock_path] = nil
		return nil
	end

	local mtime = stat.mtime and stat.mtime.sec or 0
	local size = stat.size or 0

	local cached = lock_cache[lock_path]
	if cached and cached.mtime == mtime and cached.size == size and type(cached.versions) == "table" then
		return cached.versions
	end

	local ok, lines = pcall(fn.readfile, lock_path)
	if not ok or type(lines) ~= "table" then
		lock_cache[lock_path] = nil
		return nil
	end

	local content = table_concat(lines, "\n")
	if content == "" then
		lock_cache[lock_path] = nil
		return nil
	end

	local versions = parse_lock_file_from_content(content)

	if versions then
		lock_cache[lock_path] = { mtime = mtime, size = size, versions = versions }
	else
		lock_cache[lock_path] = nil
	end

	return versions
end

local function strip_comments_and_trim(s)
	if not s then
		return nil
	end
	local t = s:gsub("#.*$", ""):match("^%s*(.-)%s*$")
	if t == "" then
		return nil
	end
	return t
end

local function parse_crates_from_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}, {}
	end

	local deps = {}
	local dev_deps = {}
	local build_deps = {}

	local current_section = nil
	local i = 1

	while i <= #lines do
		local raw = lines[i]
		local line = strip_comments_and_trim(raw)

		if line then
			if line:match("^%[dependencies%]$") then
				current_section = "dependencies"
			elseif line:match("^%[dev%-dependencies%]$") then
				current_section = "dev-dependencies"
			elseif line:match("^%[build%-dependencies%]$") then
				current_section = "build-dependencies"
			elseif line:match("^%[") then
				current_section = nil
			elseif current_section then
				local name, rhs = line:match("^([%w%-%_]+)%s*=%s*(.+)$")
				if name and rhs then
					rhs = rhs:match("^%s*(.-)%s*$")
					local ver = nil

					if rhs:match("^{") then
						ver = rhs:match('version%s*=%s*"(.-)"')
					else
						ver = rhs:match('^"(.-)"')
					end

					if ver then
						local entry = { raw = ver, current = clean_version(ver) or ver }
						if current_section == "dependencies" then
							deps[name] = entry
						elseif current_section == "dev-dependencies" then
							dev_deps[name] = entry
						elseif current_section == "build-dependencies" then
							build_deps[name] = entry
						end
					end
				end
			end
		end

		i = i + 1
	end

	return deps, dev_deps, build_deps
end

local function parse_with_decoder(content, lines)
	local ok, parsed = pcall(decoder.parse_toml, content)
	if ok and type(parsed) == "table" then
		local deps = {}
		local dev_deps = {}
		local build_deps = {}

		local raw_deps = parsed.dependencies
		local raw_dev = parsed["dev-dependencies"]
		local raw_build = parsed["build-dependencies"]

		if raw_deps and type(raw_deps) == "table" then
			for name, val in pairs(raw_deps) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = has and (clean_version(raw) or tostring(raw)) or nil
				deps[name] = { raw = raw, current = cur }
			end
		end
		if raw_dev and type(raw_dev) == "table" then
			for name, val in pairs(raw_dev) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = has and (clean_version(raw) or tostring(raw)) or nil
				dev_deps[name] = { raw = raw, current = cur }
			end
		end
		if raw_build and type(raw_build) == "table" then
			for name, val in pairs(raw_build) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = has and (clean_version(raw) or tostring(raw)) or nil
				build_deps[name] = { raw = raw, current = cur }
			end
		end

		return { dependencies = deps, devDependencies = dev_deps, buildDependencies = build_deps }
	end

	local fb_deps, fb_dev, fb_build = parse_crates_from_lines(lines or split(content, "\n"))
	return { dependencies = fb_deps or {}, devDependencies = fb_dev or {}, buildDependencies = fb_build or {} }
end

local function apply_lock_versions(parsed, lock_versions)
	if not lock_versions or type(lock_versions) ~= "table" then
		return
	end

	local function apply(tbl)
		for name, info in pairs(tbl or {}) do
			if lock_versions[name] then
				info.current = lock_versions[name]
				info.in_lock = true
			else
				info.in_lock = false
			end
		end
	end

	apply(parsed.dependencies)
	apply(parsed.devDependencies)
	apply(parsed.buildDependencies)
end

local function is_update_loading(bufnr)
	return state.buffers
		and state.buffers[bufnr]
		and state.buffers[bufnr].is_loading == true
		and state.buffers[bufnr].pending_dep ~= nil
end

local function is_checking_single_package(bufnr)
	return state.buffers and state.buffers[bufnr] and state.buffers[bufnr].checking_single_package ~= nil
end

local function guarded_display(bufnr, manifest_key)
	if is_update_loading(bufnr) then
		return
	end
	vt.display(bufnr, manifest_key)
end

local function guarded_check_outdated(bufnr, manifest_key)
	if is_update_loading(bufnr) then
		return
	end
	checker.check_manifest_outdated(bufnr, manifest_key)
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end

	parsed_tables = parsed_tables or {}

	local deps = parsed_tables.dependencies or {}
	local dev_deps = parsed_tables.devDependencies or {}
	local build_deps = parsed_tables.buildDependencies or {}

	local installed_dependencies = {}
	local invalid_dependencies = {}

	local function add(tbl, source)
		for name, info in pairs(tbl or {}) do
			if installed_dependencies[name] then
				invalid_dependencies[name] = { diagnostic = "DUPLICATED" }
			end

			installed_dependencies[name] = {
				current = info.current,
				raw = info.raw,
				in_lock = info.in_lock,
				_source = source,
			}
		end
	end

	add(deps, "dependencies")
	add(dev_deps, "dev-dependencies")
	add(build_deps, "build-dependencies")

	schedule(function()
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			state.save_buffer(bufnr, "crates", api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		state.ensure_manifest("crates")
		state.clear_manifest("crates")

		local bulk = {}
		for name, info in pairs(installed_dependencies) do
			local scope = info._source or "dependencies"
			bulk[name] = {
				current = info.current,
				raw = info.raw,
				in_lock = info.in_lock == true,
				scopes = { [scope] = true },
			}
		end
		state.set_installed("crates", bulk)

		state.set_invalid("crates", invalid_dependencies)
		state.set_outdated("crates", state.get_dependencies("crates").outdated or {})

		state.update_buffer_lines(bufnr, buffer_lines)
		state.update_last_run(bufnr)

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_crates_parsed = { installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		state.buffers[bufnr].last_crates_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		-- Call display and check_outdated AFTER state is updated (like composer does)
		if not is_checking_single_package(bufnr) then
			guarded_display(bufnr, "crates")
			guarded_check_outdated(bufnr, "crates")
		end
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	if is_checking_single_package(bufnr) then
		return state.buffers[bufnr].last_crates_parsed
	end

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_crates_parsed then
			defer_fn(function()
				guarded_display(bufnr, "crates")
			end, 10)
			return state.buffers[bufnr].last_crates_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_crates_hash and state.buffers[bufnr].last_crates_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_crates_parsed then
			defer_fn(function()
				guarded_display(bufnr, "crates")
			end, 10)
			return state.buffers[bufnr].last_crates_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_crates_parsed
	end

	state.buffers[bufnr].parse_scheduled = true

	defer_fn(function()
		if not api.nvim_buf_is_valid(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		if is_checking_single_package(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		local fresh_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table_concat(fresh_lines, "\n")

		local ok_decode, parsed = pcall(parse_with_decoder, fresh_content, fresh_lines)
		if not (ok_decode and parsed) then
			local fb_deps, fb_dev, fb_build = parse_crates_from_lines(fresh_lines)
			parsed =
				{ dependencies = fb_deps or {}, devDependencies = fb_dev or {}, buildDependencies = fb_build or {} }
		end

		-- Find and apply lock versions
		local lock_path = find_cargo_lock_path(bufnr)
		local lock_versions = lock_path and get_lock_versions(lock_path) or nil
		apply_lock_versions(parsed, lock_versions)

		do_parse_and_update(bufnr, parsed, fresh_lines, fresh_content)
	end, 20)

	return state.buffers[bufnr].last_crates_parsed
end

M.parse_lock_file_content = parse_lock_file_from_content

M.parse_lock_file_path = function(lock_path)
	local ok, lines = pcall(fn.readfile, lock_path)
	if not ok or type(lines) ~= "table" then
		return nil
	end
	local content = table_concat(lines, "\n")
	return parse_lock_file_from_content(content)
end

M.filename = "Cargo.toml"
M.manifest_key = "crates"

return M
