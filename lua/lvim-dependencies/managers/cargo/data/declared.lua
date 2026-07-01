-- lvim-dependencies.managers.cargo.data.declared: turns the parsed Cargo.toml dependency map
-- into typed declared-package records. Each raw value is classified through the manifest's
-- dependency-type detectors (registry/git/path/workspace/…); anything not matched falls back
-- to a plain registry record. This is the "declared" leg the core hub reads for a manager.
---@module "lvim-dependencies.managers.cargo.data.declared"

local parser = require("lvim-dependencies.managers.cargo.parser")
local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local common = require("lvim-dependencies.managers.common")

local debug = utils.debug

---@class CargoDeclared
local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get manifest (init.lua owns the cache)
---@return CargoManifest|nil
local function get_manifest()
    local m = init.get_manifest("cargo")
    ---@cast m CargoManifest|nil
    return m
end

--- Try to detect and build a DeclaredPackage using manifest dependency type definitions
---@param name string
---@param version any
---@param dep_types table<string, DependencyTypeDef>
---@return CargoDeclaredPackage|nil
local function detect_dependency_type(name, version, dep_types)
    local type_name, extracted = common.detect_dependency_type(version, dep_types)
    if not type_name then
        return nil
    end

    ---@type CargoDeclaredPackage
    local dep = { name = name, type = type_name, declared = nil, raw = version }
    if extracted then
        for k, v in pairs(extracted) do
            dep[k] = v
        end
    end
    return dep
end

--- Process a single dependency from raw data
---@param name string
---@param version any
---@param dep_types table<string, DependencyTypeDef>
---@return CargoDeclaredPackage
local function process_dependency(name, version, dep_types)
    local detected = detect_dependency_type(name, version, dep_types)
    if detected then
        return detected
    end

    return {
        name = name,
        type = "registry",
        declared = type(version) == "string" and version or (type(version) == "table" and version.version) or nil,
        raw = version,
    }
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get all declared packages from Cargo.toml
---@return table<string, CargoDeclaredPackage>
function M.get_data()
    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No manifest data, returning empty dependencies", vim.log.levels.ERROR)
        return {}
    end

    if not common.validate_manifest(manifest_data, { "dependency_types" }) then
        debug("Invalid manifest structure", vim.log.levels.ERROR)
        return {}
    end

    local raw_deps = parser.get_dependencies() or {}
    local dep_types = manifest_data.dependency_types or {}
    local result = {}

    for name, version in pairs(raw_deps) do
        result[name] = process_dependency(name, version, dep_types)
    end

    debug(string.format("Loaded %d declared packages", vim.tbl_count(result)), vim.log.levels.INFO)
    return result
end

--- Clear manifest cache — no-op, init.lua owns the cache.
function M.clear_cache()
    debug("Cargo declared cache cleared (no-op, init.lua owns manifest cache)", vim.log.levels.DEBUG)
end

return M
