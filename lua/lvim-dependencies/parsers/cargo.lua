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

-- Try to parse Cargo.lock or similar: prefer TOML, then JSON, otherwise fallback
local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	local parsed = nil
	local ok, res = pcall(decoder.parse_toml, content)
	if ok and type(res) == "table" then
		parsed = res
	else
		ok, res = pcall(decoder.parse_json, content)
		if ok and type(res) == "table" then
			parsed = res
		end
	end

	if parsed and type(parsed) == "table" then
		local versions = {}
		local function collect(tbl)
			if type(tbl) ~= "table" then return end
			for _, pkg in ipairs(tbl) do
				if type(pkg) == "table" and pkg.name and pkg.version then
					versions[pkg.name] = tostring(pkg.version)
				end
			end
		end
		collect(parsed.package)
		collect(parsed["packages-dev"])
		if next(versions) then
			return versions
		end
	end

	-- fallback: scan for [[package]] blocks or top-level name/version pairs
	local versions = {}
	local lines = split(content, "\n")
	local in_pkg = false
	local cur_name = nil
	for _, ln in ipairs(lines) do
		if ln:match("^%s*%[%[%s*package%s*%]%]") then
			in_pkg = true
			cur_name = nil
		elseif in_pkg then
			local name = ln:match("^%s*name%s*=%s*[\"']?(.-)[\"']?%s*$")
			if name then
				cur_name = name
			end
			local ver = ln:match("^%s*version%s*=%s*[\"']?(.-)[\"']?%s*$")
			if ver and cur_name then
				versions[cur_name] = tostring(ver)
			end
			if ln:match("^%s*%[") and not ln:match("^%s*%[%[") then
				in_pkg = false
				cur_name = nil
			end
		else
			local name = ln:match("^%s*name%s*=%s*[\"']?(.-)[\"']?%s*$")
			local ver = ln:match("^%s*version%s*=%s*[\"']?(.-)[\"']?%s*$")
			if name and ver then
				versions[name] = tostring(ver)
			end
		end
	end

	if next(versions) then
		return versions
	end

	return nil
end

local function strip_comments_and_trim(s)
	if not s then return nil end
	local t = s:gsub("//.*$", ""):gsub("/%*.-%*/", ""):gsub(",%s*$", ""):match("^%s*(.-)%s*$")
	if t == "" then return nil end
	return t
end

local function parse_crates_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}
	end

	local function collect_table(start_idx)
		local tbl = {}
		local i = start_idx + 1
		while i <= #lines do
			local raw = lines[i]
			local line = strip_comments_and_trim(raw)
			if not line then
				i = i + 1
			else
				if line:match("^%[") then
					break
				end
				-- name = "version" or name = { version = "..." , ... }
				local name, rhs = line:match("^%s*([%w%-%_]+)%s*=%s*(.+)$")
				if name and rhs then
					-- remove trailing comma if present
					rhs = rhs:gsub(",%s*$", ""):match("^%s*(.-)%s*$")
					-- table form
					local ver = rhs:match('version%s*=%s*[\'"]?(.-)[\'"]?$')
					if not ver then
						-- plain string form "1.2.3" or '1.2.3'
						ver = rhs:match('^[\'"]?(.-)[\'"]$')
					end
					if ver then
						tbl[name] = ver
					end
				end
				i = i + 1
			end
		end
		return tbl
	end

	local deps = {}
	local dev_deps = {}
	local i = 1
	while i <= #lines do
		local raw = lines[i]
		if raw then
			local lower = raw:lower()
			if lower:match("^%s*%[dependencies%]%s*$") then
				local parsed = collect_table(i)
				for k, v in pairs(parsed) do
					local cur = clean_version(v) or tostring(v)
					deps[k] = { raw = v, current = cur }
				end
			elseif lower:match("^%s*%[dev%-dependencies%]%s*$") then
				local parsed = collect_table(i)
				for k, v in pairs(parsed) do
					local cur = clean_version(v) or tostring(v)
					dev_deps[k] = { raw = v, current = cur }
				end
			end
		end
		i = i + 1
	end

	return deps, dev_deps
end

local function parse_with_decoder(content, lines)
	-- prefer TOML parsing for Cargo manifests
	local ok, parsed = pcall(decoder.parse_toml, content)
	if ok and type(parsed) == "table" then
		local deps = {}
		local dev_deps = {}
		local raw_deps = parsed.dependencies or parsed["dependencies"]
		local raw_dev = parsed["dev-dependencies"] or parsed["dev_dependencies"] or parsed["dev-dependencies"]
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
		return { dependencies = deps, devDependencies = dev_deps }
	end

	local fb_deps, fb_dev = parse_crates_fallback_lines(lines or split(content, "\n"))
	return { dependencies = fb_deps or {}, devDependencies = fb_dev or {} }
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then return end
	parsed_tables = parsed_tables or {}

	local deps = parsed_tables.dependencies or {}
	local dev_deps = parsed_tables.devDependencies or {}

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
				_source = source,
			}
		end
	end

	add(deps, "dependencies")
	add(dev_deps, "dev_dependencies")

	schedule(function()
		if not api.nvim_buf_is_valid(bufnr) then return end

		if state.save_buffer then
			state.save_buffer(bufnr, "crates", api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		if state.set_installed then
			state.set_installed("crates", installed_dependencies)
		elseif state.set_dependencies and type(state.set_dependencies) == "function" then
			local result = {
				lines = buffer_lines,
				installed = installed_dependencies,
				outdated = {},
				invalid = invalid_dependencies,
			}
			state.set_dependencies("crates", result)
		end

		if state.set_invalid then state.set_invalid("crates", invalid_dependencies) end
		if state.set_outdated then state.set_outdated("crates", state.get_dependencies("crates").outdated or {}) end

		if state.update_buffer_lines then state.update_buffer_lines(bufnr, buffer_lines) end
		if state.update_last_run then state.update_last_run(bufnr) end

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_crates_parsed = { installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		state.buffers[bufnr].last_crates_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		vt.display(bufnr, "crates")
		checker.check_manifest_outdated(bufnr, "crates")
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then return nil end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_crates_parsed then
			defer_fn(function() vt.display(bufnr, "crates") end, 10)
			return state.buffers[bufnr].last_crates_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_crates_hash and state.buffers[bufnr].last_crates_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_crates_parsed then
			defer_fn(function() vt.display(bufnr, "crates") end, 10)
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

		local fresh_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table_concat(fresh_lines, "\n")

		local ok_decode, parsed = pcall(parse_with_decoder, fresh_content, fresh_lines)
		if ok_decode and parsed then
			local lock_path = utils.find_lock_for_manifest(bufnr, "crates")
			local lock_versions = nil
			if lock_path then
				local lock_content = utils.read_file(lock_path)
				lock_versions = parse_lock_file_from_content(lock_content)
			end

			if lock_versions and type(lock_versions) == "table" then
				for name, info in pairs(parsed.dependencies or {}) do
					if lock_versions[name] then info.current = lock_versions[name] end
				end
				for name, info in pairs(parsed.devDependencies or {}) do
					if lock_versions[name] then info.current = lock_versions[name] end
				end
			end

			do_parse_and_update(bufnr, parsed, fresh_lines, fresh_content)
		else
			local fb_deps, fb_dev = parse_crates_fallback_lines(fresh_lines)
			local conv = { dependencies = fb_deps or {}, devDependencies = fb_dev or {} }

			local lock_path = utils.find_lock_for_manifest(bufnr, "crates")
			local lock_versions = nil
			if lock_path then
				local lock_content = utils.read_file(lock_path)
				lock_versions = parse_lock_file_from_content(lock_content)
			end
			if lock_versions and type(lock_versions) == "table" then
				for name in pairs(conv.dependencies or {}) do
					if lock_versions[name] then conv.dependencies[name].current = lock_versions[name] end
				end
				for name in pairs(conv.devDependencies or {}) do
					if lock_versions[name] then conv.devDependencies[name].current = lock_versions[name] end
				end
			end

			do_parse_and_update(bufnr, conv, fresh_lines, fresh_content)
		end
	end, 20)

	return state.buffers[bufnr].last_crates_parsed
end

M.parse_lock_file_content = parse_lock_file_from_content

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "Cargo.toml"
M.manifest_key = "crates"

return M
