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

-- ------------------------------------------------------------
-- Lock parse cache (per lock_path + mtime + size)
-- ------------------------------------------------------------
local lock_cache = {
	-- [lock_path] = { mtime=..., size=..., versions=table }
}

local function trim_quotes(v)
	v = tostring(v or "")
	v = v:gsub("^%s*", ""):gsub("%s*$", "")
	v = v:gsub("^['\"]", ""):gsub("['\"]$", "")
	return v
end

local function normalize_semverish(v)
	v = trim_quotes(v)
	if v == "" then
		return nil
	end
	return v:match("^([0-9]+%.[0-9]+%.[0-9]+[%w%-%._]*)") or v:match("^([0-9]+%.[0-9]+[%w%-%._]*)") or v
end

local function pnpm_key_to_name_version(key)
	if not key or key == "" then
		return nil, nil
	end
	key = trim_quotes(key)
	key = key:gsub("^/", "")

	local name, ver = key:match("^(.+)@(%d+%.%d+%.%d+[^%(]*)")
	if not ver then
		name, ver = key:match("^(.+)@(%d+%.%d+[^%(]*)")
	end
	if not (name and ver) then
		return nil, nil
	end

	name = name:gsub("%s*$", "")
	ver = normalize_semverish(ver)
	return name, ver
end

-- ------------------------------------------------------------
-- PNPM: parse top-level deps from importers (correct source)
-- ------------------------------------------------------------
local function strip_inline_comment(s)
	-- pnpm-lock.yaml normally doesn't have comments, but be safe
	return (s:gsub("%s+#.*$", ""))
end

local function parse_yaml_scalar_value(s)
	-- Handles:
	-- lodash: 4.17.23
	-- lodash:
	--   version: 4.17.23
	s = strip_inline_comment(s or "")
	s = s:match("^%s*(.-)%s*$")
	if s == "" then
		return nil
	end
	s = s:gsub('^"(.*)"$', "%1")
	s = s:gsub("^'(.*)'$", "%1")
	return s
end

-- From a pnpm version field like:
-- "4.17.23" or "4.17.23(@types/node@20.0.0)" or "link:../x"
local function pnpm_extract_version_field(v)
	v = parse_yaml_scalar_value(v)
	if not v or v == "" then
		return nil
	end

	-- ignore non-registry installs
	if v:match("^link:") or v:match("^file:") or v:match("^workspace:") or v:match("^patch:") then
		return nil
	end

	-- remove parenthesized suffix
	v = v:gsub("%(.*$", "")
	v = v:gsub("^/+", "")
	return normalize_semverish(v)
end

local function parse_pnpm_importers_top_level_versions(content)
	-- Returns name->version for top-level deps, or nil if cannot parse.
	if not content or content == "" then
		return nil
	end
	-- quick check
	if not (content:match("\nimporters:%s*\n") or content:match("^importers:%s*$")) then
		return nil
	end

	local lines = split(content, "\n")

	-- Find importers:
	local importers_start = nil
	for i, line in ipairs(lines) do
		if line:match("^importers:%s*$") then
			importers_start = i
			break
		end
	end
	if not importers_start then
		return nil
	end

	-- Identify the importer block we want: prefer "." else first importer key.
	local importer_key = nil
	local importer_line = nil

	for i = importers_start + 1, #lines do
		local line = lines[i]
		if line:match("^[^%s]") then
			-- left importers section
			break
		end
		if line:match("^%s%s[^%s].-:%s*$") then
			local k = line:match("^%s%s([^:]+):%s*$")
			k = parse_yaml_scalar_value(k)
			if k then
				-- prefer "."
				if k == "." then
					importer_key = k
					importer_line = i
					break
				end
				-- otherwise remember first
				if not importer_key then
					importer_key = k
					importer_line = i
				end
			end
		end
	end

	if not importer_key or not importer_line then
		return nil
	end

	-- Now parse under this importer for dependency sections
	local versions = {}
	local current_section = nil -- "dependencies" | "devDependencies" | "optionalDependencies" | ...
	local dep_name = nil

	for i = importer_line + 1, #lines do
		local line = lines[i]

		-- stop if we reached next importer (2 spaces indent key) or end of importers
		if line:match("^%s%s[^%s].-:%s*$") then
			-- next importer starts
			break
		end
		if line:match("^[^%s]") then
			-- left importers section
			break
		end

		-- detect sections at 4 spaces: "    dependencies:"
		local sec = line:match("^%s%s%s%s([%w%-]+):%s*$")
		if sec then
			current_section = sec
			dep_name = nil
		end

		-- We only care about dep sections
		if
			current_section == "dependencies"
			or current_section == "devDependencies"
			or current_section == "optionalDependencies"
		then
			-- dep key at 6 spaces: "      lodash:"
			local dn = line:match("^%s%s%s%s%s%s([^%s:]+):%s*$")
			if dn then
				dep_name = parse_yaml_scalar_value(dn)
			end

			-- inline form: "      lodash: 4.17.23"
			local dn_inline, v_inline = line:match("^%s%s%s%s%s%s([^%s:]+):%s*(.+)%s*$")
			if dn_inline and v_inline and not line:match("^%s%s%s%s%s%s[^%s:]+:%s*$") then
				local name = parse_yaml_scalar_value(dn_inline)
				local ver = pnpm_extract_version_field(v_inline)
				if name and ver then
					versions[name] = ver
				end
				dep_name = nil
			end

			-- nested version field: 8 spaces: "        version: 4.17.23"
			if dep_name then
				local k, v = line:match("^%s%s%s%s%s%s%s%s([%w%-]+):%s*(.-)%s*$")
				if k == "version" then
					local ver = pnpm_extract_version_field(v)
					if ver then
						versions[dep_name] = ver
					end
				end
			end
		end
	end

	if next(versions) == nil then
		return nil
	end
	return versions
end

-- ------------------------------------------------------------
-- PNPM fallback: scan snapshots/packages keys (NOT reliable for top-level)
-- ------------------------------------------------------------
local function parse_pnpm_snapshots_packages_fast(content)
	local versions = {}
	local lines = split(content or "", "\n")

	local in_section = false

	for _, line in ipairs(lines) do
		if line:match("^snapshots:%s*$") or line:match("^packages:%s*$") then
			in_section = true
		elseif line:match("^[^%s]") and not (line:match("^snapshots:%s*$") or line:match("^packages:%s*$")) then
			in_section = false
		end

		if in_section then
			local key = line:match("^%s%s'([^']+)'%s*:%s*$")
				or line:match('^%s%s"([^"]+)"%s*:%s*$')
				or line:match("^%s%s([^%s].-)%s*:%s*$")

			if key and key ~= "" then
				local name, ver = pnpm_key_to_name_version(key)
				if name and ver then
					versions[name] = versions[name] or ver
				end
			end
		end
	end

	return versions
end

-- ------------------------------------------------------------
-- Lock parse dispatcher (pnpm/yarn/npm)
-- ------------------------------------------------------------
local function parse_lock_file_from_content(content)
	if not content or content == "" then
		return {}
	end

	-- pnpm-lock.yaml detection
	if content:match("^lockfileVersion:") or content:match("\nlockfileVersion:") then
		-- Correct: prefer importers-derived top-level versions
		local from_importers = parse_pnpm_importers_top_level_versions(content)
		if from_importers and type(from_importers) == "table" and next(from_importers) then
			return from_importers
		end
		-- fallback (less correct)
		return parse_pnpm_snapshots_packages_fast(content)
	end

	-- JSON lock (package-lock.json / npm-shrinkwrap.json)
	local ok, parsed = pcall(decoder.parse_json, content)
	if not ok or type(parsed) ~= "table" then
		return {}
	end

	local versions = {}

	-- npm v7+ has packages table
	if parsed.packages and type(parsed.packages) == "table" then
		for pkg_path, info in pairs(parsed.packages) do
			if type(info) == "table" and info.version then
				local name = pkg_path:match("node_modules/([^/]+)$") or pkg_path:gsub("^node_modules/", "")
				if name and name ~= "" then
					versions[name] = tostring(info.version)
				end
			end
		end
	end

	-- npm v5/v6 dependencies
	if parsed.dependencies and type(parsed.dependencies) == "table" then
		for name, info in pairs(parsed.dependencies) do
			if info and type(info) == "table" and info.version then
				versions[name] = tostring(info.version)
			end
		end
	end

	return versions
end

local function get_lock_versions(lock_path)
	if not lock_path then
		return nil
	end

	local content, mtime, size = utils.read_file_cached(lock_path)
	if content == nil then
		lock_cache[lock_path] = nil
		return nil
	end

	local cached = lock_cache[lock_path]
	if cached and cached.mtime == mtime and cached.size == size and type(cached.versions) == "table" then
		return cached.versions
	end

	local versions = parse_lock_file_from_content(content)
	lock_cache[lock_path] = { mtime = mtime, size = size, versions = versions }
	return versions
end

-- ------------------------------------------------------------
-- package.json parsing
-- ------------------------------------------------------------
local function parse_package_fallback_lines(lines)
	if not lines or type(lines) ~= "table" then
		return {}, {}
	end

	local function strip_comments_and_trim(s)
		if not s then
			return nil
		end
		local t = s:gsub("//.*$", ""):gsub("/%*.-%*/", ""):gsub(",%s*$", ""):match("^%s*(.-)%s*$")
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
	if source == "dependencies" then
		return "dependencies"
	end
	if source == "dev_dependencies" then
		return "devDependencies"
	end
	if source == "optional_dependencies" then
		return "optionalDependencies"
	end
	if source == "peer_dependencies" then
		return "peerDependencies"
	end
	if source == "overrides" then
		return "overrides"
	end
	return "dependencies"
end

local function do_parse_and_update(bufnr, parsed_tables, buffer_lines, content)
	if not api.nvim_buf_is_valid(bufnr) then
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
				in_lock = info.in_lock,
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
		if not api.nvim_buf_is_valid(bufnr) then
			return
		end

		if state.save_buffer then
			state.save_buffer(bufnr, "package", api.nvim_buf_get_name(bufnr), buffer_lines)
		end

		state.ensure_manifest("package")
		state.clear_manifest("package")

		-- ------------------------------------------------------------
		-- UNIVERSAL INSTALLED SHAPE:
		-- Always set installed entries as table: {current, raw, in_lock, scopes}
		-- We do NOT rely on state.add_installed_dependency (it can create string entries).
		-- ------------------------------------------------------------
		local bulk = {}
		for name, info in pairs(installed_dependencies) do
			local scope = map_source_to_scope(info._source or "dependencies")
			bulk[name] = {
				current = info.current,
				raw = info.raw,
				in_lock = info.in_lock == true, -- normalize to boolean
				scopes = { [scope] = true },
			}
		end
		state.set_installed("package", bulk)

		state.set_invalid("package", invalid_dependencies)
		state.set_outdated("package", state.get_dependencies("package").outdated or {})

		state.update_buffer_lines(bufnr, buffer_lines)
		state.update_last_run(bufnr)

		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].last_package_parsed =
			{ installed = installed_dependencies, invalid = invalid_dependencies }
		state.buffers[bufnr].parse_scheduled = false

		state.buffers[bufnr].last_package_hash = fn.sha256(content)
		state.buffers[bufnr].last_changedtick = api.nvim_buf_get_changedtick(bufnr)

		vt.display(bufnr, "package")
		checker.check_manifest_outdated(bufnr, "package")
	end)
end

M.parse_buffer = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return nil
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local buf_changedtick = api.nvim_buf_get_changedtick(bufnr)
	if state.buffers[bufnr].last_changedtick and state.buffers[bufnr].last_changedtick == buf_changedtick then
		if state.buffers[bufnr].last_package_parsed then
			defer_fn(function()
				vt.display(bufnr, "package")
			end, 10)
			return state.buffers[bufnr].last_package_parsed
		end
	end

	local buffer_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local content = table_concat(buffer_lines, "\n")

	local current_hash = fn.sha256(content)
	if state.buffers[bufnr].last_package_hash and state.buffers[bufnr].last_package_hash == current_hash then
		state.buffers[bufnr].last_changedtick = buf_changedtick
		if state.buffers[bufnr].last_package_parsed then
			defer_fn(function()
				vt.display(bufnr, "package")
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
		if not (ok_decode and parsed) then
			local fb_deps, fb_dev = parse_package_fallback_lines(fresh_lines)
			parsed = {
				dependencies = fb_deps or {},
				devDependencies = fb_dev or {},
				optionalDependencies = {},
				peerDependencies = {},
				overrides = {},
			}
		end

		local lock_path = utils.find_lock_for_manifest(bufnr, "package")
		local lock_versions = lock_path and get_lock_versions(lock_path) or nil

		local function apply_lock(tbl)
			for name, info in pairs(tbl or {}) do
				if lock_versions and lock_versions[name] then
					info.current = lock_versions[name]
					info.in_lock = true
				else
					info.in_lock = false
				end
			end
		end

		apply_lock(parsed.dependencies)
		apply_lock(parsed.devDependencies)
		apply_lock(parsed.optionalDependencies)
		apply_lock(parsed.peerDependencies)

		do_parse_and_update(bufnr, parsed, fresh_lines, fresh_content)
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
