-- lvim-dependencies/managers/go/data/latest.lua
-- Latest version fetcher from proxy.golang.org

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local http = require("lvim-dependencies.utils.http")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class GoLatest
local M = {}

---@type table<string, function[]>
local in_flight = {}

-- ============================================================================
-- Helpers
-- ============================================================================

local function get_manifest()
    local m = init.get_manifest("go")
    ---@cast m GoManifest|nil
    return m
end

local function include_prerelease()
    return config.go and config.go.version and config.go.version.include_prerelease
end

--- Encode Go module path for proxy URL (uppercase → !lowercase)
---@param module_path string
---@return string
local function encode_path(module_path)
    return (module_path:gsub("[A-Z]", function(c)
        return "!" .. c:lower()
    end))
end

--- Parse the list endpoint response (newline-separated versions)
---@param output string
---@return string[]
local function parse_version_list(output)
    local versions = {}
    if not output then
        return versions
    end
    for line in output:gmatch("[^\n]+") do
        local ver = line:match("^%s*(v[%w%.%-%+]+)%s*$")
        if ver then
            versions[#versions + 1] = ver
        end
    end
    return versions
end

--- Build metadata for a Go module from its path.
--- proxy.golang.org does not return homepage/description metadata, so we
--- derive what we can from the module path itself:
---   - repository: constructed for GitHub / GitLab / Bitbucket / golang.org / gopkg.in
---   - documentation: always https://pkg.go.dev/{module_path}
---@param module_path string
---@return table
local function build_metadata(module_path)
    local md = {}

    -- pkg.go.dev has documentation for every public Go module
    md.documentation = "https://pkg.go.dev/" .. module_path

    -- Derive repository URL from well-known hosting prefixes
    local repo_url
    local host = module_path:match("^([^/]+)")
    if host == "github.com" or host == "gitlab.com" or host == "bitbucket.org" then
        -- Take first three path segments: host/org/repo
        repo_url = "https://"
            .. table.concat({
                module_path:match("^([^/]+/[^/]+/[^/]+)") and module_path:match("^([^/]+/[^/]+/[^/]+)") or module_path,
            }, "")
    elseif host == "golang.org" or host == "google.golang.org" or host == "gopkg.in" then
        repo_url = "https://" .. module_path
    end

    if repo_url then
        md.repository = repo_url
    end

    return md
end

--- Parse the @latest endpoint response; also extract Origin.URL if present.
---@param output string
---@param module_path string
---@return string|nil version, table metadata
local function parse_latest_response(output, module_path)
    if not output then
        return nil, build_metadata(module_path)
    end
    local ok, data = pcall(vim.json.decode, output)
    if not ok or type(data) ~= "table" then
        return nil, build_metadata(module_path)
    end
    local ver = data.Version
    if not (ver and type(ver) == "string" and ver:match("^v")) then
        return nil, build_metadata(module_path)
    end
    -- Extract repository URL from Origin if proxy provides it
    local md = build_metadata(module_path)
    if type(data.Origin) == "table" and type(data.Origin.URL) == "string" and data.Origin.URL ~= "" then
        md.repository = data.Origin.URL
    end
    return ver, md
end

local function build_list_url(module_path, manifest_data)
    local registry = manifest_data and manifest_data.registry or {}
    local base = (config.go and config.go.api and config.go.api.proxy_base)
        or registry.base_url
        or "https://proxy.golang.org"

    local encoded = encode_path(module_path)
    local ep = registry.list_endpoint or "/%s/@v/list"
    return base .. string.format(ep, encoded)
end

local function build_latest_url(module_path, manifest_data)
    local registry = manifest_data and manifest_data.registry or {}
    local base = (config.go and config.go.api and config.go.api.proxy_base)
        or registry.base_url
        or "https://proxy.golang.org"

    local encoded = encode_path(module_path)
    local ep = registry.latest_endpoint or "/%s/@latest"
    return base .. string.format(ep, encoded)
end

local function get_timeout(manifest_data)
    return (config.go and config.go.api and config.go.api.timeout)
        or (manifest_data and manifest_data.api and manifest_data.api.timeout)
        or 10
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

local function fetch_from_proxy(package_name, manifest_data)
    local cmp = require("lvim-dependencies.managers.go.compare_versions")
    local timeout = get_timeout(manifest_data)
    local inc_pre = include_prerelease()

    -- Fetch the version list
    local list_url = build_list_url(package_name, manifest_data)
    debug(string.format("go: fetching list for %s from %s", package_name, list_url), vim.log.levels.DEBUG)

    http.get(list_url, function(output, err)
        if err or not output or output == "" then
            -- Fallback: try @latest
            local latest_url = build_latest_url(package_name, manifest_data)
            debug(string.format("go: list failed, trying @latest for %s", package_name), vim.log.levels.DEBUG)
            http.get(latest_url, function(out2, err2)
                if err2 or not out2 then
                    debug(string.format("go: both endpoints failed for %s", package_name), vim.log.levels.ERROR)
                    notify_waiters(package_name, err2 or "fetch failed", nil)
                    return
                end
                local version, meta = parse_latest_response(out2, package_name)
                if not version then
                    notify_waiters(package_name, "Failed to parse version", nil)
                    return
                end
                debug(
                    string.format("go: got version %s for %s (via @latest)", version, package_name),
                    vim.log.levels.INFO
                )
                notify_waiters(package_name, nil, { version = version, metadata = meta })
            end, timeout)
            return
        end

        -- Parse version list and pick latest
        local versions = parse_version_list(output)
        if #versions == 0 then
            notify_waiters(package_name, "No versions found", nil)
            return
        end

        -- Filter prereleases unless requested
        if not inc_pre then
            local stable = {}
            for _, v in ipairs(versions) do
                if not cmp.is_prerelease(v) then
                    stable[#stable + 1] = v
                end
            end
            if #stable > 0 then
                versions = stable
            end
        end

        local best = cmp.latest(versions)
        if not best then
            notify_waiters(package_name, "Failed to determine latest", nil)
            return
        end

        debug(string.format("go: got version %s for %s", best, package_name), vim.log.levels.INFO)
        notify_waiters(package_name, nil, { version = best, metadata = build_metadata(package_name) })
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
        callback("No go manifest data", nil)
        return
    end

    if in_flight[package_name] then
        table.insert(in_flight[package_name], callback)
        return
    end

    in_flight[package_name] = { callback }
    fetch_from_proxy(package_name, manifest_data)
end

---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end
    local hub = require("lvim-dependencies.core.hub.latest")
    local cached = hub.get_data("go")
    local result = {}
    for name in pairs(declared_packages) do
        local entry = cached[name]
        result[name] = entry and entry.version or nil
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.latest")
    hub.clear_cache("go")
    in_flight = {}
    debug("go latest cache cleared (via hub)", vim.log.levels.INFO)
end

return M
