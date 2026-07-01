-- lvim-dependencies.core.operation: the Command half of a Command pattern. Pure data —
-- each constructor (install/update/update_direct/delete/check_outdated) builds a
-- normalized Command table (type, manager, payload, opts, callback) with defaults filled
-- in; core.operator later dispatches it to the manager's handler. No side effects here.
--
---@module "lvim-dependencies.core.operation"

local const = require("lvim-dependencies.core.const")

-- ============================================================================
-- Command type definition
-- ============================================================================

---@class Command
---@field type string
---@field manager string
---@field payload table
---@field opts table
---@field callback InstallerCallback

-- ============================================================================
-- Internal constructor
-- ============================================================================

---@param cmd_type string
---@param manager string
---@param payload table
---@param opts table|nil
---@param callback InstallerCallback|nil
---@return Command
local function new(cmd_type, manager, payload, opts, callback)
    assert(type(cmd_type) == "string", "command type must be a string")
    assert(type(manager) == "string", "manager must be a string")

    if type(payload) ~= "table" then
        payload = {}
    end

    if type(opts) ~= "table" then
        opts = {}
    end

    -- make callback optional
    if type(callback) ~= "function" then
        callback = function() end
    end

    return {
        type = cmd_type,
        manager = manager,
        payload = payload,
        opts = opts,
        callback = callback,
    }
end

-- ============================================================================
-- Public constructors
-- ============================================================================

local M = {}

---@param manager string
---@param packages string[]|nil
---@param opts? table
---@param callback? InstallerCallback
---@return Command
function M.install(manager, packages, opts, callback)
    return new(const.INSTALLER_METHODS.INSTALL, manager, { packages = packages or {} }, opts, callback)
end

---@param manager string
---@param packages string[]|nil
---@param opts? table
---@param callback? InstallerCallback
---@return Command
function M.update(manager, packages, opts, callback)
    return new(const.INSTALLER_METHODS.UPDATE, manager, { packages = packages or {} }, opts, callback)
end

---@param manager string
---@param package string
---@param version string|nil
---@param opts? table
---@param callback? InstallerCallback
---@return Command
function M.update_direct(manager, package, version, opts, callback)
    return new(const.INSTALLER_METHODS.UPDATE_DIRECT, manager, { package = package, version = version }, opts, callback)
end

---@param manager string
---@param packages string[]|nil
---@param opts? table
---@param callback? InstallerCallback
---@return Command
function M.delete(manager, packages, opts, callback)
    return new(const.INSTALLER_METHODS.DELETE, manager, { packages = packages or {} }, opts, callback)
end

---@param manager string
---@param opts? table
---@param callback? InstallerCallback
---@return Command
function M.check_outdated(manager, opts, callback)
    return new(const.INSTALLER_METHODS.CHECK_OUTDATED, manager, {}, opts, callback)
end

return M
