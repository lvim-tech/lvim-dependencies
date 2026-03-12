-- lvim-dependencies/core/hub/latest.lua
-- Central hub for latest package operations (callback-based)

---@include "types.lua"

local cache = require("lvim-dependencies.core.cache")
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")
local config = require("lvim-dependencies.config")

local debug = utils.debug
local deepcopy = vim.deepcopy
local now = os.time

local CACHE_TYPE_LATEST = const.CACHE_TYPES.LATEST

---@class LatestHub
local M = {}

---@type table<string, LatestModule>
local manager_modules = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function load_latest_module(manager_type)
    if manager_modules[manager_type] then
        return manager_modules[manager_type]
    end

    metrics.start_measure("module:latest:" .. manager_type)

    local module_path = string.format("lvim-dependencies.managers.%s.data.latest", manager_type)
    local ok, mod = pcall(require, module_path)

    local duration = metrics.end_measure()
    metrics.record_operation("module_load", duration)

    if not ok or not mod then
        debug(string.format("Failed to load latest module for %s", manager_type), vim.log.levels.ERROR)
        metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
        return nil
    end

    if not mod.get_package_latest then
        debug(string.format("Latest module for %s missing get_package_latest", manager_type), vim.log.levels.ERROR)
        metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
        return nil
    end

    manager_modules[manager_type] = mod
    debug(string.format("Loaded latest module for %s", manager_type), vim.log.levels.DEBUG)
    return mod
end

--- Check if a cached entry is expired
---@param entry table
---@param package_name string
---@return boolean
local function is_expired(entry, package_name)
    local expiry = entry[const.CACHE_FIELDS.EXPIRY] and entry[const.CACHE_FIELDS.EXPIRY][package_name]
    if not expiry then
        return false
    end
    return now() > expiry
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.get_package_latest(manager_type, package_name, callback)
    local entry = cache.ensure(manager_type, CACHE_TYPE_LATEST)
    local cached = entry[const.CACHE_FIELDS.DATA][package_name]

    if cached and not is_expired(entry, package_name) then
        debug(
            string.format("Cache HIT for %s/%s: %s", manager_type, package_name, cached.version or "nil"),
            vim.log.levels.INFO
        )

        -- Single source of truth for cache hit recording
        metrics.record_cache_event(manager_type, true)
        callback(nil, cached)
        return
    end

    if cached then
        debug(string.format("Cache EXPIRED for %s/%s", manager_type, package_name), vim.log.levels.INFO)
        entry[const.CACHE_FIELDS.DATA][package_name] = nil
        if entry[const.CACHE_FIELDS.EXPIRY] then
            entry[const.CACHE_FIELDS.EXPIRY][package_name] = nil
        end
        metrics.record_cache_expiry(manager_type)
    else
        debug(string.format("Cache MISS for %s/%s", manager_type, package_name), vim.log.levels.INFO)
        metrics.record_cache_event(manager_type, false)
    end

    local latest_mod = load_latest_module(manager_type)
    if not latest_mod then
        local err = string.format("No valid latest module for %s", manager_type)
        debug(err, vim.log.levels.ERROR)
        callback(err, nil)
        return
    end

    metrics.start_measure("latest:lookup:" .. package_name)

    latest_mod.get_package_latest(package_name, function(err, result)
        local duration = metrics.end_measure()
        metrics.record_operation("latest_lookup", duration)
        if metrics.stats then
            metrics.stats.operations.total_loads = (metrics.stats.operations.total_loads or 0) + 1
        end

        if err then
            debug(
                string.format("Error getting latest version for %s/%s: %s", manager_type, package_name, err),
                vim.log.levels.ERROR
            )
            metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.NETWORK)
            callback(err, nil)
            return
        end

        local ts = now()
        local info
        if type(result) == "table" then
            info = { version = result.version, metadata = result.metadata or {}, fetched_at = ts }
        else
            info = { version = result, metadata = {}, fetched_at = ts }
        end

        entry[const.CACHE_FIELDS.DATA][package_name] = info

        debug(string.format("Cache SAVE for %s/%s = %s", manager_type, package_name, info.version), vim.log.levels.INFO)

        local ttl = config.cache.ttl.latest
        if ttl then
            entry[const.CACHE_FIELDS.EXPIRY] = entry[const.CACHE_FIELDS.EXPIRY] or {}
            entry[const.CACHE_FIELDS.EXPIRY][package_name] = ts + ttl
        end

        callback(nil, info)
    end)
end

function M.get_data(manager_type)
    local entry = cache.ensure(manager_type, CACHE_TYPE_LATEST)
    local result = {}
    for name, info in pairs(entry[const.CACHE_FIELDS.DATA]) do
        if not is_expired(entry, name) then
            result[name] = info
            metrics.record_cache_event(manager_type, true)
        else
            metrics.record_cache_expiry(manager_type)
        end
    end
    return result
end

function M.get_full_data(manager_type)
    local entry = cache.ensure(manager_type, CACHE_TYPE_LATEST)
    return deepcopy(entry[const.CACHE_FIELDS.DATA])
end

function M.clear_cache(manager_type, package_name)
    if not manager_type then
        debug("Clearing all latest cache", vim.log.levels.INFO)
        cache.get()[CACHE_TYPE_LATEST] = {}
        -- cache.clear already records clears in metrics
        return
    end

    if package_name then
        debug(string.format("Clearing cache for %s/%s", manager_type, package_name), vim.log.levels.INFO)
    else
        debug(string.format("Clearing all cache for %s", manager_type), vim.log.levels.INFO)
    end

    cache.clear(manager_type, CACHE_TYPE_LATEST, package_name)
end

return M
