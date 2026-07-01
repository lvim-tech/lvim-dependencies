-- lvim-dependencies.managers.npm.utils.helpers: small shared utilities for the npm actions —
-- manifest accessors (file patterns, dependency sections), locating which section a package
-- lives in, reading a version straight from node_modules/<pkg>/package.json (faster than lock
-- parsing for single lookups), and URL-encoding scoped package names for registry requests.
--
---@module "lvim-dependencies.managers.npm.utils.helpers"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local file_ops = require("lvim-dependencies.managers.npm.core.file_ops")
local json_ops = require("lvim-dependencies.managers.npm.core.json_ops")

local debug = utils.debug

---@class NpmHelpers
local M = {}

-- ============================================================================
-- Manifest access
-- ============================================================================

--- Get manifest (init.lua owns the cache)
---@return NpmManifest|nil
function M.get_manifest()
    local m = init.get_manifest("npm")
    ---@cast m NpmManifest|nil
    return m
end

--- Manifest file patterns npm buffers are matched against.
---@return string[]
function M.get_file_patterns()
    local manifest = M.get_manifest()
    return (manifest and manifest.file_patterns) or { "package.json" }
end

--- The dependency sections scanned inside package.json.
---@return string[]
function M.get_dependency_sections()
    local manifest = M.get_manifest()
    return (manifest and manifest.dependency_sections)
        or { "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" }
end

-- ============================================================================
-- Package lookup
-- ============================================================================

--- Find which section a package belongs to in package.json
---@param pkg_name string
---@return string|nil section
function M.find_package_section(pkg_name)
    local path = file_ops.find_package_json_path()
    if not path then
        return nil
    end

    local content = file_ops.read_content(path)
    if not content then
        return nil
    end

    local data = json_ops.parse(content)
    if not data then
        return nil
    end

    for _, section in ipairs(M.get_dependency_sections()) do
        if data[section] and data[section][pkg_name] ~= nil then
            debug(string.format("Package '%s' found in section '%s'", pkg_name, section), vim.log.levels.DEBUG)
            return section
        end
    end

    debug(string.format("Package '%s' not found in any section", pkg_name), vim.log.levels.DEBUG)
    return nil
end

--- Read installed version from node_modules/pkg/package.json
--- Faster than parsing lock files for single-package lookups
---@param pkg_name string
---@return string|nil
function M.read_installed_from_node_modules(pkg_name)
    local path = file_ops.find_package_json_path()
    if not path then
        return nil
    end

    local dir = vim.fn.fnamemodify(path, ":h")
    local pkg_json = dir .. "/node_modules/" .. pkg_name .. "/package.json"

    local content = file_ops.read_content(pkg_json)
    if not content then
        return nil
    end

    local data = json_ops.parse(content)
    return data and data.version or nil
end

--- URL encode a string (for scoped packages like @scope/pkg)
---@param str string|nil
---@return string
function M.urlencode(str)
    str = str or ""
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return (string.gsub(str, " ", "+"))
end

--- Encode scoped package name for registry URL
--- "@scope/pkg" → "%40scope%2Fpkg" (for some registries)
--- or "@scope/pkg" → "@scope%2Fpkg" (for npmjs.com)
---@param pkg_name string
---@return string
function M.encode_package_name(pkg_name)
    if pkg_name:match("^@") then
        -- npmjs.com accepts @scope%2Fpkg
        local scope, name = pkg_name:match("^(@[^/]+)/(.+)$")
        if scope and name then
            return scope .. "%2F" .. name
        end
    end
    return pkg_name
end

--- No-op — init.lua owns manifest cache
function M.clear_cache()
    debug("npm helpers cache cleared (no-op)", vim.log.levels.DEBUG)
end

return M
