local api = vim.api
local fn = vim.fn
local defer_fn = vim.defer_fn

local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local validator = require("lvim-dependencies.validator")

local M = {}

-- Localize common config tables for speed
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
	if filename == "package.json" then return "package" end
	if filename == "Cargo.toml" then return "crates" end
	if filename == "pubspec.yaml" or filename == "pubspec.yml" then return "pubspec" end
	if filename == "composer.json" then return "composer" end
	if filename == "go.mod" then return "go" end
	return nil
end

local function get_dependency_name_from_line(line, manifest_key)
	if not line then return nil end
	if manifest_key == "package" or manifest_key == "composer" then
		local parts = {}
		for chunk in string.gmatch(line, [["(.-)"]]) do
			parts[#parts + 1] = chunk
			if #parts >= 2 then break end
		end
		return parts[1]
	elseif manifest_key == "crates" then
		return line:match("^%s*([%w_%-]+)%s*=")
	elseif manifest_key == "pubspec" then
		return line:match("^%s+([%w_%-]+):")
	elseif manifest_key == "go" then
		local name = line:match("^%s*require%s+([^%s]+)")
		if name then return name end
		name = line:match("^%s+([^%s]+)%s+[^%s]+")
		if name and name:match("%/") then return name end
		name = line:match("^%s*([^%s]+)%s+v[%d%w%-%+%.]+")
		if name and name:match("%/") then return name end
	end
	return nil
end

local function build_virt_parts(manifest_key, dep_name)
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

	-- outdated / constraint / up-to-date
	if outdated and outdated.latest then
		local latest = tostring(outdated.latest)
		local cur = installed and installed.current and tostring(installed.current) or nil
		local is_up_to_date = (cur ~= nil and cur == latest)

		if outdated.constraint_newer then
			local txt = tostring(latest) .. " (constraint)"
			if vt_cfg.show_status_icon and vt_cfg.icon_when_constraint_newer then
				return {
					{ vt_cfg.prefix, hl.separator },
					{ vt_cfg.icon_when_constraint_newer .. " " .. txt, hl.constraint_newer },
				}
			end
			return { { vt_cfg.prefix, hl.separator }, { txt, hl.constraint_newer } }
		end

		if is_up_to_date then
			if vt_cfg.show_status_icon and vt_cfg.icon_when_up_to_date then
				return { { vt_cfg.prefix, hl.separator }, { vt_cfg.icon_when_up_to_date .. " " .. latest, hl.up_to_date } }
			end
			return { { vt_cfg.prefix, hl.separator }, { latest, hl.up_to_date } }
		else
			if vt_cfg.show_status_icon and vt_cfg.icon_when_outdated then
				return { { vt_cfg.prefix, hl.separator }, { vt_cfg.icon_when_outdated .. " " .. latest, hl.outdated } }
			end
			return { { vt_cfg.prefix, hl.separator }, { latest, hl.outdated } }
		end
	end

	-- installed only
	if installed and installed.current then
		local cur = tostring(installed.current)
		if vt_cfg.show_status_icon and vt_cfg.icon_when_up_to_date then
			return { { vt_cfg.prefix, hl.separator }, { vt_cfg.icon_when_up_to_date .. " " .. cur, hl.up_to_date } }
		end
		return { { vt_cfg.prefix, hl.separator }, { cur, hl.up_to_date } }
	end

	return nil
end

local function get_loading_parts()
	return { { vt_cfg.prefix, hl.separator }, { vt_cfg.loading, hl.loading } }
end

local function do_display(bufnr, manifest_key)
	if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then return end

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	manifest_key = manifest_key or filename_to_manifest_key(filename)
	if not manifest_key then return end

	-- manifest support check (assume validator exists)
	if not validator.is_supported_manifest(manifest_key) then return end

	-- honor explicit disable
	if vt_cfg.enabled == false then return end

    local ns = tonumber(ensure_namespace()) or 0

	-- clear namespace
	api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local deps_tbl = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed_tbl = deps_tbl.installed or {}
	local outdated_tbl = deps_tbl.outdated or {}
	local invalid_tbl = deps_tbl.invalid or {}

	local is_loading = state.buffers and state.buffers[bufnr] and state.buffers[bufnr].is_loading
	local loading_parts = is_loading and get_loading_parts() or nil

	-- prefer cached buffer lines if provided via state.get_buffer
	local buffer_meta = state.get_buffer(bufnr)
	local lines = (buffer_meta and buffer_meta.lines) or api.nvim_buf_get_lines(bufnr, 0, -1, false)

	for i = 1, #lines do
		local line = lines[i]
		local dep_name = get_dependency_name_from_line(line, manifest_key)
		if dep_name and (installed_tbl[dep_name] or invalid_tbl[dep_name]) then
			local virt_parts
			if is_loading then
				if outdated_tbl[dep_name] or invalid_tbl[dep_name] then
					virt_parts = build_virt_parts(manifest_key, dep_name)
				else
					virt_parts = loading_parts
				end
			else
				if outdated_tbl[dep_name] or invalid_tbl[dep_name] then
					virt_parts = build_virt_parts(manifest_key, dep_name)
				else
					if installed_tbl[dep_name] then
						virt_parts = build_virt_parts(manifest_key, dep_name)
					end
				end
			end

			if virt_parts and #virt_parts > 0 then
				-- set extmark at EOL
				api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
					virt_text = virt_parts,
					virt_text_pos = "eol",
					priority = 200,
				})
			end
		end
	end

	-- record that virtual text is displayed
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
	if bufnr == -1 then return end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	-- fast path when loading
	if state.buffers[bufnr].is_loading then
		do_display(bufnr, manifest_key)
		return
	end

	-- debounce full render
	if state.buffers[bufnr].display_scheduled then
		state.buffers[bufnr].display_requested_manifest = manifest_key or state.buffers[bufnr].display_requested_manifest
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
	if bufnr == -1 then return end
    local ns = tonumber(ensure_namespace()) or 0
	api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
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

return M
