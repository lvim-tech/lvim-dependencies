local api = vim.api
local fn = vim.fn
local defer_fn = vim.defer_fn

local const = require("lvim-dependencies.const")
local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local validator = require("lvim-dependencies.validator")

local M = {}

-- Localize common config tables for speed
local vt_cfg = config.ui.virtual_text
local hl = config.ui.highlight.groups
local perf = config.performance

-- Cache for lock file checks to avoid repeated disk reads
local lock_file_cache = {}
local lock_file_cache_ttl = 5000 -- 5 seconds TTL

local function ensure_namespace()
	state.namespace = state.namespace or {}
	state.namespace.id = state.namespace.id or api.nvim_create_namespace("lvim_dependencies")
	return state.namespace.id
end

local function filename_to_manifest_key(filename)
	local mk = state.get_manifest_key_from_filename(filename)
	if mk then
		return mk
	end
	return const.MANIFEST_KEYS[filename]
end

local function normalize_version_spec(v)
	if not v then
		return nil
	end
	v = tostring(v):gsub("^%s*", ""):gsub("%s*$", "")
	v = v:gsub("^[%s%~%^><=]+", "")
	local sem = v:match("(%d+%.%d+%.%d+)")
	if sem then
		return sem
	end
	sem = v:match("(%d+%.%d+)")
	if sem then
		return sem
	end
	local tok = v:match("(%d+)")
	return tok
end

local function get_declared_version_from_line(line, manifest_key)
	if not line then
		return nil
	end
	if manifest_key == "package" or manifest_key == "composer" then
		local parts = {}
		for chunk in string.gmatch(line, [["(.-)"]]) do
			parts[#parts + 1] = chunk
			if #parts >= 2 then
				break
			end
		end
		return parts[2] and vim.trim(parts[2]) or nil
	elseif manifest_key == "crates" then
		local v = line:match('=%s*"?([^%s,"]+)"?')
		return v and vim.trim(v) or nil
	elseif manifest_key == "pubspec" then
		local v = line:match(":%s*([^%s#]+)")
		if not v then
			return nil
		end
		v = v:gsub('[",]$', "")
		return vim.trim(v)
	elseif manifest_key == "go" then
		local v = line:match("^%s*[^%s]+%s+([v%d%.%-%+]+)")
		return v and vim.trim(v) or nil
	end
	return nil
end

-- Track which section we're in for context-aware parsing
local function find_current_section(lines, line_idx, manifest_key)
	local sections = const.SECTION_NAMES[manifest_key]
	if not sections then
		return nil
	end

	if manifest_key == "package" or manifest_key == "composer" then
		local depth = 0
		for i = line_idx - 1, 1, -1 do
			local ln = lines[i]
			local close_count = select(2, ln:gsub("}", ""))
			local open_count = select(2, ln:gsub("{", ""))
			depth = depth + close_count - open_count

			if depth == 0 then
				for _, section in ipairs(sections) do
					local pattern = string.format([["%s"%s*:]], section:gsub("%-", "%%-"))
					if ln:match(pattern) then
						return section
					end
				end
			end
		end
		return nil
	elseif manifest_key == "crates" then
		for i = line_idx - 1, 1, -1 do
			local ln = lines[i]
			local section_match = ln:match("^%[(.-)%]")
			if section_match then
				for _, section in ipairs(sections) do
					if section_match == section then
						return section
					end
				end
				return nil
			end
		end
		return nil
	elseif manifest_key == "pubspec" then
		for i = line_idx - 1, 1, -1 do
			local ln = lines[i]
			if ln:match("^[%w_%-]+%s*:") and not ln:match("^%s") then
				local section_name = ln:match("^([%w_%-]+)%s*:")
				for _, section in ipairs(sections) do
					if section_name == section then
						return section
					end
				end
				return nil
			end
		end
		return nil
	elseif manifest_key == "go" then
		for i = line_idx - 1, 1, -1 do
			local ln = lines[i]
			if ln:match("^require%s*%(") or ln:match("^require%s+%(") then
				return "require"
			elseif ln:match("^%w+") then
				break
			end
		end
		return nil
	end
	return nil
end

local function get_dependency_name_from_line(line, manifest_key, lines, line_idx)
	if not line then
		return nil
	end

	if manifest_key == "package" or manifest_key == "composer" then
		local section = find_current_section(lines, line_idx, manifest_key)
		if not section then
			return nil
		end

		local parts = {}
		for chunk in string.gmatch(line, [["(.-)"]]) do
			parts[#parts + 1] = chunk
			if #parts >= 2 then
				break
			end
		end
		return parts[1]
	elseif manifest_key == "crates" then
		local section = find_current_section(lines, line_idx, manifest_key)
		if not section then
			return nil
		end

		return line:match("^%s*([%w_%-]+)%s*=")
	elseif manifest_key == "pubspec" then
		local section = find_current_section(lines, line_idx, manifest_key)
		if not section then
			return nil
		end

		local name = line:match("^%s+([%w_%-]+):")
		if not name then
			return nil
		end

		-- Exclude special Flutter/Dart keywords
		local excluded = {
			sdk = true,
			git = true,
			path = true,
			hosted = true,
			url = true,
			ref = true,
			version = true,
		}

		if excluded[name] then
			return nil
		end

		return name
	elseif manifest_key == "go" then
		local section = find_current_section(lines, line_idx, manifest_key)

		local name = line:match("^%s*require%s+([^%s]+)")
		if name and name:match("%/") then
			return name
		end

		if section == "require" then
			name = line:match("^%s+([^%s]+)%s+[^%s]+")
			if name and name:match("%/") then
				return name
			end
		end

		return nil
	end

	return nil
end

local function find_lock_file_path(manifest_key)
	local cwd = fn.getcwd()
	local candidates = const.LOCK_CANDIDATES[manifest_key]

	if not candidates then
		return nil
	end

	for _, lock_file in ipairs(candidates) do
		local lock_path = cwd .. "/" .. lock_file
		if fn.filereadable(lock_path) == 1 then
			return lock_path
		end
	end

	return nil
end

local function is_package_in_lock_file(manifest_key, dep_name)
	local cache_key = manifest_key .. ":" .. dep_name
	local now = fn.reltime()

	-- Check cache
	if lock_file_cache[cache_key] then
		local cached = lock_file_cache[cache_key]
		local elapsed_ms = fn.reltimefloat(fn.reltime(cached.time, now)) * 1000
		if elapsed_ms < lock_file_cache_ttl then
			return cached.result
		end
	end

	local lock_path = find_lock_file_path(manifest_key)
	if not lock_path then
		lock_file_cache[cache_key] = { result = false, time = now }
		return false
	end

	local ok, lines = pcall(fn.readfile, lock_path)
	if not ok or type(lines) ~= "table" then
		lock_file_cache[cache_key] = { result = false, time = now }
		return false
	end

	local escaped_name = vim.pesc(dep_name)
	local found = false

	for _, line in ipairs(lines) do
		if manifest_key == "pubspec" then
			if line:match("^%s+" .. escaped_name .. "%s*:") then
				found = true
				break
			end
		elseif manifest_key == "crates" then
			if line:match('name%s*=%s*"' .. escaped_name .. '"') then
				found = true
				break
			end
		elseif manifest_key == "package" then
			if line:match('"' .. escaped_name .. '"') or line:match("'" .. escaped_name .. "'") then
				found = true
				break
			end
		elseif manifest_key == "composer" then
			if line:match('"' .. escaped_name .. '"') then
				found = true
				break
			end
		elseif manifest_key == "go" then
			if line:match(escaped_name) then
				found = true
				break
			end
		end
	end

	lock_file_cache[cache_key] = { result = found, time = now }
	return found
end

local function build_virt_parts(manifest_key, dep_name, declared)
	local deps = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed = deps.installed and deps.installed[dep_name]
	local outdated = deps.outdated and deps.outdated[dep_name]
	local invalid = deps.invalid and deps.invalid[dep_name]

	-- invalid diagnostic
	if invalid then
		local pieces = {}
		pieces[#pieces + 1] = { vt_cfg.prefix, hl.separator }
		local diag = invalid.diagnostic or "ERR"
		if vt_cfg.show_status_icon and vt_cfg.icon_when_invalid then
			pieces[#pieces + 1] = { vt_cfg.icon_when_invalid .. " " .. diag, hl.invalid }
		else
			pieces[#pieces + 1] = { diag, hl.invalid }
		end
		return pieces
	end

	-- Check if package is actually in lock file
	local in_lock = is_package_in_lock_file(manifest_key, dep_name)

	if not in_lock then
		if declared then
			local pieces = {}
			pieces[#pieces + 1] = { vt_cfg.prefix, hl.separator }
			local declared_norm = normalize_version_spec(declared) or declared
			local txt = declared_norm .. " (not in lock)"
			if vt_cfg.show_status_icon and vt_cfg.icon_when_constraint_newer then
				pieces[#pieces + 1] = { vt_cfg.icon_when_constraint_newer .. " " .. txt, hl.constraint_newer }
			else
				pieces[#pieces + 1] = { txt, hl.constraint_newer }
			end
			return pieces
		else
			local pieces = {}
			pieces[#pieces + 1] = { vt_cfg.prefix, hl.separator }
			if vt_cfg.show_status_icon and vt_cfg.icon_when_invalid then
				pieces[#pieces + 1] = { vt_cfg.icon_when_invalid .. " not installed", hl.invalid }
			else
				pieces[#pieces + 1] = { "not installed", hl.invalid }
			end
			return pieces
		end
	end

	local latest = (outdated and outdated.latest) and tostring(outdated.latest) or nil
	local cur = (installed and installed.current) and tostring(installed.current) or nil

	local function append_lock_diff_if_needed(parts)
		if not declared or not cur then
			return parts
		end
		local declared_norm = normalize_version_spec(declared)
		local cur_norm = normalize_version_spec(cur)
		if declared_norm and cur_norm and declared_norm ~= cur_norm then
			parts[#parts + 1] = { " ", hl.separator }
			parts[#parts + 1] = { ("(Different in lock - %s)"):format(cur), hl.lock_diff or hl.invalid }
		end
		return parts
	end

	if latest then
		local latest_s = tostring(latest)
		local is_up_to_date = (cur ~= nil and cur == latest_s)

		if outdated and outdated.constraint_newer then
			local txt = tostring(latest_s) .. " (constraint)"
			if vt_cfg.show_status_icon and vt_cfg.icon_when_constraint_newer then
				return {
					{ vt_cfg.prefix, hl.separator },
					{ vt_cfg.icon_when_constraint_newer .. " " .. txt, hl.constraint_newer },
				}
			end
			return { { vt_cfg.prefix, hl.separator }, { txt, hl.constraint_newer } }
		end

		local base_parts = nil
		if is_up_to_date then
			if vt_cfg.show_status_icon and vt_cfg.icon_when_up_to_date then
				base_parts = {
					{ vt_cfg.prefix, hl.separator },
					{ vt_cfg.icon_when_up_to_date .. " " .. latest_s, hl.up_to_date },
				}
			else
				base_parts = { { vt_cfg.prefix, hl.separator }, { latest_s, hl.up_to_date } }
			end
		else
			if vt_cfg.show_status_icon and vt_cfg.icon_when_outdated then
				base_parts =
					{ { vt_cfg.prefix, hl.separator }, { vt_cfg.icon_when_outdated .. " " .. latest_s, hl.outdated } }
			else
				base_parts = { { vt_cfg.prefix, hl.separator }, { latest_s, hl.outdated } }
			end
		end

		return append_lock_diff_if_needed(base_parts)
	end

	if cur then
		local cur_s = tostring(cur)
		local parts = nil
		if vt_cfg.show_status_icon and vt_cfg.icon_when_up_to_date then
			parts = { { vt_cfg.prefix, hl.separator }, { vt_cfg.icon_when_up_to_date .. " " .. cur_s, hl.up_to_date } }
		else
			parts = { { vt_cfg.prefix, hl.separator }, { cur_s, hl.up_to_date } }
		end

		return append_lock_diff_if_needed(parts)
	end

	return nil
end

local function get_loading_parts()
	return { { vt_cfg.prefix, hl.separator }, { vt_cfg.loading, hl.loading } }
end

local function do_display(bufnr, manifest_key)
	if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
		return
	end

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	manifest_key = manifest_key or filename_to_manifest_key(filename)
	if not manifest_key then
		return
	end

	if not validator.is_supported_manifest(manifest_key) then
		return
	end

	if vt_cfg.enabled == false then
		return
	end

	local ns = tonumber(ensure_namespace()) or 0

	api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local deps_tbl = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed_tbl = deps_tbl.installed or {}
	local outdated_tbl = deps_tbl.outdated or {}
	local invalid_tbl = deps_tbl.invalid or {}

	local is_loading = state.buffers and state.buffers[bufnr] and state.buffers[bufnr].is_loading
	local loading_parts = is_loading and get_loading_parts() or nil

	local buffer_meta = state.get_buffer(bufnr)
	local lines = (buffer_meta and buffer_meta.lines) or api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i = 1, #lines do
		local line = lines[i]
		local dep_name = get_dependency_name_from_line(line, manifest_key, lines, i)
		if dep_name then
			local should_process = installed_tbl[dep_name] or outdated_tbl[dep_name] or invalid_tbl[dep_name]

			if should_process or is_loading then
				local declared_version = get_declared_version_from_line(line, manifest_key)

				local virt_parts
				if is_loading then
					if outdated_tbl[dep_name] or invalid_tbl[dep_name] then
						virt_parts = build_virt_parts(manifest_key, dep_name, declared_version)
					else
						virt_parts = loading_parts
					end
				else
					virt_parts = build_virt_parts(manifest_key, dep_name, declared_version)
				end

				if virt_parts and #virt_parts > 0 then
					api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
						virt_text = virt_parts,
						virt_text_pos = "eol",
						priority = 200,
					})
				end
			end
		end
	end

	if state.set_virtual_text_displayed then
		state.set_virtual_text_displayed(bufnr, true)
	else
		state.buffers = state.buffers or {}
		state.buffers[bufnr] = state.buffers[bufnr] or {}
		state.buffers[bufnr].is_virtual_text_displayed = true
	end
end

M.display = function(bufnr, manifest_key)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	if state.buffers[bufnr].is_loading then
		do_display(bufnr, manifest_key)
		return
	end

	if state.buffers[bufnr].display_scheduled then
		state.buffers[bufnr].display_requested_manifest = manifest_key
			or state.buffers[bufnr].display_requested_manifest
		return
	end

	state.buffers[bufnr].display_scheduled = true
	state.buffers[bufnr].display_requested_manifest = manifest_key

	defer_fn(function()
		state.buffers[bufnr].display_scheduled = false
		local mk = state.buffers[bufnr].display_requested_manifest
		state.buffers[bufnr].display_requested_manifest = nil
		do_display(bufnr, mk)
	end, perf.deferred_full_render_ms)
end

M.clear = function(bufnr)
	bufnr = bufnr or fn.bufnr()
	if bufnr == -1 then
		return
	end
	local ns = tonumber(ensure_namespace()) or 0
	api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	local manifest_key = filename_to_manifest_key(filename)
	if manifest_key then
		for key in pairs(lock_file_cache) do
			if key:match("^" .. vim.pesc(manifest_key) .. ":") then
				lock_file_cache[key] = nil
			end
		end
	end

	if state.set_virtual_text_displayed then
		state.set_virtual_text_displayed(bufnr, false)
	else
		if state.buffers and state.buffers[bufnr] then
			state.buffers[bufnr].is_virtual_text_displayed = false
		end
	end
	if state.buffers and state.buffers[bufnr] then
		state.buffers[bufnr].display_scheduled = false
		state.buffers[bufnr].display_requested_manifest = nil
	end
end

M.clear_lock_cache = function()
	lock_file_cache = {}
end

M.debug_extmarks = function(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	local ns = tonumber(ensure_namespace()) or 0
	local marks = api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
	if not marks or #marks == 0 then
		print("failed to get extmarks or none present")
		return
	end
	print("extmarks in ns:", ns, "count:", #marks)
	for _, m in ipairs(marks) do
		local id, row, col, details = m[1], m[2], m[3], m[4]
		print(string.format("id=%s row=%d col=%d", tostring(id), row, col))
		if details and details.virt_text then
			print("  virt_text:", vim.inspect(details.virt_text))
		end
	end
end

pcall(function()
	api.nvim_create_autocmd("User", {
		pattern = "LvimDepsPackageUpdated",
		callback = function()
			M.clear_lock_cache()

			for _, bufnr in ipairs(api.nvim_list_bufs()) do
				if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_is_valid(bufnr) then
					local name = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
					local mk = filename_to_manifest_key(name)
					if mk then
						pcall(M.display, bufnr, mk)
					end
				end
			end
		end,
	})

	api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
		pattern = const.LOCK_FILE_PATTERNS,
		callback = function()
			M.clear_lock_cache()

			for _, bufnr in ipairs(api.nvim_list_bufs()) do
				if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_is_valid(bufnr) then
					local name = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
					local mk = filename_to_manifest_key(name)
					if mk then
						pcall(M.display, bufnr, mk)
					end
				end
			end
		end,
	})
end)

return M
