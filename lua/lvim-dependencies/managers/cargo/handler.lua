-- lvim-dependencies/managers/cargo/handler.lua
-- Command Pattern: cargo handler — implements execute(cmd, callback)

---@include "core/types.lua"

local operator = require("lvim-dependencies.core.operator")
local const = require("lvim-dependencies.core.const")

local utils = require("lvim-dependencies.utils")
local ui = require("lvim-dependencies.ui.popup")

local api = require("lvim-dependencies.managers.cargo.api")
local helpers = require("lvim-dependencies.managers.cargo.utils.helpers")
local features = require("lvim-dependencies.managers.cargo.features")

local debug = utils.debug
local notify = utils.notify

-- ============================================================================
-- Constants
-- ============================================================================
local INSTALLER_METHODS = const.INSTALLER_METHODS

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Get package at cursor
---@return string|nil
local function get_package_at_cursor()
    local pkg = api.get_package_at_cursor()
    if not pkg then
        notify("No package at cursor", vim.log.levels.WARN)
    end
    return pkg
end

--- Fetch versions for a package
---@param package string
---@param callback fun(versions_data: VersionData|nil)
local function fetch_versions(package, callback)
    api.fetch_versions_async(package, callback)
end

--- Fetch features for a package
---@param package string
---@param callback fun(features_data: table|nil)
local function fetch_features(package, callback)
    -- Use features.fetch_available_features instead of api.fetch_features_async
    features.fetch_available_features(package, function(available_features, err)
        if err then
            debug(string.format("Error fetching features for %s: %s", package, err), vim.log.levels.ERROR)
            callback(nil)
            return
        end

        -- Convert array of features to the format expected by the UI
        local features_data = {
            available = {},
        }
        for _, feature in ipairs(available_features or {}) do
            features_data.available[feature] = true
        end

        callback(features_data)
    end)
end

--- Show version selection UI
---@param package string
---@param versions_data VersionData
---@param callback fun(selected_version: string)
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

            local selected_version = items[idx]
            debug(string.format("Selected version %s for %s", selected_version, package), vim.log.levels.INFO)
            callback(selected_version)
        end,
        {
            default_index = current_idx,
            current_item = versions_data.current,
        }
    )
end

--- Show features selection UI
---@param package string
---@param features_data table
---@param current_features string[]
---@param callback fun(selected_features: string[], default_features: boolean, optional: boolean)
local function show_features_selection(package, features_data, current_features, callback)
    if not features_data or not features_data.available then
        -- No features available, proceed without features
        callback({}, true, false)
        return
    end

    -- Convert features table to list for UI
    local available = {}
    for feature in pairs(features_data.available) do
        table.insert(available, feature)
    end
    table.sort(available)

    -- Build checkboxes for features
    local checkboxes = {}
    for _, feature in ipairs(available) do
        table.insert(checkboxes, {
            text = feature,
            checked = vim.tbl_contains(current_features or {}, feature),
        })
    end

    -- TODO: Implement multi-select UI for features
    -- For now, just proceed with current features
    debug(string.format("Features UI not yet implemented, using current features"), vim.log.levels.INFO)
    callback(current_features or {}, true, false)
end

--- Show package name input UI
---@param sections string[]
---@param callback fun(package_name: string|nil)
local function show_package_input(sections, callback)
    local _ = sections -- mark as unused, but keep for future use

    ui.input("Install Package", "Enter package name", "", function(confirmed, package_name)
        if not confirmed or not package_name or package_name == "" then
            callback(nil)
            return
        end

        package_name = package_name:match("^%s*(.-)%s*$") or package_name
        callback(package_name)
    end)
end

--- Complete install flow: package → version → features → install
---@param package string|nil
---@param callback InstallerCallback
local function complete_install_flow(package, callback)
    if not package then
        callback({ success = false, message = "No package specified", packages = {} })
        return
    end

    -- Step 1: Fetch versions
    fetch_versions(package, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available for " .. package, packages = {} })
            return
        end

        -- Step 2: Show version selection
        show_version_selection(package, versions_data, function(selected_version)
            if not selected_version then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end

            -- Step 3: Fetch features
            fetch_features(package, function(features_data)
                -- Step 4: Show features selection
                -- TODO: Get current features from package if it exists
                show_features_selection(
                    package,
                    features_data,
                    {},
                    function(selected_features, default_features, optional)
                        -- Step 5: Install with selected options
                        vim.schedule(function()
                            api.update_async(package, {
                                version = selected_version,
                                from_ui = true,
                                features = selected_features,
                                default_features = default_features,
                                optional = optional,
                            }, function(result)
                                if result and not result.success then
                                    result.no_retry = true
                                end
                                callback(result)
                            end)
                        end)
                    end
                )
            end)
        end)
    end)
end

--- Complete update flow: package → version → features → update
---@param package string
---@param callback InstallerCallback
local function complete_update_flow(package, callback)
    -- Step 1: Fetch versions
    fetch_versions(package, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available for " .. package, packages = {} })
            return
        end

        -- Step 2: Show version selection
        show_version_selection(package, versions_data, function(selected_version)
            if not selected_version then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end

            -- Step 3: Fetch features
            fetch_features(package, function(features_data)
                -- Step 4: Get current features from package
                local current = features.get_current_features(package)

                -- Step 5: Show features selection
                show_features_selection(
                    package,
                    features_data,
                    current.features,
                    function(selected_features, default_features, optional)
                        -- Step 6: Update with selected options
                        vim.schedule(function()
                            api.update_async(package, {
                                version = selected_version,
                                from_ui = true,
                                features = selected_features,
                                default_features = default_features,
                                optional = optional,
                            }, function(result)
                                if result and not result.success then
                                    result.no_retry = true
                                end
                                callback(result)
                            end)
                        end)
                    end
                )
            end)
        end)
    end)
end

-- ============================================================================
-- Operation handlers
-- ============================================================================

--- Handle install command
---@param cmd Command
---@param callback InstallerCallback
local function handle_install(cmd, callback)
    local sections = helpers.get_dependency_sections()

    -- If package at cursor — start install flow for it
    local pkg = api.get_package_at_cursor()
    if pkg then
        complete_install_flow(pkg, callback)
        return
    end

    -- If packages provided in payload — install first one
    local packages = cmd.payload.packages
    if packages and #packages > 0 then
        complete_install_flow(packages[1], callback)
        return
    end

    -- Otherwise — show package name input
    show_package_input(sections, function(package_name)
        if package_name then
            complete_install_flow(package_name, callback)
        else
            callback({ success = false, message = "cancelled", packages = {} })
        end
    end)
end

--- Handle update command
---@param cmd Command
---@param callback InstallerCallback
local function handle_update(cmd, callback)
    local pkg = cmd.payload.packages and cmd.payload.packages[1] or get_package_at_cursor()

    if not pkg then
        callback({ success = false, message = "No package specified for update", packages = {} })
        return
    end

    complete_update_flow(pkg, callback)
end

--- Handle update_direct command
---@param cmd Command
---@param callback InstallerCallback
local function handle_update_direct(cmd, callback)
    local package = cmd.payload.package
    local version = cmd.payload.version

    if not package then
        callback({ success = false, message = "No package specified for direct update", packages = {} })
        return
    end

    -- Version provided — update directly with current features
    if version then
        local current = features.get_current_features(package)
        api.update_async(package, {
            version = version,
            from_ui = cmd.opts.from_ui,
            features = current.features,
            default_features = current.default_features,
            optional = current.optional,
        }, callback)
        return
    end

    -- No version — show version selection UI
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

            local current = features.get_current_features(package)
            api.update_async(package, {
                version = selected_version,
                from_ui = true,
                features = current.features,
                default_features = current.default_features,
                optional = current.optional,
            }, callback)
        end)
    end)
end

--- Handle delete command
---@param cmd Command
---@param callback InstallerCallback
local function handle_delete(cmd, callback)
    local pkg = cmd.payload.packages and cmd.payload.packages[1] or get_package_at_cursor()

    if not pkg then
        callback({ success = false, message = "No package specified for delete", packages = {} })
        return
    end

    api.delete(pkg, {
        from_ui = cmd.opts.from_ui,
    }, callback)
end

--- Handle check_outdated command
---@param cmd Command
---@param callback InstallerCallback
local function handle_check_outdated(cmd, callback)
    debug(string.format("check_outdated called for %s", cmd.manager), vim.log.levels.INFO)

    -- TODO: Implement `cargo outdated` integration
    callback({
        success = true,
        message = "Outdated check not yet implemented",
        packages = {},
    })
end

--- Handle features command (custom for cargo)
---@param cmd Command
---@param callback InstallerCallback
local function handle_features(cmd, callback)
    local package = cmd.payload.package or get_package_at_cursor()

    if not package then
        callback({ success = false, message = "No package specified for features", packages = {} })
        return
    end

    -- Fetch available features
    fetch_features(package, function(features_data)
        -- Get current features from package
        local current = features.get_current_features(package)

        -- Show features UI
        features.show_ui(package, vim.api.nvim_get_current_buf())

        -- Callback with success
        callback({ success = true, message = "Features UI opened", packages = { package } })
    end)
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
    -- Custom command for features
    features = handle_features,
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
            string.format("cargo handler: %s (payload: %s)", cmd.type, vim.inspect(cmd.payload)),
            vim.log.levels.DEBUG
        )

        fn(cmd, callback)
    end,
}

-- ============================================================================
-- Register with executor
-- ============================================================================

operator.register_handler("cargo", handler)

return handler
