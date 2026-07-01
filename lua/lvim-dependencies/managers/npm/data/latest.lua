-- lvim-dependencies.managers.npm.data.latest: fetches the latest published version + metadata
-- from the npm registry. To avoid pulling the multi-MB full package document it hits the cheap
-- endpoints: /<pkg>/latest for stable, or /-/package/<pkg>/dist-tags when prereleases are
-- included (then picks the numerically-newest tag). Concurrent requests for the same package are
-- coalesced through an in-flight table so N callers share one HTTP round-trip.
--
---@module "lvim-dependencies.managers.npm.data.latest"

local utils = require("lvim-dependencies.utils")
local http = require("lvim-dependencies.utils.http")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class NpmLatest
local M = {}

-- package_name → list of pending callbacks waiting on one in-flight registry request.
---@type table<string, function[]>
local in_flight = {}

---@type string[]
local METADATA_FIELDS = { "description", "homepage", "repository", "license", "keywords" }

-- ============================================================================
-- Helpers
-- ============================================================================

---@return NpmManifest|nil
local function get_manifest()
    local m = init.get_manifest("npm")
    ---@cast m NpmManifest|nil
    return m
end

--- True when `val` is a non-empty string (guards against vim.NIL from decoded JSON).
---@param val any
---@return boolean
local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

--- Normalize the registry's metadata fields (repository URLs de-VCS-prefixed, keywords listed).
---@param data table  decoded registry response
---@return table
local function extract_metadata(data)
    local metadata = {}
    for _, field in ipairs(METADATA_FIELDS) do
        local value = data[field]
        if is_valid_string(value) then
            if field == "repository" then
                value = value:gsub("^git%+", ""):gsub("^ssh://git@", "https://"):gsub("%.git$", "")
            end
            metadata[field] = value
        elseif field == "repository" and type(value) == "table" then
            local url = value.url
            if type(url) == "string" then
                -- Strip VCS prefixes npm registry adds: "git+https://..." → "https://..."
                url = url:gsub("^git%+", "")
                -- Convert git+ssh: "git+ssh://git@github.com/u/r.git" → "https://github.com/u/r"
                url = url:gsub("^ssh://git@", "https://")
                url = url:gsub("%.git$", "")
            end
            metadata.repository = url or nil
        elseif field == "keywords" and type(value) == "table" then
            local kws = {}
            for _, kw in ipairs(value) do
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

--- Whether prerelease versions should be considered for "latest".
---@return boolean|nil
local function include_prerelease()
    return config.npm and config.npm.version and config.npm.version.include_prerelease
end

--- Check if a version string is a prerelease (semver: contains "-" after patch)
---@param ver string
---@return boolean
local function is_prerelease(ver)
    return ver:match("%d+%.%d+%.%d+%-") ~= nil
end

--- Parse response from registry.
---
--- include_prerelease=false → endpoint /%s/latest → {version, ...}
---   data.version is the stable dist-tag latest.
---
--- include_prerelease=true  → endpoint /%s → {dist-tags, versions, ...}
---   We use dist-tags first (lightweight), then fall back to versions keys.
---   NOTE: We do NOT fetch the full /%s payload — it can be 10MB+.
---   Instead build_url still uses /%s/latest but we pick from dist-tags
---   which is included in the /latest response too.
---   For prerelease we use /%s/latest AND check dist-tags.next / dist-tags.beta.
---@param output string|nil  raw HTTP body (nil on transport failure)
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

    local version = nil
    local metadata = nil

    if include_prerelease() then
        -- Response from /-/package/%s/dist-tags:
        -- {"latest":"7.18.6","esm":"7.21.4-esm.4"}
        -- All values are valid dist-tag versions — pick the newest by numeric comparison.
        -- compare_numeric strips prerelease suffix: 7.21.4-esm.4 → 7.21.4 > 7.18.6 ✓
        local cmp = require("lvim-dependencies.managers.npm.compare_versions")

        for _, tagged_ver in pairs(data) do
            if
                is_valid_string(tagged_ver)
                and tagged_ver:match("^%d")
                and tagged_ver:match("%.")
                and not tagged_ver:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+$")
            then
                if not version or cmp.compare_numeric(tagged_ver, version) > 0 then
                    version = tagged_ver
                end
            end
        end

        metadata = {}
    else
        -- Response from /%s/latest:
        -- {"version":"7.18.6","description":"...",...}
        local ver = data.version
        if is_valid_string(ver) and not is_prerelease(ver) then
            version = ver
        elseif type(data["dist-tags"]) == "table" then
            local cmp = require("lvim-dependencies.managers.npm.compare_versions")
            for _, tagged_ver in pairs(data["dist-tags"]) do
                if is_valid_string(tagged_ver) and not is_prerelease(tagged_ver) then
                    if not version or cmp.compare(tagged_ver, version) == 1 then
                        version = tagged_ver
                    end
                end
            end
        end
        metadata = extract_metadata(data)
    end

    if not is_valid_string(version) then
        return nil, nil
    end
    return version, metadata
end

--- Encode package name for use in npm registry URLs.
--- Scoped packages like "@babel/core" must have "/" encoded as "%2F":
---   @babel/core  →  @babel%2Fcore
--- The "@" itself does NOT need encoding in npm registry URLs.
---@param pkg string
---@return string
local function encode_pkg(pkg)
    if pkg:match("^@") then
        -- Replace the "/" between scope and name with %2F
        -- Wrap in () to discard the second return value (replacement count) from gsub
        return (pkg:gsub("/", "%%2F", 1))
    end
    return pkg
end

--- Compose the registry URL + timeout for a package, honouring config overrides and the
--- stable-vs-prerelease endpoint choice.
---@param package_name string
---@param manifest_data NpmManifest
---@return string url
---@return integer timeout
local function build_url(package_name, manifest_data)
    local registry = manifest_data.registry or {}
    local base = (config.npm and config.npm.api and config.npm.api.registry_base)
        or registry.base_url
        or "https://registry.npmjs.org"

    local timeout = (config.npm and config.npm.api and config.npm.api.timeout)
        or (manifest_data.api and manifest_data.api.timeout)
        or 10

    local encoded = encode_pkg(package_name)

    -- Explicit user config override always wins
    if config.npm and config.npm.api and config.npm.api.endpoint then
        return base .. string.format(config.npm.api.endpoint, encoded), timeout
    end

    -- include_prerelease uses the dedicated dist-tags endpoint
    -- (must be checked before manifest.registry.package_endpoint which is always "/%s/latest")
    if include_prerelease() then
        local ep = registry.package_endpoint_prerelease or "/-/package/%s/dist-tags"
        return base .. string.format(ep, encoded), timeout
    end

    -- Stable latest: use manifest endpoint or fallback
    local ep = registry.package_endpoint or "/%s/latest"
    return base .. string.format(ep, encoded), timeout
end

--- Resolve every coalesced callback for a package with the shared result.
---@param package_name string
---@param err string|nil
---@param result {version: string, metadata: table}|nil
local function notify_waiters(package_name, err, result)
    local waiting = in_flight[package_name] or {}
    in_flight[package_name] = nil
    for _, cb in ipairs(waiting) do
        vim.schedule(function()
            cb(err, result)
        end)
    end
end

--- Perform the HTTP request and dispatch the parsed result to all waiters.
---@param package_name string
---@param manifest_data NpmManifest
local function fetch_from_registry(package_name, manifest_data)
    local url, timeout = build_url(package_name, manifest_data)
    debug(string.format("npm: fetching %s from %s (timeout: %ds)", package_name, url, timeout), vim.log.levels.DEBUG)

    http.get(url, function(output, err)
        if err then
            debug(string.format("npm: HTTP error for %s: %s", package_name, err), vim.log.levels.ERROR)
            notify_waiters(package_name, err, nil)
            return
        end

        local version, metadata = parse_response(output)
        if not version then
            debug(string.format("npm: failed to parse version for %s", package_name), vim.log.levels.WARN)
            notify_waiters(package_name, "Failed to parse version from registry", nil)
            return
        end

        debug(string.format("npm: got version %s for %s", version, package_name), vim.log.levels.INFO)
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
        callback("No npm manifest data", nil)
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
    local hub = require("lvim-dependencies.core.hub.latest")
    local data = hub.get_data("npm")
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
    local cached = hub.get_data("npm")
    local result = {}
    for name in pairs(declared_packages) do
        local entry = cached[name]
        result[name] = entry and entry.version or nil
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.latest")
    hub.clear_cache("npm")
    in_flight = {}
    debug("npm latest cache cleared (via hub)", vim.log.levels.INFO)
end

return M
