-- lvim-dependencies.managers.composer.handler: the Command-pattern handler that the core
-- operator dispatches to for composer (install / update / delete / check-outdated). It is the
-- UI-orchestration layer — resolve the target package (cursor, payload, or prompt), fetch the
-- available versions, drive the version-select UI, then hand the choice to the api. Platform
-- requirements are rejected up front (composer cannot require/remove them). It registers
-- itself with the operator at load time (last line).
--
---@module "lvim-dependencies.managers.composer.handler"

local operator = require("lvim-dependencies.core.operator")
local const = require("lvim-dependencies.core.const")
local utils = require("lvim-dependencies.utils")
local ui = require("lvim-dependencies.ui")

local api = require("lvim-dependencies.managers.composer.api")
local helpers = require("lvim-dependencies.managers.composer.utils.helpers")
local manifest = require("lvim-dependencies.managers.composer.manifest")

local debug = utils.debug
local notify = utils.notify

local INSTALLER_METHODS = const.INSTALLER_METHODS

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Delegates to manifest.is_package_actionable — no manager-specific logic here
---@param name string
---@return boolean
local function is_actionable(name)
    return manifest.is_package_actionable(name)
end

---@return string|nil
local function get_package_at_cursor()
    local pkg = api.get_package_at_cursor()
    if not pkg then
        notify("No package at cursor", vim.log.levels.WARN)
    end
    return pkg
end

---@param package string
---@param callback fun(versions_data: VersionData|nil)
local function fetch_versions(package, callback)
    api.fetch_versions_async(package, callback)
end

--- Show version selection UI
---@param package string
---@param versions_data VersionData
---@param callback fun(selected_version: string|nil)
local function show_version_selection(package, versions_data, callback)
    local items = versions_data.versions or {}
    if #items == 0 then
        callback(nil)
        return
    end

    local current_idx = 1
    for i, ver in ipairs(items) do
        if ver == versions_data.current then
            current_idx = i
            break
        end
    end

    ui.select(
        "Select Version",
        string.format("Package: %s", package),
        "Choose version:",
        items,
        function(confirmed, idx)
            if not confirmed or not idx then
                callback(nil)
                return
            end
            local selected = items[idx]
            debug(string.format("Selected version %s for %s", selected, package), vim.log.levels.INFO)
            callback(selected)
        end,
        { default_index = current_idx, current_item = versions_data.current }
    )
end

--- Complete update flow: fetch versions → show UI → update
---@param package string
---@param callback InstallerCallback
local function complete_update_flow(package, callback)
    fetch_versions(package, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available for " .. package, packages = {} })
            return
        end

        show_version_selection(package, versions_data, function(selected_version)
            if not selected_version then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end

            vim.schedule(function()
                api.update_async(package, {
                    version = selected_version,
                    scope = versions_data.section,
                    from_ui = true,
                }, function(result)
                    if result and not result.success then
                        result.no_retry = true
                    end
                    callback(result)
                end)
            end)
        end)
    end)
end

-- ============================================================================
-- Operation handlers
-- ============================================================================

---@param cmd Command
---@param callback InstallerCallback
local function handle_install(cmd, callback)
    local sections = helpers.get_dependency_sections()
    local _ = sections

    local pkg = api.get_package_at_cursor()
    if pkg then
        if not is_actionable(pkg) then
            notify(
                string.format("'%s' is a platform requirement — not manageable via composer", pkg),
                vim.log.levels.WARN
            )
            callback({ success = false, message = "", packages = {} })
            return
        end
        complete_update_flow(pkg, callback)
        return
    end

    local packages = cmd.payload.packages
    if packages and #packages > 0 then
        local p = packages[1]
        if not is_actionable(p) then
            callback({ success = false, message = "", packages = {} })
            return
        end
        complete_update_flow(p, callback)
        return
    end

    ui.input("Install Package", "Enter package name (vendor/package)", "", function(confirmed, package_name)
        if not confirmed or not package_name or package_name == "" then
            callback({ success = false, message = "cancelled", packages = {} })
            return
        end
        package_name = package_name:match("^%s*(.-)%s*$") or package_name
        if not is_actionable(package_name) then
            notify(
                string.format("'%s' is a platform requirement — not manageable via composer", package_name),
                vim.log.levels.WARN
            )
            callback({ success = false, message = "", packages = {} })
            return
        end
        complete_update_flow(package_name, callback)
    end)
end

---@param cmd Command
---@param callback InstallerCallback
local function handle_update(cmd, callback)
    local pkg = cmd.payload.packages and cmd.payload.packages[1] or get_package_at_cursor()
    if not pkg then
        callback({ success = false, message = "No package specified for update", packages = {} })
        return
    end
    if not is_actionable(pkg) then
        notify(
            string.format("'%s' is a platform requirement — not manageable via composer", pkg),
            vim.log.levels.WARN
        )
        callback({ success = false, message = "", packages = {} })
        return
    end
    complete_update_flow(pkg, callback)
end

---@param cmd Command
---@param callback InstallerCallback
local function handle_update_direct(cmd, callback)
    local package = cmd.payload.package
    local version = cmd.payload.version

    if not package then
        callback({ success = false, message = "No package specified for direct update", packages = {} })
        return
    end
    if not is_actionable(package) then
        callback({ success = false, message = "", packages = {} })
        return
    end

    if version then
        api.update_async(package, {
            version = version,
            from_ui = cmd.opts and cmd.opts.from_ui,
        }, callback)
        return
    end

    fetch_versions(package, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available for " .. package, packages = {} })
            return
        end

        show_version_selection(package, versions_data, function(selected_version)
            if not selected_version then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end

            api.update_async(package, {
                version = selected_version,
                from_ui = true,
            }, callback)
        end)
    end)
end

---@param cmd Command
---@param callback InstallerCallback
local function handle_delete(cmd, callback)
    local pkg = cmd.payload.packages and cmd.payload.packages[1] or get_package_at_cursor()
    if not pkg then
        callback({ success = false, message = "No package specified for delete", packages = {} })
        return
    end
    api.delete(pkg, { from_ui = cmd.opts and cmd.opts.from_ui }, callback)
end

---@param cmd Command
---@param callback InstallerCallback
local function handle_check_outdated(cmd, callback)
    debug(string.format("check_outdated called for %s", cmd.manager), vim.log.levels.INFO)
    callback({ success = true, message = "Use `composer outdated` in terminal", packages = {} })
end

-- ============================================================================
-- Dispatch table
-- ============================================================================

---@type table<string, fun(cmd: Command, callback: InstallerCallback)>
local dispatch = {
    [INSTALLER_METHODS.INSTALL] = handle_install,
    [INSTALLER_METHODS.UPDATE] = handle_update,
    [INSTALLER_METHODS.UPDATE_DIRECT] = handle_update_direct,
    [INSTALLER_METHODS.DELETE] = handle_delete,
    [INSTALLER_METHODS.CHECK_OUTDATED] = handle_check_outdated,
}

-- ============================================================================
-- Handler object
-- ============================================================================

local handler = {
    ---@param cmd Command
    ---@param callback InstallerCallback
    execute = function(cmd, callback)
        local fn = dispatch[cmd.type]
        if not fn then
            callback({
                success = false,
                message = string.format("Unknown command type: %s", cmd.type),
                packages = {},
            })
            return
        end

        debug(
            string.format("composer handler: %s (payload: %s)", cmd.type, vim.inspect(cmd.payload)),
            vim.log.levels.DEBUG
        )

        fn(cmd, callback)
    end,
}

-- ============================================================================
-- Register with executor
-- ============================================================================

operator.register_handler("composer", handler)

return handler
