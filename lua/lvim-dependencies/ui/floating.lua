local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local validator = require("lvim-dependencies.validator")
local confirm = require("lvim-dependencies.ui.confirm")
local L = vim.log.levels

local M = {}

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

	-- Check if package is actually in lock file
	if not utils.is_package_in_lock(manifest, name) then
		utils.notify_safe(("LvimDeps: %s is not installed (not found in lock file)"):format(name), L.WARN, {})
		return
	end

	local display_name = name
	if version and version ~= "" then
		display_name = ("%s@%s"):format(name, tostring(version))
	end

	local title = "DELETE"
	local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), tostring(canonical_scope))

	local subject = "Изтрийте следния пакет"
	local lines = { display_name }

	confirm.confirm_async(title, subtitle, subject, lines, function(confirmed)
		if not confirmed then
			return
		end

		local module_name = const.ACTION_MAP[manifest]
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
		opts.from_ui = true

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

	local module_name = const.ACTION_MAP[manifest]
	if not module_name then
		utils.notify_safe(("LvimDeps: unsupported manifest '%s'"):format(manifest), L.ERROR, {})
		return
	end

	local okreq, mod = pcall(require, module_name)
	if not okreq or type(mod) ~= "table" then
		utils.notify_safe(("LvimDeps: cannot load update action for %s"):format(manifest), L.ERROR, {})
		return
	end

	local base_opts = {}
	if canonical_scope then
		base_opts.scope = canonical_scope
	end

	local function do_update(selected_version)
		local opts = vim.tbl_extend("force", {}, base_opts)
		if selected_version and selected_version ~= "" then
			opts.version = tostring(selected_version)
		end

		opts.from_ui = true

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

	-- Check if package is in lock file to determine real current version
	local is_installed = utils.is_package_in_lock(manifest, name)

	local versions_result = nil
	if type(mod.fetch_versions) == "function" then
		local okv, vr = pcall(function()
			return mod.fetch_versions(name, base_opts)
		end)
		if okv and vr then
			versions_result = vr
		end
	end

	if versions_result then
		local versions = nil
		local current = nil

		if type(versions_result) == "table" and type(versions_result.versions) == "table" then
			versions = versions_result.versions
			current = versions_result.current
		elseif type(versions_result) == "table" then
			versions = versions_result
		end

		if versions and #versions > 0 then
			local lines = {}
			local index_map = {}
			local current_index = nil

			-- Only mark current if package is actually in lock
			local show_current = is_installed and current

			for _, v in ipairs(versions) do
				local vs = tostring(v)
				local label = (show_current and tostring(current) == vs) and ("● " .. vs) or ("  " .. vs)
				table.insert(lines, label)
				index_map[#lines] = vs
				if show_current and tostring(current) == vs then
					current_index = #lines
				end
			end

			local title = "UPDATE"
			local subject = tostring(name)
			if show_current then
				subject = subject .. " (current: " .. tostring(current) .. ")"
			else
				subject = subject .. " (not installed)"
			end
			local display_scope = canonical_scope and tostring(canonical_scope) or "<unspecified>"
			local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), display_scope)

			local confirm_opts = { border = "rounded", highlight_title = "Question" }
			if current_index then
				confirm_opts.default_index = current_index
			end

			confirm.confirm_async(title, subtitle, subject, lines, function(confirmed, selected)
				if not confirmed then
					return
				end

				local selected_version = nil
				if type(selected) == "number" then
					selected_version = index_map[selected]
				elseif type(selected) == "string" then
					for idx, lbl in ipairs(lines) do
						if lbl == selected then
							selected_version = index_map[idx]
							break
						end
					end
				end

				if not selected_version then
					selected_version = version
				end

				do_update(selected_version)
			end, confirm_opts)

			return
		end
	end

	-- Fallback
	local title = "UPDATE"
	local subject = tostring(name)

	if is_installed then
		local ok_state, state_mod = pcall(require, "lvim-dependencies.state")
		if ok_state and type(state_mod.get_installed_version) == "function" then
			local curv = state_mod.get_installed_version(manifest, name)
			if curv and curv ~= "" then
				subject = subject .. " (current: " .. tostring(curv) .. ")"
			end
		end
	else
		subject = subject .. " (not installed)"
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

		do_update(version)
	end)
end

M.install = function(manifest)
	if not manifest or manifest == "" then
		utils.notify_safe("LvimDeps: manifest not provided", L.ERROR, {})
		return
	end

	local module_name = const.ACTION_MAP[manifest]
	if not module_name then
		utils.notify_safe(("LvimDeps: unsupported manifest '%s'"):format(manifest), L.ERROR, {})
		return
	end

	local okreq, mod = pcall(require, module_name)
	if not okreq or type(mod) ~= "table" then
		utils.notify_safe(("LvimDeps: cannot load install action for %s"):format(manifest), L.ERROR, {})
		return
	end

	-- Step 1: Ask for package name
	confirm.input_async(
		"📦 INSTALL PACKAGE",
		("Manifest: %s"):format(tostring(manifest)),
		"Enter package name...",
		function(confirmed, package_name)
			if not confirmed or not package_name or package_name == "" then
				return
			end

			-- Trim whitespace
			package_name = package_name:match("^%s*(.-)%s*$")

			if package_name == "" then
				utils.notify_safe("LvimDeps: package name cannot be empty", L.WARN, {})
				return
			end

			-- Step 2: Fetch versions
			if type(mod.fetch_versions) ~= "function" then
				utils.notify_safe(("LvimDeps: fetch_versions not implemented for %s"):format(manifest), L.ERROR, {})
				return
			end

			local okv, versions_result = pcall(function()
				return mod.fetch_versions(package_name, {})
			end)

			if not okv or not versions_result then
				utils.notify_safe(("LvimDeps: failed to fetch versions for %s"):format(package_name), L.ERROR, {})
				return
			end

			local versions = nil
			if type(versions_result) == "table" and type(versions_result.versions) == "table" then
				versions = versions_result.versions
			elseif type(versions_result) == "table" then
				versions = versions_result
			end

			if not versions or #versions == 0 then
				utils.notify_safe(("LvimDeps: no versions found for %s"):format(package_name), L.WARN, {})
				return
			end

			-- Step 3: Show version selector
			local lines = {}
			local index_map = {}

			for i, v in ipairs(versions) do
				local vs = tostring(v)
				local marker = i == 1 and "→ " or "  " -- Latest version marker
				local label = marker .. vs
				table.insert(lines, label)
				index_map[#lines] = vs
			end

			local title = "SELECT VERSION"
			local subtitle = ("Package: %s    Manifest: %s"):format(package_name, tostring(manifest))
			local subject = string.format("Found %d versions (latest: %s)", #versions, tostring(versions[1]))

			confirm.confirm_async(title, subtitle, subject, lines, function(ver_confirmed, selected_idx)
				if not ver_confirmed or not selected_idx then
					return
				end

				local selected_version = index_map[selected_idx]
				if not selected_version then
					utils.notify_safe("LvimDeps: invalid version selection", L.ERROR, {})
					return
				end

				-- Step 4: Ask for scope (dependencies or dev_dependencies)
				local valid_scopes = const.SECTION_NAMES[manifest] or { "dependencies", "dev_dependencies" }

				-- Filter to only show relevant scopes
				local scope_lines = {}
				local scope_map = {}
				for _, sc in ipairs(valid_scopes) do
					if sc == "dependencies" or sc == "dev_dependencies" then
						table.insert(scope_lines, sc)
						scope_map[#scope_lines] = sc
					end
				end

				if #scope_lines == 0 then
					utils.notify_safe(("LvimDeps: no valid scopes found for %s"):format(manifest), L.ERROR, {})
					return
				end

				-- If only one scope, use it directly
				if #scope_lines == 1 then
					local scope = scope_map[1]

					-- Install the package
					if type(mod.update) ~= "function" then
						utils.notify_safe(
							("LvimDeps: install action not implemented for %s"):format(manifest),
							L.ERROR,
							{}
						)
						return
					end

					local opts = {
						version = selected_version,
						scope = scope,
						from_ui = true,
					}

					local success, res = pcall(function()
						return mod.update(package_name, opts)
					end)

					if not success then
						utils.notify_safe(("LvimDeps: install failed: %s"):format(tostring(res)), L.ERROR, {})
						return
					end

					if type(res) == "table" and res.ok == false then
						utils.notify_safe(
							("LvimDeps: failed to install %s: %s"):format(package_name, tostring(res.msg or "unknown")),
							L.ERROR,
							{}
						)
					else
						utils.notify_safe(
							("Installing %s@%s in %s..."):format(package_name, selected_version, scope),
							L.INFO,
							{}
						)
					end

					return
				end

				-- Multiple scopes - show selector
				local scope_title = "SELECT SCOPE"
				local scope_subtitle = ("Package: %s@%s    Manifest: %s"):format(
					package_name,
					selected_version,
					tostring(manifest)
				)
				local scope_subject = "Choose installation scope"

				confirm.confirm_async(
					scope_title,
					scope_subtitle,
					scope_subject,
					scope_lines,
					function(scope_confirmed, scope_idx)
						if not scope_confirmed or not scope_idx then
							return
						end

						local scope = scope_map[scope_idx]
						if not scope then
							utils.notify_safe("LvimDeps: invalid scope selection", L.ERROR, {})
							return
						end

						-- Install the package
						if type(mod.update) ~= "function" then
							utils.notify_safe(
								("LvimDeps: install action not implemented for %s"):format(manifest),
								L.ERROR,
								{}
							)
							return
						end

						local opts = {
							version = selected_version,
							scope = scope,
							from_ui = true,
						}

						local success, res = pcall(function()
							return mod.update(package_name, opts)
						end)

						if not success then
							utils.notify_safe(("LvimDeps: install failed: %s"):format(tostring(res)), L.ERROR, {})
							return
						end

						if type(res) == "table" and res.ok == false then
							utils.notify_safe(
								("LvimDeps: failed to install %s: %s"):format(
									package_name,
									tostring(res.msg or "unknown")
								),
								L.ERROR,
								{}
							)
						else
							utils.notify_safe(
								("Installing %s@%s in %s..."):format(package_name, selected_version, scope),
								L.INFO,
								{}
							)
						end
					end,
					{ default_index = 1 } -- Default to dependencies
				)
			end, { default_index = 1 }) -- Default to latest version
		end
	)
end

return M
