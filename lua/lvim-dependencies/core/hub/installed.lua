-- lvim-dependencies.core.hub.installed: callback-based access to a manager's INSTALLED
-- versions (read from lock files, disk-bound). Serves from core.cache on hit; on miss it
-- defers to the manager's data.installed module, then stores the result with a TTL so a
-- lock file isn't re-parsed on every lookup. Every hit/miss/error is recorded to metrics.
--
---@module "lvim-dependencies.core.hub.installed"

local cache = require("lvim-dependencies.core.cache")
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")
local config = require("lvim-dependencies.config")

local debug = utils.debug
local now = os.time

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED

---@class InstalledHub
local M = {}

---@type table<string, InstalledModule>
local manager_modules = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Load a manager's data.installed module, caching the result.
---@param manager_type string
---@return InstalledModule|nil
local function load_installed_module(manager_type)
    if manager_modules[manager_type] then
        return manager_modules[manager_type]
    end

    metrics.start_measure("module:installed:" .. manager_type)

    local module_path = string.format("lvim-dependencies.managers.%s.data.installed", manager_type)
    local ok, mod = pcall(require, module_path)

    local duration = metrics.end_measure()
    metrics.record_operation("module_load", duration)

    if not ok or not mod then
        debug(string.format("Failed to load installed module for %s", manager_type), vim.log.levels.ERROR)
        metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
        return nil
    end

    manager_modules[manager_type] = mod
    return mod
end

--- Normalize a cached entry (table or bare string) to a version string.
---@param cached any
---@return string|nil
local function extract_version(cached)
    if type(cached) == "table" then
        return cached.version
    end
    return cached
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get the installed version of a package (cache-first, TTL'd on miss).
---@param manager_type string
---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
function M.get_package_installed(manager_type, package_name, callback)
    local entry = cache.ensure(manager_type, CACHE_TYPE_INSTALLED)
    local cached = entry[const.CACHE_FIELDS.DATA][package_name]

    if cached ~= nil then
        local version = extract_version(cached)
        debug(
            string.format("Cache HIT for %s/%s: %s", manager_type, package_name, version or "nil"),
            vim.log.levels.INFO
        )

        -- Single source of truth for cache hit recording
        metrics.record_cache_event(manager_type, true)
        callback(nil, version)
        return
    end

    debug(string.format("Cache MISS for %s/%s", manager_type, package_name), vim.log.levels.INFO)
    metrics.record_cache_event(manager_type, false)

    local installed_mod = load_installed_module(manager_type)
    if not installed_mod or not installed_mod.get_package_installed then
        local err = string.format("No valid installed module for %s", manager_type)
        debug(err, vim.log.levels.ERROR)
        metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
        callback(err, nil)
        return
    end

    metrics.start_measure("installed:lookup:" .. package_name)

    installed_mod.get_package_installed(package_name, function(err, version)
        local duration = metrics.end_measure()
        metrics.record_operation("installed_lookup", duration)
        if metrics.stats then
            metrics.stats.operations.total_loads = (metrics.stats.operations.total_loads or 0) + 1
        end

        if err then
            debug(
                string.format("Error getting installed version for %s/%s: %s", manager_type, package_name, err),
                vim.log.levels.ERROR
            )
            metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
            callback(err, nil)
            return
        end

        if not version then
            debug(string.format("No version returned for %s/%s", manager_type, package_name), vim.log.levels.WARN)
            callback(nil, nil)
            return
        end

        local version_str = type(version) == "table" and version.version or version

        local ts = now()
        local info = {
            version = version_str,
            metadata = type(version) == "table" and version.metadata or {},
            installed_at = ts,
        }

        entry[const.CACHE_FIELDS.DATA][package_name] = info

        debug(string.format("Cache SAVE for %s/%s = %s", manager_type, package_name, version_str), vim.log.levels.INFO)

        local ttl = config.cache.ttl.installed
        if ttl then
            entry[const.CACHE_FIELDS.EXPIRY] = entry[const.CACHE_FIELDS.EXPIRY] or {}
            entry[const.CACHE_FIELDS.EXPIRY][package_name] = ts + ttl
        end

        callback(nil, version_str)
    end)
end

--- All cached installed versions for a manager (name → version string).
---@param manager_type string
---@return table<string, string|nil>
function M.get_data(manager_type)
    local entry = cache.ensure(manager_type, CACHE_TYPE_INSTALLED)
    local result = {}
    for name, value in pairs(entry[const.CACHE_FIELDS.DATA]) do
        result[name] = extract_version(value)
    end
    return result
end

--- All cached installed entries for a manager, with metadata (deepcopied).
---@param manager_type string
---@return table<string, InstalledPackageInfo>
function M.get_full_data(manager_type)
    local entry = cache.ensure(manager_type, CACHE_TYPE_INSTALLED)
    return vim.deepcopy(entry[const.CACHE_FIELDS.DATA])
end

--- Clear installed cache for a manager/package (or all when manager_type is nil).
---@param manager_type? string
---@param package_name? string
function M.clear_cache(manager_type, package_name)
    if not manager_type then
        cache.get()[CACHE_TYPE_INSTALLED] = {}
        return
    end
    cache.clear(manager_type, CACHE_TYPE_INSTALLED, package_name)
    -- cache.clear already calls metrics.record_cache_clear()
end

return M
