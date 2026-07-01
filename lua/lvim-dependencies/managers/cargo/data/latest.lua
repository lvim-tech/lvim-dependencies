-- lvim-dependencies.managers.cargo.data.latest: fetches the latest version + crate metadata
-- from crates.io. Honours the include_prerelease preference (max_version vs max_stable_version,
-- with a versions-array fallback), extracts a fixed set of metadata fields, and dedups
-- concurrent requests for the same crate via an in-flight waiter list. The result CACHE is
-- owned by core.hub.latest (required inline to break the hub↔data circular dependency).
---@module "lvim-dependencies.managers.cargo.data.latest"

local utils = require("lvim-dependencies.utils")
local http = require("lvim-dependencies.utils.http")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class CargoLatest
local M = {}

--- In-flight request dedup: crate name → callbacks awaiting the same fetch.
---@type table<string, fun(err: string|nil, result: table|nil)[]>
local in_flight = {}

--- Metadata fields lifted verbatim from the crates.io `crate` object.
---@type string[]
local METADATA_FIELDS = {
    "description",
    "homepage",
    "repository",
    "documentation",
    "license",
    "categories",
    "keywords",
}

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

local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

local function include_prerelease()
    return config.cargo and config.cargo.version and config.cargo.version.include_prerelease
end

--- Check if a version string is a prerelease (semver: contains "-" after patch)
---@param ver string
---@return boolean
local function is_prerelease(ver)
    return ver:match("%d+%.%d+%.%d+%-") ~= nil
end

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

local function extract_metadata(crate)
    local metadata = {}
    for _, field in ipairs(METADATA_FIELDS) do
        if is_valid_string(crate[field]) then
            metadata[field] = crate[field]
        elseif field == "categories" and type(crate.categories) == "table" then
            local cats = {}
            for _, cat in ipairs(crate.categories) do
                if is_valid_string(cat) then
                    cats[#cats + 1] = cat
                elseif type(cat) == "table" and is_valid_string(cat.category) then
                    cats[#cats + 1] = cat.category
                end
            end
            if #cats > 0 then
                metadata.categories = cats
            end
        elseif field == "keywords" and type(crate.keywords) == "table" then
            local kws = {}
            for _, kw in ipairs(crate.keywords) do
                if is_valid_string(kw) then
                    kws[#kws + 1] = kw
                elseif type(kw) == "table" and is_valid_string(kw.keyword) then
                    kws[#kws + 1] = kw.keyword
                end
            end
            if #kws > 0 then
                metadata.keywords = kws
            end
        end
    end
    return metadata
end

--- Walk versions array (crates.io: newest-first) and return the first acceptable version.
--- With include_prerelease=true: returns the absolute newest (first entry).
--- With include_prerelease=false: returns the first non-prerelease entry.
--- Accepts arbitrary decoded-JSON input (from traverse_path); validated internally.
---@param arr any
---@return string|nil
local function version_from_array(arr)
    if type(arr) ~= "table" or #arr == 0 then
        return nil
    end
    for _, entry in ipairs(arr) do
        local ver = nil
        if is_valid_string(entry) then
            ver = entry
        elseif type(entry) == "table" then
            ver = entry.num or entry.version
        end
        if ver then
            if include_prerelease() or not is_prerelease(ver) then
                return ver
            end
        end
    end
    return nil
end

local function extract_default(data)
    local version, metadata = nil, nil

    if data.crate then
        if include_prerelease() then
            -- max_version = absolute newest including prerelease
            version = data.crate.max_version
        else
            -- max_stable_version = newest non-prerelease (crates.io field, added 2020)
            -- Fall back to max_version only if it happens to be stable
            local stable = data.crate.max_stable_version or data.crate.max_version
            if stable and not is_prerelease(stable) then
                version = stable
            end
        end
        metadata = extract_metadata(data.crate)
    end

    -- Fallback: walk versions array
    if not version and data.versions then
        version = version_from_array(data.versions)
    end
    if not version and data.crate and data.crate.versions then
        version = version_from_array(data.crate.versions)
    end

    return version, metadata
end

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
    local metadata = data.crate and extract_metadata(data.crate) or nil
    return version, metadata
end

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

local function build_request(package_name, manifest_data)
    local registry = manifest_data.registry or {}
    local base_url = config.cargo.api.registry_base
        or registry.base_url
        or manifest_data.default_registry
        or "https://crates.io/api/v1"
    local endpoint = config.cargo.api.endpoint or registry.package_endpoint or "/crates/%s"
    local timeout = config.cargo.api.timeout or (manifest_data.api and manifest_data.api.timeout) or 10
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
        callback("No manifest data for cargo", nil)
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
    local data = hub.get_full_data("cargo")
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
    local cached = hub.get_data("cargo")
    local result = {}
    for package_name in pairs(declared_packages) do
        local entry = cached[package_name]
        result[package_name] = entry and entry.version or nil
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.latest")
    hub.clear_cache("cargo")
    in_flight = {}
    debug("Latest cache cleared (via hub)", vim.log.levels.INFO)
end

return M
