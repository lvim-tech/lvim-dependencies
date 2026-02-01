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

local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return nil
	end

	-- try structured parse (YAML/JSON)
	local parsed = nil
	local ok, res = pcall(decoder.parse_yaml, content)
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
		if parsed.packages and type(parsed.packages) == "table" then
			for name, info in pairs(parsed.packages) do
				if info and type(info) == "table" and info.version then
					versions[name] = tostring(info.version)
				end
			end
		end
		if next(versions) then
			return versions
		end
	end

	-- fallback: simple line-based scan
	local versions = {}
	local lines = split(content, "\n")
	for i = 1, #lines do
		local ln = lines[i]
		local name = ln:match("^%s*([%w%-%_@/%.]+)%s*:%s*$")
		if name then
			for j = i + 1, #lines do
				local vln = lines[j]
				local ver = vln:match('^%s*version%s*:%s*"?(.-)"?%s*$')
				if ver and ver ~= "" then
					versions[name] = tostring(ver)
					break
				end
				-- stop when block ends (no indent)
				if vln and not vln:match("^%s") then
					break
				end
			end
		end
	end

	if next(versions) then
		return versions
	end

	return nil
end

local function looks_like_platform_or_nonpub_entry(val_string, lookahead_lines)
	if val_string and val_string:match("%s*sdk%s*:") then
		return true
	end
	if val_string and (val_string:match("^%s*path%s*:") or val_string:match("^%s*git%s*:")) then
		return true
	end

	if lookahead_lines and type(lookahead_lines) == "table" then
		for _, l in ipairs(lookahead_lines) do
			if l:match("%s*sdk%s*:") or l:match("%s*path%s*:") or l:match("%s*git%s*:") then
				return true
			end
		end
	end
	return false
end

local function parse_pubspec_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}
	end

	local function strip_comments_and_trim(s)
		if not s then
			return nil
		end
		local t = s:gsub("%s*#.*$", "")
		t = t:gsub(",%s*$", ""):match("^%s*(.-)%s*$")
		if t == "" then
			return nil
		end
		return t
	end

	local function collect_block(start_idx)
		local tbl = {}
		local i = start_idx + 1
		while i <= #lines do
			local raw = lines[i]
			local line = strip_comments_and_trim(raw)
			if not line then
				i = i + 1
			else
				-- block ends when no leading indent
				if not line:match("^%s") then
					break
				end

				local name, val = line:match("^%s*([%w%-%_@/%.]+)%s*:%s*(.-)%s*$")
				if name then
					if val and val ~= "" and not val:match("^%s*[{%[]") then
						if not looks_like_platform_or_nonpub_entry(val) then
							val = val:gsub("^[\"']", ""):gsub("[\"']%s*$", "")
							tbl[name] = val
						else
							tbl[name] = nil
						end
					else
						-- collect lookahead lines to decide
						local lookahead = {}
						for j = i + 1, math.max(i + 1, i + 8), 1 do
							if j > #lines then
								break
							end
							lookahead[#lookahead + 1] = lines[j]
						end

						if looks_like_platform_or_nonpub_entry(nil, lookahead) then
							tbl[name] = nil
						else
							local found = nil
							for j = i + 1, #lines do
								local l2 = lines[j]
								local v2 = l2:match('^%s*version%s*:%s*"?(.-)"?%s*$')
								if v2 and v2 ~= "" then
									found = v2
									break
								end
								if l2 and not l2:match("^%s") then
									break
								end
							end
							tbl[name] = found
						end
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
			if lower:match("^%s*dependencies%s*:") then
				local parsed = collect_block(i)
				for k, v in pairs(parsed) do
					if v ~= nil then
						deps[k] = { raw = v, current = (clean_version(v) or tostring(v)) }
					end
				end
			elseif lower:match("^%s*dev[_-]?dependencies%s*:") then
				local parsed = collect_block(i)
				for k, v in pairs(parsed) do
					if v ~= nil then
						dev_deps[k] = { raw = v, current = (clean_version(v) or tostring(v)) }
					end
				end
			end
		end
		i = i + 1
	end

	return deps, dev_deps
end

local function parse_with_decoder(content, lines)
	-- Try YAML parse first (pubspec is YAML); if it fails, fall back to line parser.
	local parsed = nil
	local ok, res = pcall(decoder.parse_yaml, content)
	if ok and type(res) == "table" then
		parsed = res
	end

	if parsed then
		local deps = {}
		local dev_deps = {}
		local raw_deps = parsed.dependencies or parsed.depends
		local raw_dev = parsed.dev_dependencies or parsed["dev_dependencies"] or parsed["dev-dependencies"]

		if raw_deps and type(raw_deps) == "table" then
			for name, val in pairs(raw_deps) do
				if type(val) == "table" then
					if val.sdk or val.path or val.git then
						-- skip platform/path/git entries
					else
						local raw, has = utils.normalize_entry_val(val)
						local cur = has and (clean_version(raw) or tostring(raw)) or nil
						deps[name] = { raw = raw, current = cur }
					end
				else
					local raw, has = utils.normalize_entry_val(val)
					local cur = has and (clean_version(raw) or tostring(raw)) or nil
					deps[name] = { raw = raw, current = cur }
				end
			end
		end

		if raw_dev and type(raw_dev) == "table" then
			for name, val in pairs(raw_dev) do
				if type(val) == "table" then
					if val.sdk or val.path or val.git then
						-- skip
					else
						local raw, has = utils.normalize_entry_val(val)
						local cur = has and (clean_version(raw) or tostring(raw)) or nil
						dev_deps[name] = { raw = raw, current = cur }
					end
				else
					local raw, has = utils.normalize_entry_val(val)
					local cur = has and (clean_version(raw) or tostring(raw)) or nil
					dev_deps[name] = { raw = raw, current = cur }
				end
			end
		end

		return { dependencies = deps, devDependencies = dev_deps }
	end

	local fb_deps, fb_dev = parse_pubspec_fallback_lines(lines or split(content, "\n"))
	return { dependencies = fb_deps or {}, devDependencies = fb_dev or {} }
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
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
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end

		-- save buffer meta
		state.save_buffer(bufnr, "pubspec", api.nvim_buf_get_name(bufnr), buffer_lines)

		-- Update state: ensure + clear manifest container
		state.ensure_manifest("pubspec")
		state.clear_manifest("pubspec")

		-- prefer per-dependency add API if available
		if state.add_installed_dependency then
			for name, info in pairs(installed_dependencies) do
				local scope = info._source or "dependencies"
				state.add_installed_dependency("pubspec", name, info.current, scope)
			end
		else
			state.set_installed("pubspec", installed_dependencies)
		end

		-- invalids
		state.set_invalid("pubspec", invalid_dependencies)

		-- maintain outdated state (keep previous value if checker will update it later)
		state.set_outdated("pubspec", state.get_dependencies("pubspec").outdated or {})

		-- update buffer cached lines/last run metadata
		state.update_buffer_lines(bufnr, buffer_lines)
		state.update_last_run(bufnr)

		-- attach last parsed snapshot to buffer for caching
		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_pubspec_parsed =
			{ installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		-- compute and store hash
		state.buffers[bufnr].last_pubspec_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		-- render virtual text and trigger checker
		vt.display(bufnr, "pubspec")
		checker.check_manifest_outdated(bufnr, "pubspec")
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	-- Skip parsing if update is in progress to avoid race conditions
	if state.get_updating and type(state.get_updating) == "function" then
		local is_updating = state.get_updating()
		if is_updating then
			-- Update is in progress, skip parsing to preserve outdated info
			return nil
		end
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_pubspec_parsed then
			defer_fn(function()
				vt.display(bufnr, "pubspec")
			end, 10)
			return state.buffers[bufnr].last_pubspec_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	-- quick hash check
	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_pubspec_hash and state.buffers[bufnr].last_pubspec_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_pubspec_parsed then
			defer_fn(function()
				vt.display(bufnr, "pubspec")
			end, 10)
			return state.buffers[bufnr].last_pubspec_parsed
		end
	end

	if state.buffers[bufnr].parse_scheduled then
		return state.buffers[bufnr].last_pubspec_parsed
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
			local lock_path = utils.find_lock_for_manifest(bufnr, "pubspec")
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
			local fb_deps, fb_dev = parse_pubspec_fallback_lines(fresh_lines)
			local conv = { dependencies = fb_deps or {}, devDependencies = fb_dev or {} }

			local lock_path = utils.find_lock_for_manifest(bufnr, "pubspec")
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

	return state.buffers[bufnr].last_pubspec_parsed
end

M.parse_lock_file_content = parse_lock_file_from_content

M.parse_lock_file_path = function(lock_path)
	local content = utils.read_file(lock_path)
	return parse_lock_file_from_content(content)
end

M.filename = "pubspec.yaml"
M.manifest_key = "pubspec"

return M
