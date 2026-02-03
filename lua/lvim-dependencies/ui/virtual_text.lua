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

local function declared_target_from(declared_raw, manifest_key)
	declared_raw = declared_raw and vim.trim(tostring(declared_raw)) or ""
	if declared_raw == "" then
		return nil
	end

	if manifest_key == "go" then
		return declared_raw
	end

	if manifest_key == "composer" then
		local cleaned = utils.clean_version(declared_raw) or declared_raw
		local is_exact = cleaned:match("^%d+%.%d+%.%d+[%w%._%-%+]*$") ~= nil
		if is_exact then
			return cleaned
		end
		return utils.normalize_version_spec(declared_raw)
	end

	local is_exact = declared_raw:match("^%d+%.%d+%.%d+[%w%._%-%+]*$") ~= nil
	if is_exact then
		return declared_raw
	end

	return utils.normalize_version_spec(declared_raw)
end

local function build_inline_badge(label)
	label = label and tostring(label) or ""
	return ("[%s] "):format(label)
end

-- ------------------------------------------------------------
-- virtual text builder
-- ------------------------------------------------------------
local function build_virt_parts(manifest_key, dep_name, declared, _)
	local deps = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed = deps.installed and deps.installed[dep_name]
	local outdated = deps.outdated and deps.outdated[dep_name]
	local invalid = deps.invalid and deps.invalid[dep_name]

	local in_lock = nil
	local cur = nil
	if type(installed) == "table" then
		in_lock = installed.in_lock
		cur = installed.current and tostring(installed.current) or nil
	elseif type(installed) == "string" then
		cur = tostring(installed)
		in_lock = nil
	end

	local declared_target = declared_target_from(declared, manifest_key)

	local cur_comp = cur
	if manifest_key == "composer" and cur then
		cur_comp = utils.clean_version(cur) or cur
	end

	local declared_comp = declared_target
	if manifest_key == "composer" and declared_target then
		declared_comp = utils.clean_version(declared_target) or declared_target
	end

	local real_label = nil
	local real_hl = nil

	if invalid then
		real_label = "invalid"
		real_hl = hl.invalid
	elseif in_lock == false or not cur or cur == "" then
		real_label = "not installed"
		real_hl = hl.not_installed
	elseif declared_comp and cur_comp and tostring(cur_comp) ~= tostring(declared_comp) then
		real_label = tostring(cur_comp)
		real_hl = hl.real
	end

	local status_value = nil
	local status_hl = nil
	if outdated and outdated.latest then
		status_value = tostring(outdated.latest)
		if outdated.up_to_date then
			status_hl = hl.up_to_date
		else
			status_hl = hl.outdated
		end
	elseif cur and cur ~= "" then
		status_value = tostring(cur_comp or cur)
		status_hl = hl.up_to_date
	end

	if not real_label and not status_value then
		return nil
	end

	local parts = {}

	if real_label then
		parts[#parts + 1] = { build_inline_badge(real_label), real_hl }
	end

	if status_value then
		local icon = ""
		if vt_cfg.show_status_icon then
			if status_hl == hl.up_to_date then
				icon = vt_cfg.icon_when_up_to_date or ""
			elseif status_hl == hl.outdated then
				icon = vt_cfg.icon_when_outdated or ""
			end
		end
		parts[#parts + 1] = { vt_cfg.prefix, hl.separator }
		parts[#parts + 1] = { icon .. status_value, status_hl }
	end

	return parts
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
						virt_parts = build_virt_parts(manifest_key, dep_name, declared_version, false)
					else
						virt_parts = loading_parts
					end
				else
					virt_parts = build_virt_parts(manifest_key, dep_name, declared_version, false)
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

pcall(function()
	api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
		pattern = const.LOCK_FILE_PATTERNS,
		callback = function()
			utils.clear_file_cache()
		end,
	})
end)

return M
