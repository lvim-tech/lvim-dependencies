-- lvim-dependencies.managers.pubspec.data.declared: turns the parser's raw name→value map into
-- typed PubspecDeclaredPackage records. Each raw value is classified via the manifest's
-- dependency_types detectors (git/path/sdk/hosted/registry/…); SDK packages short-circuit to a
-- "sdk" record and anything unrecognised falls back to "registry". Keeps a local manifest cache
-- (validated for a dependency_types field) that clear_cache resets.
--
---@module "lvim-dependencies.managers.pubspec.data.declared"

local parser = require("lvim-dependencies.managers.pubspec.parser")
local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local common = require("lvim-dependencies.managers.common")

local debug = utils.debug

---@class PubspecDeclared
local M = {}

--- Cache for manifest data
---@type PubspecManifest|nil
local manifest_cache = nil

--- Known SDK packages that skip registry lookup
---@type table<string, boolean>
local SDK_PACKAGES = {
    flutter = true,
    dart = true,
    sky_engine = true,
}

--- Check if package is an SDK package (like flutter)
---@param name string
---@return boolean
local function is_sdk_package(name)
    return SDK_PACKAGES[name] or false
end

--- Get manifest data for pubspec manager (cached)
---@return PubspecManifest|nil
local function get_manifest()
    if manifest_cache then
        return manifest_cache
    end

    local ok, manifest_data = pcall(init.get_manifest, "pubspec")
    if not ok or not manifest_data then
        debug(string.format("Failed to load manifest: %s", tostring(manifest_data)), vim.log.levels.ERROR)
        return nil
    end

    -- Validate manifest structure
    if not common.validate_manifest(manifest_data, { "dependency_types" }) then
        debug("Invalid manifest structure", vim.log.levels.ERROR)
        return nil
    end

    ---@cast manifest_data PubspecManifest
    manifest_cache = manifest_data
    return manifest_data
end

--- Try to detect and build a PubspecDeclaredPackage using manifest dependency type definitions
---@param name string Package name
---@param version any Raw version from pubspec
---@param dep_types table<string, DependencyTypeDef>
---@return PubspecDeclaredPackage|nil
local function detect_dependency_type(name, version, dep_types)
    local type_name, extracted = common.detect_dependency_type(version, dep_types)
    if type_name then
        ---@type PubspecDeclaredPackage
        local dep = {
            name = name,
            type = type_name,
            declared = nil,
            raw = version,
        }
        -- Copy extracted fields
        if extracted then
            for k, v in pairs(extracted) do
                dep[k] = v
            end
        end
        return dep
    end
    return nil
end

--- Process a single dependency from raw data
---@param name string Package name
---@param version any Raw version from pubspec
---@param dep_types table<string, DependencyTypeDef>
---@return PubspecDeclaredPackage
local function process_dependency(name, version, dep_types)
    -- Handle SDK packages specially
    if is_sdk_package(name) then
        return {
            name = name,
            type = "sdk",
            declared = nil,
            raw = version,
            sdk = name,
        }
    end

    local detected = detect_dependency_type(name, version, dep_types)
    if detected then
        return detected
    end

    -- Fallback: no detector matched, assume registry type
    return {
        name = name,
        type = "registry",
        declared = tostring(version),
        raw = version,
    }
end

--- Get all declared packages from pubspec.yaml
---@return table<string, PubspecDeclaredPackage>
function M.get_data()
    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No manifest data, returning empty dependencies", vim.log.levels.ERROR)
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

--- Clear manifest cache
function M.clear_cache()
    manifest_cache = nil
    debug("Pubspec declared cache cleared", vim.log.levels.DEBUG)
end

return M
