local decoder = require("lvim-dependencies.libs.decoder")
local state = require("lvim-dependencies.state")
local utils = require("lvim-dependencies.utils")
local clean_version = utils.clean_version

local M = {}

local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end
	local ok, parsed = pcall(function()
		return decoder.parse_json(content)
	end)
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

local function parse_package_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}
	end

	local function strip_comments_and_trim(s)
		if not s then
			return nil
		end

		local t = s:gsub("//.*$", "")
		t = t:gsub("/%*.-%*/", "")
		t = t:gsub(",%s*$", ""):match("^%s*(.-)%s*$")
		if t == "" then
			return nil
		end
		return t
	end

	local function collect_block(start_idx)
		local tbl = {}
		local brace_level = 0
		local started = false
		local last_idx = start_idx

		for i = start_idx, #lines do
			local raw_line = lines[i]
			local line = strip_comments_and_trim(raw_line)
			if not line then
				last_idx = i
			else
				if not started and line:find("{", 1, true) then
					started = true
				end

				for c in line:gmatch(".") do
					if c == "{" then
						brace_level = brace_level + 1
					elseif c == "}" then
						brace_level = brace_level - 1
					end
				end

				for name, ver in line:gmatch("%s*[\"']?([%w%-%_@/%.]+)[\"']?%s*:%s*[\"']([^\"']+)[\"']%s*,?") do
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
				if last and last > i then
					i = last
				end
			elseif lower:match('%s*"?devdependencies"?%s*:') or lower:match('%s*"?dev%-dependencies"?%s*:') then
				local parsed, last = collect_block(i)
				for k, v in pairs(parsed) do
					dev_deps[k] = { raw = v, current = (clean_version(v) or tostring(v)) }
				end
				if last and last > i then
					i = last
				end
			end
		end
		i = i + 1
	end

	return deps, dev_deps
end

local function parse_with_decoder(content, lines)
	local ok, parsed = pcall(function()
		if decoder and type(decoder.parse_json) == "function" then
			return decoder.parse_json(content)
		end
		return vim.fn.json_decode(content)
	end)

	if ok and parsed and type(parsed) == "table" then
		local deps = {}
		local dev_deps = {}
		local optional_deps = {}
		local peer_deps = {}
		local overrides = {}

		local raw_deps = parsed.dependencies or parsed.deps
		local raw_dev = parsed.devDependencies or parsed.dev_dependencies
		local raw_opt = parsed.optionalDependencies
		local raw_peer = parsed.peerDependencies
		local raw_overrides = parsed.overrides or parsed.dependency_overrides

		if raw_deps and type(raw_deps) == "table" then
			for name, val in pairs(raw_deps) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = nil
				if has then
					cur = clean_version(raw) or tostring(raw)
				end
				deps[name] = { raw = raw, current = cur }
			end
		end

		if raw_dev and type(raw_dev) == "table" then
			for name, val in pairs(raw_dev) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = nil
				if has then
					cur = clean_version(raw) or tostring(raw)
				end
				dev_deps[name] = { raw = raw, current = cur }
			end
		end

		if raw_opt and type(raw_opt) == "table" then
			for name, val in pairs(raw_opt) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = nil
				if has then
					cur = clean_version(raw) or tostring(raw)
				end
				optional_deps[name] = { raw = raw, current = cur }
			end
		end

		if raw_peer and type(raw_peer) == "table" then
			for name, val in pairs(raw_peer) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = nil
				if has then
					cur = clean_version(raw) or tostring(raw)
				end
				peer_deps[name] = { raw = raw, current = cur }
			end
		end

		if raw_overrides and type(raw_overrides) == "table" then
			for name, val in pairs(raw_overrides) do
				local raw, has = utils.normalize_entry_val(val)
				local cur = nil
				if has then
					cur = clean_version(raw) or tostring(raw)
				end
				overrides[name] = { raw = raw, current = cur }
			end
		end

		return {
			dependencies = deps,
			devDependencies = dev_deps,
			optionalDependencies = optional_deps,
			peerDependencies = peer_deps,
			overrides = overrides,
		}
	end

	local fb_deps, fb_dev = parse_package_fallback_lines(lines or vim.split(content, "\n"))
	return {
		dependencies = fb_deps or {},
		devDependencies = fb_dev or {},
		optionalDependencies = {},
		peerDependencies = {},
		overrides = {},
	}
end

local function map_source_to_scope(source)
	-- map internal source tags to typical package.json scope names
	if source == "dependencies" then
		return "dependencies"
	elseif source == "dev_dependencies" then
		return "devDependencies"
	elseif source == "optional_dependencies" then
		return "optionalDependencies"
	elseif source == "peer_dependencies" then
		return "peerDependencies"
	elseif source == "overrides" then
		return "overrides"
	end
	return "dependencies"
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
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

	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			pcall(state.save_buffer, bufnr, "package", vim.api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		-- prepare state: ensure + clear manifest container
		if state.ensure_manifest then
			pcall(state.ensure_manifest, "package")
		end
		if state.clear_manifest then
			pcall(state.clear_manifest, "package")
		end

		-- Prefer per-dependency API to capture scopes; fallback to bulk set_installed
		local used_add = false
		if state.add_installed_dependency and type(state.add_installed_dependency) == "function" then
			used_add = true
			for name, info in pairs(installed_dependencies) do
				local scope = map_source_to_scope(info._source or "dependencies")
				pcall(state.add_installed_dependency, "package", name, info.current, scope)
			end
		end

		if not used_add then
			-- build table in expected format { name = { current = "...", scopes = { [scope]=true } } }
			local bulk = {}
			for name, info in pairs(installed_dependencies) do
				local scope = map_source_to_scope(info._source or "dependencies")
				bulk[name] = { current = info.current, scopes = { [scope] = true } }
			end
			if state.set_installed then
				pcall(state.set_installed, "package", bulk)
			end
		end

		-- invalids
		if state.set_invalid then
			pcall(state.set_invalid, "package", invalid_dependencies)
		end

		-- maintain outdated state (checker will refresh)
		if state.set_outdated then
			pcall(state.set_outdated, "package", state.get_dependencies("package").outdated or {})
		end

		-- update buffer cached lines/last run metadata
		if state.update_buffer_lines then
			pcall(state.update_buffer_lines, bufnr, buffer_lines)
		end
		if state.update_last_run then
			pcall(state.update_last_run, bufnr)
		end

		-- attach last parsed snapshot to buffer for caching
		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_package_parsed =
			{ installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false
		local ok_hash, h = pcall(function()
			return vim.fn.sha256(content)
		end)
		if ok_hash then
			state.buffers[bufnr].last_package_hash = h
		end
		state.buffers[bufnr].last_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

		-- render virtual text and trigger checker
		pcall(function()
			local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
			if ok_vt and vt and type(vt.display) == "function" then
				vt.display(bufnr, "package")
			end
		end)

		pcall(function()
			local ok_chk, chk = pcall(require, "lvim-dependencies.actions.check_manifests")
			if ok_chk and chk and type(chk.check_manifest_outdated) == "function" then
				pcall(chk.check_manifest_outdated, bufnr, "package")
			end
		end)
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_package_parsed then
			vim.defer_fn(function()
				pcall(function()
					local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok_vt and vt and type(vt.display) == "function" then
						vt.display(bufnr, "package")
					end
				end)
			end, 10)
			return state.buffers[bufnr].last_package_parsed
		end
	end

	local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table.concat(buffer_lines, "\n")

	local ok_hash, current_hash = pcall(function()
		return vim.fn.sha256(content)
	end)
	if
		ok_hash
		and state.buffers[bufnr].last_package_hash
		and state.buffers[bufnr].last_package_hash == current_hash
	then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_package_parsed then
			vim.defer_fn(function()
				pcall(function()
					local ok_vt, vt = pcall(require, "lvim-dependencies.ui.virtual_text")
					if ok_vt and vt and type(vt.display) == "function" then
						vt.display(bufnr, "package")
					end
				end)
			end, 10)
			return state.buffers[bufnr].last_package_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_package_parsed
	end

	state.buffers[bufnr].parse_scheduled = true

	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			state.buffers[bufnr].parse_scheduled = false
			return
		end

		local fresh_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local fresh_content = table.concat(fresh_lines, "\n")

		local ok_decode, parsed = pcall(function()
			return parse_with_decoder(fresh_content, fresh_lines)
		end)
		if ok_decode and parsed then
			local lock_path = utils.find_lock_for_manifest(bufnr, "package")
			local lock_versions = nil
			if lock_path then
				local lock_content = utils.read_file(lock_path)
				lock_versions = parse_lock_file_from_content(lock_content)
			end

			if lock_versions and type(lock_versions) == "table" then
				for name, info in pairs(parsed.dependencies or {}) do
					if lock_versions[name] then
						info.current = lock_versions[name]
					end
				end
				for name, info in pairs(parsed.devDependencies or {}) do
					if lock_versions[name] then
						info.current = lock_versions[name]
					end
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
					if lock_versions[name] then
						conv.dependencies[name].current = lock_versions[name]
					end
				end
				for name in pairs(conv.devDependencies or {}) do
					if lock_versions[name] then
						conv.devDependencies[name].current = lock_versions[name]
					end
				end
			end

			do_parse_and_update(bufnr, conv, fresh_lines, fresh_content)
		end
	end, 20)

	return state.buffers[bufnr].last_package_parsed
end

M.parse_lock_file_content = function(content)
	return parse_lock_file_from_content(content)
end

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "package.json"
M.manifest_key = "package"

return M
