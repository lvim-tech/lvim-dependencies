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

	-- use display_name in the prompt so the local is not unused
	local display_name = name
	if version and version ~= "" then
		display_name = ("%s -> %s"):format(name, tostring(version))
	end

	local title = "UPDATE"
	local display_scope = canonical_scope and tostring(canonical_scope) or "<unspecified>"
	local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), display_scope)
	local lines = {}
	if version and version ~= "" then
		lines[#lines + 1] = ("Set %s"):format(display_name)
	else
		lines[#lines + 1] = ("Update %s (no version specified)"):format(name)
	end

	confirm.confirm_async(title, subtitle, lines, function(confirmed)
		if not confirmed then
			return
		end

		local module_name = ACTION_MAP[manifest]
		if not module_name then
			utils.notify_safe(("LvimDeps: unsupported manifest '%s'"):format(manifest), L.ERROR, {})
			return
		end
		local okreq, mod = pcall(require, module_name)
		if not okreq or type(mod) ~= "table" or type(mod.update) ~= "function" then
			utils.notify_safe(("LvimDeps: cannot load update action for %s"):format(manifest), L.ERROR, {})
			return
		end

		local opts = {}
		if version and version ~= "" then
			opts.version = version
		end
		if canonical_scope then
			opts.scope = canonical_scope
		end

		local success, res = pcall(mod.update, name, opts)
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
	end, { border = "rounded", highlight_title = "Question" })
end

M.install = function(manifest)
	print(manifest)
end

return M
