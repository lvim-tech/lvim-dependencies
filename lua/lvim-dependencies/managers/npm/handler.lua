-- lvim-dependencies/managers/npm/handler.lua
-- Command handler for npm/yarn/pnpm

---@include "core/types.lua"

local operator = require("lvim-dependencies.core.operator")
local const = require("lvim-dependencies.core.const")
local utils = require("lvim-dependencies.utils")
local ui = require("lvim-dependencies.ui")
local actions = require("lvim-dependencies.managers.npm.api")

local debug = utils.debug
local notify = utils.notify

local INSTALLER_METHODS = const.INSTALLER_METHODS

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function get_package_at_cursor()
    local pkg = actions.get_package_at_cursor()
    if not pkg then
        notify("No package at cursor", vim.log.levels.WARN)
    end
    return pkg
end

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
            callback(items[idx])
        end,
        { default_index = current_idx, current_item = versions_data.current }
    )
end

local function complete_update_flow(package, callback)
    actions.fetch_versions_async(package, function(versions_data)
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
                actions.update_async(package, { version = selected_version, from_ui = true }, function(result)
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

local function handle_install(cmd, callback)
    local pkg = actions.get_package_at_cursor() or (cmd.payload.packages and cmd.payload.packages[1])

    if not pkg then
        ui.input("Install Package", "Enter package name", "", function(confirmed, package_name)
            if not confirmed or not package_name or package_name == "" then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end
            complete_update_flow(package_name:match("^%s*(.-)%s*$"), callback)
        end)
        return
    end

    complete_update_flow(pkg, callback)
end

local function handle_update(cmd, callback)
    local pkg = (cmd.payload.packages and cmd.payload.packages[1]) or get_package_at_cursor()
    if not pkg then
        callback({ success = false, message = "No package specified", packages = {} })
        return
    end
    complete_update_flow(pkg, callback)
end

local function handle_update_direct(cmd, callback)
    local package = cmd.payload.package
    local version = cmd.payload.version
    if not package then
        callback({ success = false, message = "No package specified", packages = {} })
        return
    end

    if version then
        actions.update_async(package, { version = version, from_ui = cmd.opts.from_ui }, callback)
        return
    end

    actions.fetch_versions_async(package, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available", packages = {} })
            return
        end
        show_version_selection(package, versions_data, function(selected)
            if not selected then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end
            actions.update_async(package, { version = selected, from_ui = true }, callback)
        end)
    end)
end

local function handle_delete(cmd, callback)
    local pkg = (cmd.payload.packages and cmd.payload.packages[1]) or get_package_at_cursor()
    if not pkg then
        callback({ success = false, message = "No package specified", packages = {} })
        return
    end
    actions.delete(pkg, { from_ui = cmd.opts and cmd.opts.from_ui }, callback)
end

local function handle_check_outdated(_, callback)
    debug("npm check_outdated: not yet implemented", vim.log.levels.INFO)
    callback({ success = true, message = "Use npm outdated in terminal", packages = {} })
end

-- ============================================================================
-- Dispatch
-- ============================================================================

---@type table<string, fun(cmd: Command, callback: InstallerCallback)>
local dispatch = {
    [INSTALLER_METHODS.INSTALL] = handle_install,
    [INSTALLER_METHODS.UPDATE] = handle_update,
    [INSTALLER_METHODS.UPDATE_DIRECT] = handle_update_direct,
    [INSTALLER_METHODS.DELETE] = handle_delete,
    [INSTALLER_METHODS.CHECK_OUTDATED] = handle_check_outdated,
}

local handler = {
    execute = function(cmd, callback)
        local fn = dispatch[cmd.type]
        if not fn then
            callback({ success = false, message = "Unknown command: " .. tostring(cmd.type), packages = {} })
            return
        end
        debug(string.format("npm handler: %s", cmd.type), vim.log.levels.DEBUG)
        fn(cmd, callback)
    end,
}

operator.register_handler("npm", handler)

return handler
