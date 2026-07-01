-- lvim-dependencies.managers.pubspec.handler: the pubspec command handler (Command pattern).
-- Registers a single `execute(cmd, callback)` object with the core operator; a dispatch table
-- keyed by INSTALLER_METHODS routes each command type to its handler, and the handlers drive the
-- interactive install/update/delete flows (version/section/name pickers) before delegating the
-- actual file/CLI work to the api module. Loaded eagerly by register.lua so the operator knows
-- about pubspec at startup.
--
---@module "lvim-dependencies.managers.pubspec.handler"

local operator = require("lvim-dependencies.core.operator")
local const = require("lvim-dependencies.core.const")

local utils = require("lvim-dependencies.utils")
local ui = require("lvim-dependencies.ui")

local api = require("lvim-dependencies.managers.pubspec.api")
local helpers = require("lvim-dependencies.managers.pubspec.utils.helpers")

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

--- Show version selection UI
---@param package string
---@param versions_data VersionData
---@param scope string|nil
---@param callback InstallerCallback
local function show_version_selection(package, versions_data, scope, callback)
    local items = versions_data.versions or {}

    if #items == 0 then
        callback({ success = false, message = "No versions available for " .. package, packages = {} })
        return
    end

    local current_idx = 1
    for i, ver in ipairs(items) do
        if ver == versions_data.current then
            current_idx = i
            break
        end
    end

    local title = scope and string.format("Package: %s (%s)", package, scope) or string.format("Package: %s", package)

    ui.select("Select Version", title, "Choose version to install:", items, function(confirmed, idx)
        local saved_view = vim.fn.winsaveview()

        if not confirmed or not idx then
            callback({ success = false, message = "cancelled", packages = {} })
            return
        end

        local selected_version = items[idx]
        debug(string.format("Selected version %s for %s", selected_version, package), vim.log.levels.INFO)

        api.update_async(package, {
            version = selected_version,
            from_ui = true,
            scope = scope,
        }, function(result)
            vim.schedule(function()
                pcall(vim.fn.winrestview, saved_view)
            end)
            callback(result)
        end)
    end, {
        default_index = current_idx,
        current_item = versions_data.current,
    })
end

--- Show section selection UI then version selection
---@param package string
---@param versions_data VersionData
---@param sections string[]
---@param callback InstallerCallback
local function show_section_selection(package, versions_data, sections, callback)
    local total = #(versions_data.versions or {})
    local latest = versions_data.versions and versions_data.versions[1] or "unknown"
    local info = string.format("Total versions: %d, Latest: %s", total, latest)

    ui.select("Select Section", string.format("Package: %s", package), info, sections, function(confirmed, idx)
        if not confirmed or not idx then
            callback({ success = false, message = "cancelled", packages = {} })
            return
        end

        local selected_section = sections[idx]
        debug(string.format("Selected section %s for %s", selected_section, package), vim.log.levels.INFO)

        show_version_selection(package, versions_data, selected_section, callback)
    end, { default_index = 1 })
end

--- Show package name input UI
---@param sections string[]
---@param callback InstallerCallback
local function show_package_input(sections, callback)
    ui.input("Install Package", "Enter package name", "", function(confirmed, package_name)
        if not confirmed or not package_name or package_name == "" then
            callback({ success = false, message = "cancelled", packages = {} })
            return
        end

        package_name = package_name:match("^%s*(.-)%s*$") or package_name

        fetch_versions(package_name, function(versions_data)
            if not versions_data or #(versions_data.versions or {}) == 0 then
                callback({ success = false, message = "No versions available for " .. package_name, packages = {} })
                return
            end

            show_section_selection(package_name, versions_data, sections, callback)
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

    -- If package at cursor — show version selection for it
    local pkg = api.get_package_at_cursor()
    if pkg then
        fetch_versions(pkg, function(versions_data)
            if not versions_data or #(versions_data.versions or {}) == 0 then
                callback({ success = false, message = "No versions available for " .. pkg, packages = {} })
                return
            end
            show_version_selection(pkg, versions_data, nil, callback)
        end)
        return
    end

    -- If packages provided in payload — install first one
    local packages = cmd.payload.packages
    if packages and #packages > 0 then
        fetch_versions(packages[1], function(versions_data)
            if not versions_data or #(versions_data.versions or {}) == 0 then
                callback({ success = false, message = "No versions available for " .. packages[1], packages = {} })
                return
            end
            show_version_selection(packages[1], versions_data, nil, callback)
        end)
        return
    end

    -- Otherwise — show package name input
    show_package_input(sections, callback)
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

    fetch_versions(pkg, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available for " .. pkg, packages = {} })
            return
        end
        show_version_selection(pkg, versions_data, versions_data.section, callback)
    end)
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

    -- Version provided — update directly
    if version then
        api.update_async(package, {
            version = version,
            from_ui = cmd.opts.from_ui,
            scope = cmd.opts.scope,
        }, callback)
        return
    end

    -- No version — show version selection UI
    fetch_versions(package, function(versions_data)
        if not versions_data or #(versions_data.versions or {}) == 0 then
            callback({ success = false, message = "No versions available for " .. package, packages = {} })
            return
        end
        show_version_selection(package, versions_data, versions_data.section, callback)
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
    callback({
        success = true,
        message = "No outdated packages found",
        packages = {},
    })
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
            string.format("pubspec handler: %s (payload: %s)", cmd.type, vim.inspect(cmd.payload)),
            vim.log.levels.DEBUG
        )

        fn(cmd, callback)
    end,
}

-- ============================================================================
-- Register with executor
-- ============================================================================

operator.register_handler("pubspec", handler)

return handler
