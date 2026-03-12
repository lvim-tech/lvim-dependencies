-- lvim-dependencies/managers/go/data/installed.lua
-- Installed version reader for Go modules
--
-- In Go modules, the "installed" version is the one declared in go.mod.
-- go.sum is NOT used for version lookups because it accumulates checksums
-- for every version ever downloaded — the same package can appear dozens
-- of times with different versions (e.g. v1.4.9, v1.4.11, v1.4.12, v1.4.13).

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local parser = require("lvim-dependencies.managers.go.parser")

local debug = utils.debug

---@class GoInstalled
local M = {}

-- ============================================================================
-- Public API
-- ============================================================================

---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
function M.get_package_installed(package_name, callback)
    local deps = parser.get_dependencies()
    local pkg = deps[package_name]
    if pkg and pkg.version then
        debug(string.format("go installed: %s = %s (from go.mod)", package_name, pkg.version), vim.log.levels.INFO)
        callback(nil, pkg.version)
        return
    end

    debug(string.format("go: %s not found in go.mod", package_name), vim.log.levels.INFO)
    callback(nil, nil)
end

---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end
    local deps = parser.get_dependencies()
    local result = {}
    for name in pairs(declared_packages) do
        local pkg = deps[name]
        result[name] = pkg and pkg.version or nil
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("go")
    debug("go installed cache cleared (via hub)", vim.log.levels.INFO)
end

return M
