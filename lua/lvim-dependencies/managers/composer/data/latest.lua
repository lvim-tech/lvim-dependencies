-- lvim-dependencies.managers.composer.data.latest: fetches the newest available version (plus
-- metadata) for a package from packagist.org. Packagist returns every version keyed by string,
-- so the "best" is picked by numeric comparison, honouring the include_prerelease setting and
-- preferring a stable release over a prerelease with the same numeric base. Concurrent requests
-- for the same package are coalesced via the in_flight table so the registry is hit once.
--
---@module "lvim-dependencies.managers.composer.data.latest"

local utils = require("lvim-dependencies.utils")
local http = require("lvim-dependencies.utils.http")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")
local compare_versions = require("lvim-dependencies.managers.composer.compare_versions")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local manifest = require("lvim-dependencies.managers.composer.manifest")

local debug = utils.debug

---@class ComposerLatest
local M = {}

---@type table<string, function[]>
local in_flight = {}

local METADATA_FIELDS = { "description", "homepage", "repository", "license", "keywords" }

-- ============================================================================
-- Helpers
-- ============================================================================

---@return ComposerManifest|nil
local function get_manifest()
    local m = init.get_manifest("composer")
    ---@cast m ComposerManifest|nil
    return m
end

local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

local function include_prerelease()
    return config.composer and config.composer.version and config.composer.version.include_prerelease
end

--- Composer prerelease: versions containing "alpha", "beta", "RC", "dev", or "-patch"
--- Also: versions starting with "dev-" (branch aliases)
---@param ver string
---@return boolean
local function is_prerelease(ver)
    if ver:match("^dev%-") then
        return true
    end
    local lower = ver:lower()
    return lower:match("alpha") ~= nil
        or lower:match("beta") ~= nil
        or lower:match("%-rc") ~= nil
        or lower:match("%.rc") ~= nil
        or lower:match("rc%d") ~= nil
        or lower:match("%-dev") ~= nil
        or lower:match("%.dev") ~= nil
        or lower:match("%-patch") ~= nil
        -- semver style: 1.0.0-alpha.1
        or ver:match("%d+%.%d+%.%d+%-") ~= nil
end

local function extract_metadata(pkg_data)
    local metadata = {}
    for _, field in ipairs(METADATA_FIELDS) do
        local val = pkg_data[field]
        if is_valid_string(val) then
            metadata[field] = val
        elseif field == "keywords" and type(val) == "table" then
            local kws = {}
            for _, kw in ipairs(val) do
                if is_valid_string(kw) then
                    kws[#kws + 1] = kw
                end
            end
            if #kws > 0 then
                metadata.keywords = kws
            end
        end
    end
    return metadata
end

--- Parse packagist.org response.
--- Response structure:
---   {"package": {"name": "vendor/pkg", "versions": {"v1.2.3": {...}, "dev-main": {...}}}}
---
---@param output string?
---@return string|nil version
---@return table|nil metadata
local function parse_response(output)
    if not output then
        return nil, nil
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok or type(data) ~= "table" then
        return nil, nil
    end

    local pkg = data.package
    if not pkg then
        return nil, nil
    end

    local versions_map = pkg.versions
    if type(versions_map) ~= "table" then
        return nil, nil
    end

    local best = nil
    local best_meta = nil

    for ver_str, ver_data in pairs(versions_map) do
        -- Strip "v" prefix: "v1.2.3" → "1.2.3"
        local ver = ver_str:gsub("^v", "")

        -- Must start with digit (skip "dev-main", "dev-master" etc after strip)
        if not ver:match("^%d") then
            goto continue
        end

        local pre = is_prerelease(ver)
        if not include_prerelease() and pre then
            goto continue
        end

        if not best then
            best = ver
            best_meta = ver_data
        else
            local cmp_result = compare_versions.compare_numeric(ver, best)
            if cmp_result == 1 then
                best = ver
                best_meta = ver_data
            elseif cmp_result == 0 and include_prerelease() then
                -- Same numeric base: prefer stable over prerelease
                if not pre and is_prerelease(best) then
                    best = ver
                    best_meta = ver_data
                end
            end
        end

        ::continue::
    end

    if not is_valid_string(best) then
        return nil, nil
    end

    local metadata = best_meta and extract_metadata(best_meta) or {}
    -- Also extract top-level package metadata
    if pkg.description and not metadata.description then
        metadata.description = pkg.description
    end

    return best, metadata
end

local function build_url(package_name, manifest_data)
    local registry = manifest_data.registry or {}
    local base = (config.composer and config.composer.api and config.composer.api.registry_base)
        or registry.base_url
        or "https://packagist.org"

    local timeout = (config.composer and config.composer.api and config.composer.api.timeout)
        or (manifest_data.api and manifest_data.api.timeout)
        or 10

    if config.composer and config.composer.api and config.composer.api.endpoint then
        return base .. string.format(config.composer.api.endpoint, package_name), timeout
    end

    local endpoint = registry.package_endpoint or "/packages/%s.json"
    return base .. string.format(endpoint, package_name), timeout
end

local function notify_waiters(package_name, err, result)
    local waiting = in_flight[package_name] or {}
    in_flight[package_name] = nil
    for _, cb in ipairs(waiting) do
        vim.schedule(function()
            cb(err, result)
        end)
    end
end

local function fetch_from_registry(package_name, manifest_data)
    local url, timeout = build_url(package_name, manifest_data)
    debug(
        string.format("composer: fetching %s from %s (timeout: %ds)", package_name, url, timeout),
        vim.log.levels.DEBUG
    )

    http.get(url, function(output, err)
        if err then
            debug(string.format("composer: HTTP error for %s: %s", package_name, err), vim.log.levels.ERROR)
            notify_waiters(package_name, err, nil)
            return
        end

        local version, metadata = parse_response(output)
        if not version then
            debug(string.format("composer: failed to parse version for %s", package_name), vim.log.levels.WARN)
            notify_waiters(package_name, "Failed to parse version from registry", nil)
            return
        end

        debug(string.format("composer: got version %s for %s", version, package_name), vim.log.levels.INFO)
        notify_waiters(package_name, nil, { version = version, metadata = metadata or {} })
    end, timeout)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Platform packages are not on packagist — skip registry fetch entirely.
---@param package_name string
---@param callback fun(err: string|nil, result: {version: string, metadata: table}|nil)
function M.get_package_latest(package_name, callback)
    -- Platform requirements have no registry entry — return nil silently
    if not manifest.is_package_actionable(package_name) then
        callback(nil, nil)
        return
    end

    local manifest_data = get_manifest()
    if not manifest_data then
        callback("No manifest data for composer", nil)
        return
    end

    if in_flight[package_name] then
        table.insert(in_flight[package_name], callback)
        return
    end

    in_flight[package_name] = { callback }
    fetch_from_registry(package_name, manifest_data)
end

---@param package_name string
---@return table|nil
function M.get_metadata(package_name)
    local data = hub_latest.get_full_data("composer")
    local entry = data and data[package_name]
    return entry and entry.metadata or nil
end

---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end
    local cached = hub_latest.get_data("composer")
    local result = {}
    for name in pairs(declared_packages) do
        local entry = cached[name]
        result[name] = entry and entry.version or nil
    end
    return result
end

function M.clear_cache()
    hub_latest.clear_cache("composer")
    in_flight = {}
    debug("composer: latest cache cleared", vim.log.levels.INFO)
end

return M
