-- lvim-dependencies/managers/pubspec/data/latest.lua
-- Latest version manager for pub.dev using manifest configuration

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local http = require("lvim-dependencies.utils.http")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class PubspecLatest
local M = {}

---@type table<string, function[]>
local in_flight = {}

local METADATA_FIELDS = { "description", "homepage", "repository", "documentation", "license" }

-- ============================================================================
-- Helpers
-- ============================================================================

---@return ManagerManifest|nil
local function get_manifest()
    return init.get_manifest("pubspec")
end

---@param val any
---@return boolean
local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

local function include_prerelease()
    return config.pubspec and config.pubspec.version and config.pubspec.version.include_prerelease
end

--- Check if a version string is a prerelease (semver or pub.dev style)
--- Pub.dev prerelease: "1.0.0-alpha", "2.0.0-beta.1", "1.0.0-rc.1"
---@param ver string
---@return boolean
local function is_prerelease(ver)
    return ver:match("%d+%.%d+%.%d+%-") ~= nil
end

---@param root table
---@param path string[]
---@return any|nil
local function traverse_path(root, path)
    local current = root
    for _, key in ipairs(path) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[key]
    end
    return current
end

---@param pubspec table
---@return table
local function extract_metadata(pubspec)
    local metadata = {}
    for _, field in ipairs(METADATA_FIELDS) do
        if is_valid_string(pubspec[field]) then
            metadata[field] = pubspec[field]
        end
    end
    return metadata
end

--- Extract version from versions array.
--- Pub.dev versions array is oldest-first — we walk from the end.
--- With include_prerelease=true:  returns the last (newest) entry.
--- With include_prerelease=false: returns the last non-prerelease entry.
---@param versions_array table
---@return string|nil
local function version_from_array(versions_array)
    if type(versions_array) ~= "table" or #versions_array == 0 then
        return nil
    end
    -- Walk from newest (end) to oldest (start)
    for i = #versions_array, 1, -1 do
        local entry = versions_array[i]
        local ver = nil
        if is_valid_string(entry) then
            ver = entry
        elseif type(entry) == "table" and is_valid_string(entry.version) then
            ver = entry.version
        end
        if ver then
            if include_prerelease() or not is_prerelease(ver) then
                return ver
            end
        end
    end
    return nil
end

---@param data table
---@return string|nil, table|nil
local function extract_default(data)
    local version = nil
    local metadata = nil

    if include_prerelease() then
        -- Walk all versions newest-first to get absolute latest (may be prerelease)
        if data.versions then
            version = version_from_array(data.versions)
        end
        -- Fallback: data.latest (stable latest from pub.dev)
        if not version and data.latest and is_valid_string(data.latest.version) then
            version = data.latest.version
        end
    else
        -- Stable only: pub.dev data.latest is always the latest stable
        if data.latest and is_valid_string(data.latest.version) then
            version = data.latest.version
        end
        -- Guard: if latest happens to be prerelease, walk versions
        if version and is_prerelease(version) then
            version = nil
            if data.versions then
                version = version_from_array(data.versions)
            end
        end
    end

    if data.latest and data.latest.pubspec then
        metadata = extract_metadata(data.latest.pubspec)
    end

    return version, metadata
end

---@param data table
---@param response_config RegistryResponseConfig
---@return string|nil, table|nil
local function extract_with_paths(data, response_config)
    local version = nil

    if response_config.version_path and #response_config.version_path > 0 then
        local val = traverse_path(data, response_config.version_path)
        if is_valid_string(val) then
            version = val
        end
    end

    if not version and response_config.versions_path and #response_config.versions_path > 0 then
        version = version_from_array(traverse_path(data, response_config.versions_path))
    end

    local metadata = nil
    if data.latest and data.latest.pubspec then
        metadata = extract_metadata(data.latest.pubspec)
    end

    return version, metadata
end

---@param output string
---@param manifest_data ManagerManifest
---@return string|nil, table|nil
local function parse_response(output, manifest_data)
    if not output then
        return nil, nil
    end

    local ok, data = pcall(vim.json.decode, output)
    if not ok or not data then
        return nil, nil
    end

    if manifest_data.registry and manifest_data.registry.response then
        return extract_with_paths(data, manifest_data.registry.response)
    end

    return extract_default(data)
end

---@param package_name string
---@param manifest_data ManagerManifest
---@return string, integer
local function build_request(package_name, manifest_data)
    local registry = manifest_data.registry or {}

    local base_url = config.pubspec.api.registry_base
        or registry.base_url
        or manifest_data.default_registry
        or "https://pub.dev/api"

    local endpoint = config.pubspec.api.endpoint or registry.package_endpoint or "/packages/%s"

    local timeout = config.pubspec.api.timeout or (manifest_data.api and manifest_data.api.timeout) or 10

    return base_url .. string.format(endpoint, package_name), timeout
end

---@param package_name string
---@param err string|nil
---@param result any
local function notify_waiters(package_name, err, result)
    local waiting = in_flight[package_name] or {}
    in_flight[package_name] = nil
    debug(string.format("Calling %d waiters for %s", #waiting, package_name), vim.log.levels.DEBUG)
    for _, cb in ipairs(waiting) do
        vim.schedule(function()
            cb(err, result)
        end)
    end
end

---@param package_name string
---@param manifest_data ManagerManifest
local function fetch_from_registry(package_name, manifest_data)
    local url, timeout = build_request(package_name, manifest_data)

    debug(string.format("Fetching %s from %s (timeout: %ds)", package_name, url, timeout), vim.log.levels.DEBUG)

    http.get(url, function(output, err)
        if err then
            debug(string.format("HTTP error for %s: %s", package_name, err), vim.log.levels.ERROR)
            notify_waiters(package_name, err, nil)
            return
        end

        local version, metadata = parse_response(output, manifest_data)

        if not version then
            debug(string.format("Failed to parse version for %s", package_name), vim.log.levels.WARN)
            notify_waiters(package_name, "Failed to parse version from response", nil)
            return
        end

        debug(string.format("Got version %s for %s", version, package_name), vim.log.levels.INFO)
        notify_waiters(package_name, nil, { version = version, metadata = metadata or {} })
    end, timeout)
end

-- ============================================================================
-- Public API
-- ============================================================================

---@param package_name string
---@param callback fun(err: string|nil, result: {version: string, metadata: table}|nil)
function M.get_package_latest(package_name, callback)
    local manifest_data = get_manifest()
    if not manifest_data then
        callback("No manifest data for pubspec", nil)
        return
    end

    -- SDK fast path
    local sdk_packages = manifest_data.sdk_packages or {}
    if sdk_packages[package_name] then
        debug(string.format("SDK package: %s", package_name), vim.log.levels.INFO)
        callback(nil, { version = "sdk", metadata = {} })
        return
    end

    if in_flight[package_name] then
        debug(string.format("Request in flight for %s, adding waiter", package_name), vim.log.levels.DEBUG)
        table.insert(in_flight[package_name], callback)
        return
    end

    in_flight[package_name] = { callback }
    fetch_from_registry(package_name, manifest_data)
end

---@param package_name string
---@return table|nil
function M.get_metadata(package_name)
    local hub = require("lvim-dependencies.core.hub.latest")
    local data = hub.get_full_data("pubspec")
    local entry = data and data[package_name]
    return entry and entry.metadata or nil
end

---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end

    local hub = require("lvim-dependencies.core.hub.latest")
    local cached = hub.get_data("pubspec")
    local result = {}

    for package_name in pairs(declared_packages) do
        local entry = cached[package_name]
        result[package_name] = entry and entry.version or nil
    end

    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.latest")
    hub.clear_cache("pubspec")
    in_flight = {}
    debug("Latest cache cleared (via hub)", vim.log.levels.INFO)
end

return M
