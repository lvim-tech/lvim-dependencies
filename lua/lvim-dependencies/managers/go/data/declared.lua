-- lvim-dependencies/managers/go/data/declared.lua
-- Declared package manager for go.mod

---@include "core/types.lua"

local parser = require("lvim-dependencies.managers.go.parser")
local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local common = require("lvim-dependencies.managers.common")

local debug = utils.debug

---@class GoDeclared
local M = {}

local function get_manifest()
    local m = init.get_manifest("go")
    ---@cast m GoManifest|nil
    return m
end

--- Detect and build a DeclaredPackage from raw data
---@param name string
---@param raw any  — {version: string, indirect: boolean, section: string}
---@param dep_types table<string, DependencyTypeDef>
---@return table
local function process_dependency(name, raw, dep_types)
    local version_str = type(raw) == "table" and raw.version or raw
    local section = type(raw) == "table" and raw.section or "require"
    local indirect = type(raw) == "table" and raw.indirect or false

    local type_name, extracted = common.detect_dependency_type(version_str, dep_types)

    local dep = {
        name = name,
        type = type_name or "registry",
        declared = type(version_str) == "string" and version_str or nil,
        raw = version_str,
        section = section,
        indirect = indirect,
    }

    if extracted then
        for k, v in pairs(extracted) do
            dep[k] = v
        end
    end

    return dep
end

-- ============================================================================
-- Public API
-- ============================================================================

---@return table<string, table>
function M.get_data()
    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No go manifest data", vim.log.levels.ERROR)
        return {}
    end

    local raw_deps = parser.get_dependencies() or {}
    local dep_types = manifest_data.dependency_types or {}
    local result = {}

    for name, raw in pairs(raw_deps) do
        result[name] = process_dependency(name, raw, dep_types)
    end

    debug(string.format("Loaded %d go declared packages", vim.tbl_count(result)), vim.log.levels.INFO)
    return result
end

function M.clear_cache()
    debug("go declared cache cleared (no-op)", vim.log.levels.DEBUG)
end

return M
