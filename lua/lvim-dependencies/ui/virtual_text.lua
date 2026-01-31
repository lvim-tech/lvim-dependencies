local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local validator = require("lvim-dependencies.validator")

local M = {}

local function ensure_namespace()
	if not state.namespace or not state.namespace.id then
		state.namespace = state.namespace or {}
		state.namespace.id = state.namespace.id or vim.api.nvim_create_namespace("lvim_dependencies")
	end
	return state.namespace.id
end

local function filename_to_manifest_key(filename)
	if state.get_manifest_key_from_filename then
		local mk = state.get_manifest_key_from_filename(filename)
		if mk then
			return mk
		end
	end
	if filename == "package.json" then
		return "package"
	end
	if filename == "Cargo.toml" then
		return "crates"
	end
	if filename == "pubspec.yaml" or filename == "pubspec.yml" then
		return "pubspec"
	end
	if filename == "composer.json" then
		return "composer"
	end
	if filename == "go.mod" then
		return "go"
	end
	return nil
end

local function get_dependency_name_from_line(line, manifest_key)
	if not line then
		return nil
	end
	if manifest_key == "package" or manifest_key == "composer" then
		local parts = {}
		for chunk in string.gmatch(line, [["(.-)"]]) do
			table.insert(parts, chunk)
			if #parts >= 2 then
				break
			end
		end
		return parts[1]
	elseif manifest_key == "crates" then
		return line:match("^%s*([%w_%-]+)%s*=")
	elseif manifest_key == "pubspec" then
		return line:match("^%s+([%w_%-]+):")
	elseif manifest_key == "go" then
		local name = line:match("^%s*require%s+([^%s]+)")
		if name then
			return name
		end
		name = line:match("^%s+([^%s]+)%s+[^%s]+")
		if name and name:match("%/") then
			return name
		end
		name = line:match("^%s*([^%s]+)%s+v[%d%w%-%+%.]+")
		if name and name:match("%/") then
			return name
		end
	end
	return nil
end

local function build_virt_parts(manifest_key, dep_name)
	-- use config values directly from config module
	local deps = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed = deps.installed and deps.installed[dep_name]
	local outdated = deps.outdated and deps.outdated[dep_name]
	local invalid = deps.invalid and deps.invalid[dep_name]

	if invalid then
		local pieces = {}
		pieces[#pieces + 1] = { config.ui.virtual_text.prefix, config.ui.highlight.groups.separator }
		local diag = invalid.diagnostic or "ERR"
		if config.ui.virtual_text.show_status_icon and config.ui.virtual_text.icon_when_invalid then
			pieces[#pieces + 1] =
				{ config.ui.virtual_text.icon_when_invalid .. " " .. diag, config.ui.highlight.groups.invalid }
		else
			pieces[#pieces + 1] = { diag, config.ui.highlight.groups.invalid }
		end
		return pieces
	end

	if outdated and outdated.latest then
		local latest = tostring(outdated.latest)
		local cur = installed and installed.current and tostring(installed.current) or nil
		local is_up_to_date = (cur ~= nil and cur == latest)

		if outdated.constraint_newer then
			local txt = tostring(latest) .. " (constraint)"
			if config.ui.virtual_text.show_status_icon and config.ui.virtual_text.icon_when_constraint_newer then
				return {
					{ config.ui.virtual_text.prefix, config.ui.highlight.groups.separator },
					{
						config.ui.virtual_text.icon_when_constraint_newer .. " " .. txt,
						config.ui.highlight.groups.constraint_newer,
					},
				}
			else
				return {
					{ config.ui.virtual_text.prefix, config.ui.highlight.groups.separator },
					{ txt, config.ui.highlight.groups.constraint_newer },
				}
			end
		end

		local pieces = {}
		pieces[#pieces + 1] = { config.ui.virtual_text.prefix, config.ui.highlight.groups.separator }
		if is_up_to_date then
			if config.ui.virtual_text.show_status_icon and config.ui.virtual_text.icon_when_up_to_date then
				pieces[#pieces + 1] = {
					config.ui.virtual_text.icon_when_up_to_date .. " " .. latest,
					config.ui.highlight.groups.up_to_date,
				}
			else
				pieces[#pieces + 1] = { latest, config.ui.highlight.groups.up_to_date }
			end
		else
			if config.ui.virtual_text.show_status_icon and config.ui.virtual_text.icon_when_outdated then
				pieces[#pieces + 1] =
					{ config.ui.virtual_text.icon_when_outdated .. " " .. latest, config.ui.highlight.groups.outdated }
			else
				pieces[#pieces + 1] = { latest, config.ui.highlight.groups.outdated }
			end
		end
		return pieces
	end

	if installed and installed.current then
		local cur = tostring(installed.current)
		local pieces = {}
		pieces[#pieces + 1] = { config.ui.virtual_text.prefix, config.ui.highlight.groups.separator }
		if config.ui.virtual_text.show_status_icon and config.ui.virtual_text.icon_when_up_to_date then
			pieces[#pieces + 1] =
				{ config.ui.virtual_text.icon_when_up_to_date .. " " .. cur, config.ui.highlight.groups.up_to_date }
		else
			pieces[#pieces + 1] = { cur, config.ui.highlight.groups.up_to_date }
		end
		return pieces
	end

	return nil
end

local function get_loading_parts()
	return {
		{ config.ui.virtual_text.prefix, config.ui.highlight.groups.separator },
		{ config.ui.virtual_text.loading, config.ui.highlight.groups.loading },
	}
end

local do_display

do_display = function(bufnr, manifest_key)
	if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	manifest_key = manifest_key or filename_to_manifest_key(filename)
	if not manifest_key then
		return
	end

	-- ensure manifest_key is supported by validator
	if not validator.is_supported_manifest(manifest_key) then
		return
	end

	-- use config.ui.virtual_text.enabled if present (honour explicit false)
	if config.ui.virtual_text.enabled == false then
		return
	end

	local ns = ensure_namespace()
	ns = tonumber(ns) or 0
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)

	local deps_tbl = state.get_dependencies(manifest_key) or { installed = {}, outdated = {}, invalid = {} }
	local installed_tbl = deps_tbl.installed or {}
	local outdated_tbl = deps_tbl.outdated or {}
	local invalid_tbl = deps_tbl.invalid or {}

	local is_loading = false
	if state.buffers and state.buffers[bufnr] and state.buffers[bufnr].is_loading then
		is_loading = true
	end

	local loading_parts = nil
	if is_loading then
		loading_parts = get_loading_parts()
	end

	local ok_lines, lines = pcall(function()
		local buffer_meta = state.get_buffer and state.get_buffer(bufnr) or nil
		return buffer_meta and buffer_meta.lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end)
	if not ok_lines or not lines then
		lines = {}
	end

	for i = 1, #lines do
		local line = lines[i]
		local dep_name = get_dependency_name_from_line(line, manifest_key)

		if dep_name and (installed_tbl[dep_name] or invalid_tbl[dep_name]) then
			local virt_parts = nil

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
				local ok_buf = pcall(vim.api.nvim_buf_is_valid, bufnr)
				if ok_buf and vim.api.nvim_buf_is_valid(bufnr) then
					pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, i - 1, 0, {
						virt_text = virt_parts,
						virt_text_pos = "eol",
						priority = 200,
					})
				end
			end
		end
	end

	if state.set_virtual_text_displayed then
		pcall(state.set_virtual_text_displayed, bufnr, true)
	elseif state.buffers and state.buffers[bufnr] then
		state.buffers[bufnr].is_virtual_text_displayed = true
	end
end

M.display = function(bufnr, manifest_key)
	bufnr = bufnr or vim.fn.bufnr()
	if bufnr == -1 then
		return
	end

	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	local is_loading = state.buffers[bufnr].is_loading
	if is_loading then
		pcall(do_display, bufnr, manifest_key)
		return
	end

	if state.buffers[bufnr].display_scheduled then
		state.buffers[bufnr].display_requested_manifest = manifest_key
			or state.buffers[bufnr].display_requested_manifest
		return
	end

	state.buffers[bufnr].display_scheduled = true
	state.buffers[bufnr].display_requested_manifest = manifest_key

	vim.defer_fn(function()
		state.buffers[bufnr].display_scheduled = false
		local mk = state.buffers[bufnr].display_requested_manifest
		state.buffers[bufnr].display_requested_manifest = nil
		do_display(bufnr, mk)
	end, config.performance.deferred_full_render_ms)
end

M.clear = function(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	if bufnr == -1 then
		return
	end
	local ns = ensure_namespace()
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
	if state.set_virtual_text_displayed then
		pcall(state.set_virtual_text_displayed, bufnr, false)
	end
	if state.buffers and state.buffers[bufnr] then
		state.buffers[bufnr].display_scheduled = false
		state.buffers[bufnr].display_requested_manifest = nil
	end
end

M.debug_extmarks = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ns = ensure_namespace()
	local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, bufnr, ns, 0, -1, { details = true })
	if not ok or not marks then
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
