local utils = require("lvim-dependencies.utils")
local validator = require("lvim-dependencies.validator")
local confirm = require("lvim-dependencies.ui.confirm")
local L = vim.log.levels

local M = {}

local ACTION_MAP = {
	package = "lvim-dependencies.actions.package",
	crates = "lvim-dependencies.actions.cargo",
	pubspec = "lvim-dependencies.actions.pubspec",
	composer = "lvim-dependencies.actions.composer",
	go = "lvim-dependencies.actions.go",
}

M.delete = function(manifest, name, version, scope)
	if not manifest or manifest == "" then
		utils.notify_safe("LvimDeps: manifest not provided", L.ERROR, {})
		return
	end
	if not name or name == "" then
		utils.notify_safe("LvimDeps: package name not provided", L.ERROR, {})
		return
	end
	if not scope or scope == "" then
		utils.notify_safe("LvimDeps: scope not provided", L.ERROR, {})
		return
	end

	local ok, canonical_scope, verr = validator.validate_manifest_and_scope(manifest, scope)
	if not ok then
		utils.notify_safe(("LvimDeps: %s"):format(verr), L.ERROR, {})
		return
	end

	local display_name = name
	if version and version ~= "" then
		display_name = ("%s@%s"):format(name, tostring(version))
	end

	-- Prepare prompt pieces for the custom confirm dialog
	local title = "DELETE"
	local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), tostring(canonical_scope))

	-- subject as plain text and put package display name as selectable line
	local subject = "Изтрийте следния пакет"
	local lines = { display_name }

	confirm.confirm_async(title, subtitle, subject, lines, function(confirmed)
		if not confirmed then
			return
		end

		-- run action (same as before)
		local module_name = ACTION_MAP[manifest]
		if not module_name then
			utils.notify_safe(("LvimDeps: unsupported manifest '%s'"):format(manifest), L.ERROR, {})
			return
		end
		local okreq, mod = pcall(require, module_name)
		if not okreq or type(mod) ~= "table" or type(mod.delete) ~= "function" then
			utils.notify_safe(("LvimDeps: cannot load delete action for %s"):format(manifest), L.ERROR, {})
			return
		end

		local opts = { scope = canonical_scope }
		if version and version ~= "" then
			opts.version = version
		end

		local success, res = pcall(mod.delete, name, opts)
		if not success then
			utils.notify_safe(("LvimDeps: delete action failed: %s"):format(tostring(res)), L.ERROR, {})
			return
		end

		if type(res) == "table" and res.ok == false then
			utils.notify_safe(
				("LvimDeps: failed to delete %s: %s"):format(name, tostring(res.msg or "unknown")),
				L.ERROR,
				{}
			)
		else
			utils.notify_safe(("LvimDeps: removed %s from %s"):format(name, tostring(manifest)), L.INFO, {})
		end
	end)
end

M.update = function(manifest, name, version, scope)
	if not manifest or manifest == "" then
		utils.notify_safe("LvimDeps: manifest not provided", L.ERROR, {})
		return
	end
	if not name or name == "" then
		utils.notify_safe("LvimDeps: package name not provided", L.ERROR, {})
		return
	end

	local canonical_scope = nil
	if scope and scope ~= "" then
		local ok, cs, verr = validator.validate_manifest_and_scope(manifest, scope)
		if not ok then
			utils.notify_safe(("LvimDeps: %s"):format(verr), L.ERROR, {})
			return
		end
		canonical_scope = cs
	end

	local module_name = ACTION_MAP[manifest]
	if not module_name then
		utils.notify_safe(("LvimDeps: unsupported manifest '%s'"):format(manifest), L.ERROR, {})
		return
	end

	local okreq, mod = pcall(require, module_name)
	if not okreq or type(mod) ~= "table" then
		utils.notify_safe(("LvimDeps: cannot load update action for %s"):format(manifest), L.ERROR, {})
		return
	end

	-- base opts passed to fetch_versions / update
	local base_opts = {}
	if canonical_scope then
		base_opts.scope = canonical_scope
	end

	-- Helper that performs the actual update call
	local function do_update(selected_version)
		local opts = vim.tbl_extend("force", {}, base_opts)
		if selected_version and selected_version ~= "" then
			opts.version = tostring(selected_version)
		end

		if type(mod.update) ~= "function" then
			utils.notify_safe(("LvimDeps: update action not implemented for %s"):format(manifest), L.ERROR, {})
			return
		end

		local success, res = pcall(function()
			return mod.update(name, opts)
		end)
		if not success then
			utils.notify_safe(("LvimDeps: update action failed: %s"):format(tostring(res)), L.ERROR, {})
			return
		end

		if type(res) == "table" and res.ok == false then
			utils.notify_safe(
				("LvimDeps: failed to update %s: %s"):format(name, tostring(res.msg or "unknown")),
				L.ERROR,
				{}
			)
		else
			utils.notify_safe(("LvimDeps: updated %s in %s"):format(name, tostring(manifest)), L.INFO, {})
		end
	end

	-- Try to fetch available versions from the action module.
	-- Expected optional interface:
	--   mod.fetch_versions(name, opts) -> { versions = {...}, current = "x.y.z" } OR array of versions
	local versions_result = nil
	if type(mod.fetch_versions) == "function" then
		local okv, vr = pcall(function()
			return mod.fetch_versions(name, base_opts)
		end)
		if okv and vr then
			versions_result = vr
		end
	end

	-- If we have versions, show them immediately in the confirm popup (with current marked)
	if versions_result then
		local versions = nil
		local current = nil

		if type(versions_result) == "table" and type(versions_result.versions) == "table" then
			versions = versions_result.versions
			current = versions_result.current
		elseif type(versions_result) == "table" then
			-- assume array-like table of versions
			versions = versions_result
		end

		if versions and #versions > 0 then
			-- build lines for confirm dialog and an index->version map
			local lines = {}
			local index_map = {}
			local current_index = nil

			-- preserve original order of `versions`; mark current with bullet and record its index
			for i, v in ipairs(versions) do
				local vs = tostring(v)
				local label = (current and tostring(current) == vs) and ("● " .. vs) or ("  " .. vs)
				table.insert(lines, label)
				index_map[#lines] = vs
				if current and tostring(current) == vs then
					current_index = #lines
				end
			end

			-- Keep title unchanged; subject is package name + current version (no quotes)
			local title = "UPDATE"
			local subject = tostring(name)
			if current and current ~= "" then
				subject = subject .. " (current: " .. tostring(current) .. ")"
			end
			local display_scope = canonical_scope and tostring(canonical_scope) or "<unspecified>"
			local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), display_scope)

			-- prepare confirm options (pass default_index so confirm can preselect)
			local confirm_opts = { border = "rounded", highlight_title = "Question" }
			if current_index then
				confirm_opts.default_index = current_index
			end

			-- show confirm dialog with all versions as separate lines; callback receives (confirmed, selected_idx_or_value)
			confirm.confirm_async(title, subtitle, subject, lines, function(confirmed, selected)
				if not confirmed then
					return
				end

				-- determine selected index/version
				local selected_version = nil
				if type(selected) == "number" then
					selected_version = index_map[selected]
				elseif type(selected) == "string" then
					-- try to find matching line and map to version
					for idx, lbl in ipairs(lines) do
						if lbl == selected then
							selected_version = index_map[idx]
							break
						end
					end
				end

				-- if nothing selected, fallback to provided 'version' argument
				if not selected_version then
					selected_version = version
				end

				do_update(selected_version)
			end, confirm_opts)

			return
		end
	end

	-- Fallback: if no versions list available, ask a confirmation and use provided version (if any)
	local title = "UPDATE"
	local subject = tostring(name)
	-- try to include current if we can get it from state (best-effort)
	local ok_state, state_mod = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state_mod.get_installed_version) == "function" then
		local curv = state_mod.get_installed_version(manifest, name)
		if curv and curv ~= "" then
			subject = subject .. " (current: " .. tostring(curv) .. ")"
		end
	end
	local display_scope = canonical_scope and tostring(canonical_scope) or "<unspecified>"
	local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), display_scope)
	local lines = {}
	if version and version ~= "" then
		lines[#lines + 1] = ("Set %s -> %s"):format(name, tostring(version))
	else
		lines[#lines + 1] = ("Update %s (no version specified)"):format(name)
	end

	confirm.confirm_async(title, subtitle, subject, lines, function(confirmed)
		if not confirmed then
			return
		end

		-- perform update with provided version (may be nil)
		do_update(version)
	end)
end

M.install = function(manifest)
	print(manifest)
end

return M
