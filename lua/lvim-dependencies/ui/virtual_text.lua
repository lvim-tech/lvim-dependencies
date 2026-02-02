local api = vim.api
local fn = vim.fn
local defer_fn = vim.defer_fn

local const = require("lvim-dependencies.const")
local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local validator = require("lvim-dependencies.validator")
local utils = require("lvim-dependencies.utils")

local M = {}

local vt_cfg = config.ui.virtual_text
local hl = config.ui.highlight.groups
local perf = config.performance

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
		local v = line:match("^%s*[^%s]+%s+([v%d%.%-%+%w]+)")
		return v and vim.trim(v) or nil
	end
	return nil
end

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
			if depth == -1 then
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

		if line:match([[:%s*{%s*$]]) then
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

local function get_loading_parts()
	return { { vt_cfg.prefix, hl.separator }, { vt_cfg.loading, hl.loading } }
end

-- ------------------------------------------------------------
-- node_modules version cache (only used for visible packages)
-- ------------------------------------------------------------
local node_modules_cache = {
	-- [name] = { mtime=..., size=..., version="x.y.z" or nil }
}

local function get_node_modules_version(dep_name)
	if not dep_name or dep_name == "" then
		return nil
	end

	local cwd = fn.getcwd()
	local pkg_json = cwd .. "/node_modules/" .. dep_name .. "/package.json"

	local st = utils.fs_stat(pkg_json)
	if not st then
		node_modules_cache[dep_name] = nil
		return nil
	end

	local mtime = (st.mtime and st.mtime.sec) or 0
	local size = st.size or 0

	local cached = node_modules_cache[dep_name]
	if cached and cached.mtime == mtime and cached.size == size then
		return cached.version
	end

	local content = utils.read_file(pkg_json)
	if not content or content == "" then
		node_modules_cache[dep_name] = { mtime = mtime, size = size, version = nil }
		return nil
	end

	local ok, parsed = pcall(vim.fn.json_decode, content)
	local ver = (ok and type(parsed) == "table" and parsed.version and tostring(parsed.version)) or nil

	node_modules_cache[dep_name] = { mtime = mtime, size = size, version = ver }
	return ver
end

local function declared_target_from(declared_raw, manifest_key)
	declared_raw = declared_raw and vim.trim(tostring(declared_raw)) or ""
	if declared_raw == "" then
		return nil
	end

	if manifest_key == "go" then
		return declared_raw
	end

	local is_exact = declared_raw:match("^%d+%.%d+%.%d+[%w%._%-]*$") ~= nil
	if is_exact then
		return declared_raw
	end

	return utils.normalize_version_spec(declared_raw)
end

local function build_badge(label)
	label = label and tostring(label) or ""
	return (" [%s]"):format(label)
end

-- ------------------------------------------------------------
-- virtual text builder
-- ------------------------------------------------------------
local function build_virt_parts(manifest_key, dep_name, declared, has_lock)
	local deps = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed = deps.installed and deps.installed[dep_name]
	local outdated = deps.outdated and deps.outdated[dep_name]
	local invalid = deps.invalid and deps.invalid[dep_name]

	if invalid then
		local pieces = {}
		pieces[#pieces + 1] = { vt_cfg.prefix, hl.separator }

		local diag = invalid.diagnostic or "ERR"
		local icon = ""
		if vt_cfg.show_status_icon and vt_cfg.icon_when_invalid then
			icon = vt_cfg.icon_when_invalid
		end

		pieces[#pieces + 1] = { build_badge(icon .. diag), hl.invalid }
		return pieces
	end

	local in_lock = nil
	local cur = nil
	if type(installed) == "table" then
		in_lock = installed.in_lock
		cur = installed.current and tostring(installed.current) or nil
	elseif type(installed) == "string" then
		cur = tostring(installed)
		in_lock = nil
	end

	if in_lock == false then
		local pieces = {}
		pieces[#pieces + 1] = { vt_cfg.prefix, hl.separator }

		local declared_norm
		if manifest_key == "go" then
			declared_norm = declared or ""
		else
			declared_norm = utils.normalize_version_spec(declared) or declared or ""
		end
		local shown = (declared_norm ~= "" and declared_norm or "unknown")

		if has_lock == false then
			local icon = ""
			if vt_cfg.show_status_icon and vt_cfg.icon_when_not_installed then
				icon = vt_cfg.icon_when_not_installed
			end
			pieces[#pieces + 1] = { icon .. shown, hl.not_installed }
			pieces[#pieces + 1] = { build_badge("not installed"), hl.not_installed }
			return pieces
		end

		local icon = ""
		if vt_cfg.show_status_icon and vt_cfg.icon_when_constraint then
			icon = vt_cfg.icon_when_constraint
		end

		pieces[#pieces + 1] = { icon .. shown, hl.constraint }
		pieces[#pieces + 1] = { build_badge("constraint"), hl.constraint }

		return pieces
	end

	-- ------------------------------------------------------------
	-- Resolved version hint config (works across ecosystems)
	-- ------------------------------------------------------------
	local resolved_ver = nil
	local lock_ver = cur and tostring(cur) or nil
	local show_resolved = false
	local mode = vt_cfg.resolved_version or vt_cfg.node_version or "mismatch"

	if mode ~= "never" then
		if manifest_key == "package" then
			resolved_ver = get_node_modules_version(dep_name)
		else
			if in_lock == true then
				resolved_ver = lock_ver
			else
				resolved_ver = nil
			end
		end
	end

	if resolved_ver and resolved_ver ~= "" and mode ~= "never" then
		local resolved_norm = vim.trim(tostring(resolved_ver))
		local lock_norm = lock_ver and vim.trim(tostring(lock_ver)) or ""
		local declared_target = declared_target_from(declared, manifest_key)

		if mode == "always" then
			show_resolved = true
		elseif mode == "mismatch" then
			if lock_norm ~= "" and resolved_norm ~= lock_norm then
				show_resolved = true
			end
			if
				not show_resolved
				and declared_target
				and declared_target ~= ""
				and lock_norm ~= ""
				and lock_norm ~= declared_target
			then
				show_resolved = true
			end
		elseif mode == "mismatch_or_difflock" then
			local mismatch = (lock_norm ~= "" and resolved_norm ~= lock_norm)
			local difflock = not not (
				declared_target
				and declared_target ~= ""
				and lock_norm ~= ""
				and lock_norm ~= declared_target
			)
			show_resolved = (mismatch or difflock) and true or false
		end
	end

	local function append_resolved_segment(pieces_tbl, main_ver)
		if show_resolved and resolved_ver and resolved_ver ~= "" then
			if main_ver and tostring(main_ver) == tostring(resolved_ver) then
				return pieces_tbl
			end

			local icon = ""
			if vt_cfg.show_status_icon and vt_cfg.icon_when_resolved then
				icon = vt_cfg.icon_when_resolved
			end
			pieces_tbl[#pieces_tbl + 1] =
				{ " " .. icon .. tostring(resolved_ver) .. build_badge("resolved"), hl.resolved }
		end
		return pieces_tbl
	end

	local latest = (outdated and outdated.latest) and tostring(outdated.latest) or nil
	if latest then
		local latest_s = tostring(latest)
		local is_up_to_date = (cur ~= nil and cur == latest_s)

		if outdated and outdated.constraint_newer then
			local icon_con = ""
			if vt_cfg.show_status_icon and vt_cfg.icon_when_constraint then
				icon_con = vt_cfg.icon_when_constraint
			end

			local declared_target = declared_target_from(declared, manifest_key)
			if declared_target and resolved_ver and tostring(declared_target) == tostring(resolved_ver) then
				show_resolved = false
			end

			if resolved_ver and cur and tostring(resolved_ver) == tostring(cur) then
				show_resolved = false
			end

			local parts = {
				{ vt_cfg.prefix, hl.separator },
				{ icon_con .. latest_s, hl.constraint },
				{ build_badge("constraint"), hl.constraint },
			}

			return append_resolved_segment(parts, latest_s)
		end

		if is_up_to_date then
			local parts
			if vt_cfg.show_status_icon and vt_cfg.icon_when_up_to_date then
				parts = {
					{ vt_cfg.prefix, hl.separator },
					{ vt_cfg.icon_when_up_to_date .. " " .. latest_s, hl.up_to_date },
				}
			else
				parts = { { vt_cfg.prefix, hl.separator }, { latest_s, hl.up_to_date } }
			end
			return append_resolved_segment(parts, latest_s)
		else
			local parts
			if vt_cfg.show_status_icon and vt_cfg.icon_when_outdated then
				parts = {
					{ vt_cfg.prefix, hl.separator },
					{ vt_cfg.icon_when_outdated .. " " .. latest_s, hl.outdated },
				}
			else
				parts = { { vt_cfg.prefix, hl.separator }, { latest_s, hl.outdated } }
			end
			return append_resolved_segment(parts, latest_s)
		end
	end

	if cur then
		local parts
		if vt_cfg.show_status_icon and vt_cfg.icon_when_up_to_date then
			parts = { { vt_cfg.prefix, hl.separator }, { vt_cfg.icon_when_up_to_date .. " " .. cur, hl.up_to_date } }
		else
			parts = { { vt_cfg.prefix, hl.separator }, { cur, hl.up_to_date } }
		end
		return append_resolved_segment(parts, cur)
	end

	return nil
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

	local w0 = fn.line("w0")
	local wend = fn.line("w$")
	if not w0 or not wend then
		return
	end
	local start0 = math.max(0, w0 - 1)
	local end0 = math.max(start0, wend)

	api.nvim_buf_clear_namespace(bufnr, ns, start0, end0)

	local deps_tbl = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed_tbl = deps_tbl.installed or {}
	local outdated_tbl = deps_tbl.outdated or {}
	local invalid_tbl = deps_tbl.invalid or {}

	local lock_path = utils.find_lock_for_manifest(bufnr, manifest_key)
	local has_lock = lock_path ~= nil

	local is_loading = state.buffers and state.buffers[bufnr] and state.buffers[bufnr].is_loading
	local loading_parts = is_loading and get_loading_parts() or nil

	local buffer_meta = state.get_buffer(bufnr)
	local lines = (buffer_meta and buffer_meta.lines) or api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i = w0, wend do
		local line = lines[i]
		local dep_name = get_dependency_name_from_line(line, manifest_key, lines, i)
		if dep_name then
			local should_process = installed_tbl[dep_name] or outdated_tbl[dep_name] or invalid_tbl[dep_name]
			if should_process or is_loading then
				local declared_version = get_declared_version_from_line(line, manifest_key)

				local virt_parts
				if is_loading then
					if outdated_tbl[dep_name] or invalid_tbl[dep_name] then
						virt_parts = build_virt_parts(manifest_key, dep_name, declared_version, has_lock)
					else
						virt_parts = loading_parts
					end
				else
					virt_parts = build_virt_parts(manifest_key, dep_name, declared_version, has_lock)
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

	state.set_virtual_text_displayed(bufnr, true)
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
	state.set_virtual_text_displayed(bufnr, false)

	if state.buffers and state.buffers[bufnr] then
		state.buffers[bufnr].display_scheduled = false
		state.buffers[bufnr].display_requested_manifest = nil
	end
end

M.clear_node_modules_cache = function()
	node_modules_cache = {}
end

pcall(function()
	api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
		pattern = const.LOCK_FILE_PATTERNS,
		callback = function()
			M.clear_node_modules_cache()
			utils.clear_file_cache()
		end,
	})
end)

return M
