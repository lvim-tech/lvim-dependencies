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

local M = {}

-- Try parse package-lock / npm-shrinkwrap JSON and extract versions
local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	local ok, parsed = pcall(decoder.parse_json, content)
	if not ok or type(parsed) ~= "table" then
		return nil
	end

	local versions = {}
	if parsed.dependencies and type(parsed.dependencies) == "table" then
		for name, info in pairs(parsed.dependencies) do
			if info and type(info) == "table" and info.version then
				versions[name] = tostring(info.version)
			end
		end
	end

	return versions
end

-- Fallback loose parser for package.json-like content (handles JS comments)
local function parse_package_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}
	end

	local function strip_comments_and_trim(s)
		if not s then return nil end
		-- remove line comments and simple block comments, then trim and drop trailing commas
		local t = s:gsub("//.*$", ""):gsub("/%*.-%*/", ""):gsub(",%s*$", ""):match("^%s*(.-)%s*$")
		if t == "" then return nil end
		return t
	end

	local function collect_block(start_idx)
		local tbl = {}
		local brace_level = 0
		local started = false
		local last_idx = start_idx

		-- scan until block end (no artificial limit)
		for i = start_idx, #lines do
			local raw_line = lines[i]
			local line = strip_comments_and_trim(raw_line)
			if not line then
				last_idx = i
			else
				-- detect object start
				if not started and line:find("{", 1, true) then
					started = true
				end

				-- update brace level
				for c in line:gmatch(".") do
					if c == "{" then
						brace_level = brace_level + 1
					elseif c == "}" then
						brace_level = brace_level - 1
					end
				end

				-- capture simple "name": "version" entries (handles quoted keys)
				for name, ver in line:gmatch([[%s*["']?([%w%-%_@/%.]+)["']?%s*:%s*["']([^"']+)["']%s*,?]]) do
					if name and ver then
						tbl[name] = ver
					end
				end

				last_idx = i
				if started and brace_level <= 0 then
					break
				end
			end
		end

		return tbl, last_idx
	end

	local deps = {}
	local dev_deps = {}
	local i = 1
	while i <= #lines do
		local raw = lines[i]
		if raw ~= nil then
			local lower = raw:lower()
			if lower:match('%s*"?dependencies"?%s*:') then
				local parsed, last = collect_block(i)
				for k, v in pairs(parsed) do
					deps[k] = { raw = v, current = (clean_version(v) or tostring(v)) }
				end
				if last and last > i then i = last end
			elseif lower:match('%s*"?devdependencies"?%s*:') or lower:match('%s*"?dev%-dependencies"?%s*:') then
				local parsed, last = collect_block(i)
				for k, v in pairs(parsed) do
					dev_deps[k] = { raw = v, current = (clean_version(v) or tostring(v)) }
				end
				if last and last > i then i = last end
			end
		end
		i = i + 1
	end

	return deps, dev_deps
end

-- Use JSON decoder when possible; fallback to loose line parser
local function parse_with_decoder(content, lines)
	local ok, parsed = pcall(decoder.parse_json, content)
	if ok and type(parsed) == "table" then
		local deps = {}
		local dev_deps = {}
		local optional_deps = {}
		local peer_deps = {}
		local overrides = {}

		local raw_deps = parsed.dependencies or parsed.deps
		local raw_dev = parsed.devDependencies or parsed.dev_dependencies
		local raw_opt = parsed.optionalDependencies or parsed.optional_dependencies
		local raw_peer = parsed.peerDependencies or parsed.peer_dependencies
		local raw_overrides = parsed.overrides or parsed.dependency_overrides

		local function collect_from_raw(raw_tbl, out_tbl)
			if raw_tbl and type(raw_tbl) == "table" then
				for name, val in pairs(raw_tbl) do
					local raw, has = utils.normalize_entry_val(val)
					local cur = has and (clean_version(raw) or tostring(raw)) or nil
					out_tbl[name] = { raw = raw, current = cur }
				end
			end
		end

		collect_from_raw(raw_deps, deps)
		collect_from_raw(raw_dev, dev_deps)
		collect_from_raw(raw_opt, optional_deps)
		collect_from_raw(raw_peer, peer_deps)
		collect_from_raw(raw_overrides, overrides)

		return {
			dependencies = deps,
			devDependencies = dev_deps,
			optionalDependencies = optional_deps,
			peerDependencies = peer_deps,
			overrides = overrides,
		}
	end

	local fb_deps, fb_dev = parse_package_fallback_lines(lines or split(content, "\n"))
	return {
		dependencies = fb_deps or {},
		devDependencies = fb_dev or {},
		optionalDependencies = {},
		peerDependencies = {},
		overrides = {},
	}
end

local function map_source_to_scope(source)
	if source == "dependencies" then return "dependencies" end
	if source == "dev_dependencies" then return "devDependencies" end
	if source == "optional_dependencies" then return "optionalDependencies" end
	if source == "peer_dependencies" then return "peerDependencies" end
	if source == "overrides" then return "overrides" end
	return "dependencies"
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then return end
	parsed_tables = parsed_tables or {}

	local deps = parsed_tables.dependencies or {}
	local dev_deps = parsed_tables.devDependencies or {}
	local optional_deps = parsed_tables.optionalDependencies or {}
	local peer_deps = parsed_tables.peerDependencies or {}
	local overrides = parsed_tables.overrides or {}

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
	add(optional_deps, "optional_dependencies")
	add(peer_deps, "peer_dependencies")
	add(overrides, "overrides")

	schedule(function()
		if not api.nvim_buf_is_valid(bufnr) then return end

		-- save buffer meta
		if state.save_buffer then
			state.save_buffer(bufnr, "package", api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		-- ensure + clear manifest container
		if state.ensure_manifest then state.ensure_manifest("package") end
		if state.clear_manifest then state.clear_manifest("package") end

		-- prefer per-dependency API to capture scopes; fallback to bulk set_installed
		local used_add = false
		if state.add_installed_dependency then
			used_add = true
			for name, info in pairs(installed_dependencies) do
				local scope = map_source_to_scope(info._source or "dependencies")
				state.add_installed_dependency("package", name, info.current, scope)
			end
		end

		if not used_add then
			local bulk = {}
			for name, info in pairs(installed_dependencies) do
				local scope = map_source_to_scope(info._source or "dependencies")
				bulk[name] = { current = info.current, scopes = { [scope] = true } }
			end
			if state.set_installed then state.set_installed("package", bulk) end
		end

		-- invalids and outdated placeholder
		if state.set_invalid then state.set_invalid("package", invalid_dependencies) end
		if state.set_outdated then state.set_outdated("package", state.get_dependencies("package").outdated or {}) end

		-- update buffer cached lines/last run metadata
		if state.update_buffer_lines then state.update_buffer_lines(bufnr, buffer_lines) end
		if state.update_last_run then state.update_last_run(bufnr) end

		-- attach last parsed snapshot to buffer for caching
		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_package_parsed = { installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		-- compute and store hash
		state.buffers[bufnr].last_package_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		-- render virtual text and trigger checker
		require("lvim-dependencies.ui.virtual_text").display(bufnr, "package")
		require("lvim-dependencies.actions.check_manifests").check_manifest_outdated(bufnr, "package")
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then return nil end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_package_parsed then
			defer_fn(function()
				require("lvim-dependencies.ui.virtual_text").display(bufnr, "package")
			end, 10)
			return state.buffers[bufnr].last_package_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	-- quick hash check
	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_package_hash and state.buffers[bufnr].last_package_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_package_parsed then
			defer_fn(function()
				require("lvim-dependencies.ui.virtual_text").display(bufnr, "package")
			end, 10)
			return state.buffers[bufnr].last_package_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_package_parsed
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
			local lock_path = utils.find_lock_for_manifest(bufnr, "package")
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
			local fb_deps, fb_dev = parse_package_fallback_lines(fresh_lines)
			local conv = {
				dependencies = fb_deps or {},
				devDependencies = fb_dev or {},
				optionalDependencies = {},
				peerDependencies = {},
				overrides = {},
			}

			local lock_path = utils.find_lock_for_manifest(bufnr, "package")
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

	return state.buffers[bufnr].last_package_parsed
end

M.parse_lock_file_content = parse_lock_file_from_content

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "package.json"
M.manifest_key = "package"

return M
