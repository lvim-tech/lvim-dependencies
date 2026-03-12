-- lvim-dependencies/core/hub/installed.lua
-- Central hub for installed package operations (callback-based)

---@include "types.lua"

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

local function extract_version(cached)
    if type(cached) == "table" then
        return cached.version
    end
    return cached
end

-- ============================================================================
-- Public API
-- ============================================================================

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

function M.get_data(manager_type)
    local entry = cache.ensure(manager_type, CACHE_TYPE_INSTALLED)
    local result = {}
    for name, value in pairs(entry[const.CACHE_FIELDS.DATA]) do
        result[name] = extract_version(value)
    end
    return result
end

function M.get_full_data(manager_type)
    local entry = cache.ensure(manager_type, CACHE_TYPE_INSTALLED)
    return vim.deepcopy(entry[const.CACHE_FIELDS.DATA])
end

function M.clear_cache(manager_type, package_name)
    if not manager_type then
        cache.get()[CACHE_TYPE_INSTALLED] = {}
        return
    end
    cache.clear(manager_type, CACHE_TYPE_INSTALLED, package_name)
    -- cache.clear already calls metrics.record_cache_clear()
end

return M
