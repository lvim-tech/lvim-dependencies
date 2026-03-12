-- lvim-dependencies/core/cache.lua
-- Central cache module for all data types

---@include "types.lua"

local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")

-- metrics is loaded lazily to avoid a circular dependency at startup
local _metrics = nil
local function get_metrics()
    if not _metrics then
        local ok, m = pcall(require, "lvim-dependencies.core.metrics")
        if ok then
            _metrics = m
        end
    end
    return _metrics
end

local deepcopy = vim.deepcopy
local now = os.time

---@class Cache
local cache = {
    [const.CACHE_TYPES.DECLARED] = {},
    [const.CACHE_TYPES.INSTALLED] = {},
    [const.CACHE_TYPES.LATEST] = {},
    [const.CACHE_TYPES.VIRTUAL_TEXT] = {},
    [const.CACHE_TYPES.MANIFEST] = {},
}

local CACHE_ENTRY_TEMPLATE = {
    [const.CACHE_FIELDS.DATA] = {},
    [const.CACHE_FIELDS.METADATA] = {},
    [const.CACHE_FIELDS.TEMP] = {},
    [const.CACHE_FIELDS.EXPIRY] = {},
    [const.CACHE_FIELDS.VERSION] = 1,
}

local M = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Get TTL for a specific cache type from config
---@param cache_type string
---@return integer|nil
local function get_ttl(cache_type)
    local ttl_map = {
        [const.CACHE_TYPES.INSTALLED] = config.cache.ttl.installed,
        [const.CACHE_TYPES.LATEST] = config.cache.ttl.latest,
        [const.CACHE_TYPES.MANIFEST] = config.cache.ttl.manifest,
        [const.CACHE_TYPES.DECLARED] = config.cache.ttl.declared,
    }
    return ttl_map[cache_type]
end

--- Check if a cache entry has expired.
--- Does NOT record metrics — callers that care should do so via metrics.record_cache_expiry.
---@param manager_cache table
---@param cache_type string
---@param package_name string
---@return boolean
local function is_expired(manager_cache, cache_type, package_name)
    local ttl = get_ttl(cache_type)
    if not ttl then
        return false
    end

    local expiry = manager_cache[const.CACHE_FIELDS.EXPIRY] and manager_cache[const.CACHE_FIELDS.EXPIRY][package_name]

    return expiry ~= nil and now() > expiry
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Ensure cache structure exists for a manager and cache type
---@param manager_type string
---@param cache_type CacheType
---@return table
function M.ensure(manager_type, cache_type)
    local ct = cache[cache_type]
    if not ct then
        ct = {}
        cache[cache_type] = ct
    end

    local mc = ct[manager_type]
    if not mc then
        mc = deepcopy(CACHE_ENTRY_TEMPLATE)
        ct[manager_type] = mc
    elseif mc[const.CACHE_FIELDS.VERSION] ~= CACHE_ENTRY_TEMPLATE[const.CACHE_FIELDS.VERSION] then
        mc = deepcopy(CACHE_ENTRY_TEMPLATE)
        ct[manager_type] = mc
    end

    return mc
end

--- Safely copy cache data with optional key filtering
---@param entry table
---@param keys? string[]
---@return table
local function copy_data(entry, keys)
    if not keys then
        return deepcopy(entry[const.CACHE_FIELDS.DATA])
    end
    local result = {}
    for _, key in ipairs(keys) do
        if entry[const.CACHE_FIELDS.DATA][key] ~= nil then
            result[key] = deepcopy(entry[const.CACHE_FIELDS.DATA][key])
        end
    end
    return result
end

--- Get declared package data
---@param manager_type string
---@param keys? string[]
---@return table
function M.get_declared(manager_type, keys)
    return copy_data(M.ensure(manager_type, const.CACHE_TYPES.DECLARED), keys)
end

--- Get installed package data with expiry checking
---@param manager_type string
---@param keys? string[]
---@return table
function M.get_installed(manager_type, keys)
    local entry = M.ensure(manager_type, const.CACHE_TYPES.INSTALLED)
    if not keys then
        return copy_data(entry)
    end

    local metrics = get_metrics()
    local result = {}
    for _, pkg in ipairs(keys) do
        if not is_expired(entry, const.CACHE_TYPES.INSTALLED, pkg) then
            result[pkg] = entry[const.CACHE_FIELDS.DATA][pkg]
            if metrics then
                metrics.record_cache_event(manager_type, true)
            end
        else
            if metrics then
                metrics.record_cache_expiry(manager_type)
            end
        end
    end
    return result
end

--- Get latest version data with expiry checking
---@param manager_type string
---@param keys? string[]
---@return table
function M.get_latest(manager_type, keys)
    local entry = M.ensure(manager_type, const.CACHE_TYPES.LATEST)
    if not keys then
        return copy_data(entry)
    end

    local metrics = get_metrics()
    local result = {}
    for _, pkg in ipairs(keys) do
        if not is_expired(entry, const.CACHE_TYPES.LATEST, pkg) then
            result[pkg] = entry[const.CACHE_FIELDS.DATA][pkg]
            if metrics then
                metrics.record_cache_event(manager_type, true)
            end
        else
            if metrics then
                metrics.record_cache_expiry(manager_type)
            end
        end
    end
    return result
end

--- Batch set multiple cache entries
---@param manager_type string
---@param cache_type string
---@param entries table
---@param metadata? table
function M.batch_set(manager_type, cache_type, entries, metadata)
    local entry = M.ensure(manager_type, cache_type)
    local now_time = now()
    local ttl = get_ttl(cache_type)

    for key, value in pairs(entries) do
        entry[const.CACHE_FIELDS.DATA][key] = value
        if ttl then
            entry[const.CACHE_FIELDS.EXPIRY] = entry[const.CACHE_FIELDS.EXPIRY] or {}
            entry[const.CACHE_FIELDS.EXPIRY][key] = now_time + ttl
        end
        if metadata and metadata[key] then
            entry[const.CACHE_FIELDS.METADATA] = entry[const.CACHE_FIELDS.METADATA] or {}
            entry[const.CACHE_FIELDS.METADATA][key] = metadata[key]
        end
    end
end

--- Set a single declared package
---@param manager_type string
---@param package_name string
---@param value any
function M.set_declared(manager_type, package_name, value)
    local entry = M.ensure(manager_type, const.CACHE_TYPES.DECLARED)
    entry[const.CACHE_FIELDS.DATA][package_name] = value
end

--- Set installed package with TTL
---@param manager_type string
---@param package_name string
---@param value any
function M.set_installed(manager_type, package_name, value)
    local entry = M.ensure(manager_type, const.CACHE_TYPES.INSTALLED)
    entry[const.CACHE_FIELDS.DATA][package_name] = value
    local ttl = get_ttl(const.CACHE_TYPES.INSTALLED)
    if ttl then
        entry[const.CACHE_FIELDS.EXPIRY] = entry[const.CACHE_FIELDS.EXPIRY] or {}
        entry[const.CACHE_FIELDS.EXPIRY][package_name] = now() + ttl
    end
end

--- Set latest version with TTL
---@param manager_type string
---@param package_name string
---@param value any
function M.set_latest(manager_type, package_name, value)
    local entry = M.ensure(manager_type, const.CACHE_TYPES.LATEST)
    entry[const.CACHE_FIELDS.DATA][package_name] = value
    local ttl = get_ttl(const.CACHE_TYPES.LATEST)
    if ttl then
        entry[const.CACHE_FIELDS.EXPIRY] = entry[const.CACHE_FIELDS.EXPIRY] or {}
        entry[const.CACHE_FIELDS.EXPIRY][package_name] = now() + ttl
    end
end

--- Clear cache entries
---@param manager_type? string
---@param cache_type string
---@param package_name? string
function M.clear(manager_type, cache_type, package_name)
    local ct = cache[cache_type]
    if not ct then
        return
    end

    if not manager_type then
        cache[cache_type] = {}
    elseif not package_name then
        ct[manager_type] = nil
    else
        local mc = ct[manager_type]
        if mc then
            mc[const.CACHE_FIELDS.DATA][package_name] = nil
            if mc[const.CACHE_FIELDS.METADATA] then
                mc[const.CACHE_FIELDS.METADATA][package_name] = nil
            end
            if mc[const.CACHE_FIELDS.EXPIRY] then
                mc[const.CACHE_FIELDS.EXPIRY][package_name] = nil
            end
        end
    end

    local metrics = get_metrics()
    if metrics then
        metrics.record_cache_clear()
    end
end

--- Clear all caches for a specific manager
---@param manager_type string
function M.clear_all(manager_type)
    for _, cache_type in ipairs({
        const.CACHE_TYPES.DECLARED,
        const.CACHE_TYPES.INSTALLED,
        const.CACHE_TYPES.LATEST,
    }) do
        local ct = cache[cache_type]
        if ct then
            ct[manager_type] = nil
        end
    end
    local metrics = get_metrics()
    if metrics then
        metrics.record_cache_clear()
    end
end

--- Check if a package exists in cache and is not expired
---@param manager_type string
---@param cache_type string
---@param package_name string
---@return boolean
function M.has(manager_type, cache_type, package_name)
    local ct = cache[cache_type]
    local metrics = get_metrics()

    if not ct then
        if metrics then
            metrics.record_cache_event(manager_type, false)
        end
        return false
    end

    local mc = ct[manager_type]
    if not mc or mc[const.CACHE_FIELDS.DATA][package_name] == nil then
        if metrics then
            metrics.record_cache_event(manager_type, false)
        end
        return false
    end

    if is_expired(mc, cache_type, package_name) then
        if metrics then
            metrics.record_cache_expiry(manager_type)
        end
        return false
    end

    if metrics then
        metrics.record_cache_event(manager_type, true)
    end
    return true
end

--- Get package data with its metadata
---@param manager_type string
---@param cache_type string
---@param package_name string
---@return any, any
function M.get_with_metadata(manager_type, cache_type, package_name)
    local ct = cache[cache_type]
    local metrics = get_metrics()

    if not ct then
        if metrics then
            metrics.record_cache_event(manager_type, false)
        end
        return nil, nil
    end

    local mc = ct[manager_type]
    local expired = mc and is_expired(mc, cache_type, package_name)
    if not mc or expired then
        if expired then
            if metrics then
                metrics.record_cache_expiry(manager_type)
            end
        else
            if metrics then
                metrics.record_cache_event(manager_type, false)
            end
        end
        return nil, nil
    end

    if metrics then
        metrics.record_cache_event(manager_type, true)
    end
    return mc[const.CACHE_FIELDS.DATA][package_name],
        mc[const.CACHE_FIELDS.METADATA] and mc[const.CACHE_FIELDS.METADATA][package_name]
end

--- Set package data with metadata
---@param manager_type string
---@param cache_type string
---@param package_name string
---@param value any
---@param metadata? table
function M.set_with_metadata(manager_type, cache_type, package_name, value, metadata)
    local entry = M.ensure(manager_type, cache_type)
    entry[const.CACHE_FIELDS.DATA][package_name] = value

    if metadata then
        entry[const.CACHE_FIELDS.METADATA] = entry[const.CACHE_FIELDS.METADATA] or {}
        entry[const.CACHE_FIELDS.METADATA][package_name] = metadata
    end

    local ttl = get_ttl(cache_type)
    if ttl then
        entry[const.CACHE_FIELDS.EXPIRY] = entry[const.CACHE_FIELDS.EXPIRY] or {}
        entry[const.CACHE_FIELDS.EXPIRY][package_name] = now() + ttl
    end
end

--- Get the entire cache structure
---@return table
function M.get()
    return cache
end

--- Clean up all expired cache entries
---@return integer
function M.cleanup_expired()
    if
        not config
        or not config.cache
        or not config.cache.cleanup
        or not config.cache.stats
        or not config.cache.stats.collect
    then
        return 0
    end

    local cleaned = 0
    local metrics = get_metrics()

    ---@diagnostic disable-next-line: unused-local
    for cache_type_name, cache_table in pairs(cache) do
        ---@diagnostic disable-next-line: unused-local
        for manager_name, manager_cache in pairs(cache_table) do
            if manager_cache[const.CACHE_FIELDS.EXPIRY] then
                for pkg, expiry in pairs(manager_cache[const.CACHE_FIELDS.EXPIRY]) do
                    if now() > expiry then
                        manager_cache[const.CACHE_FIELDS.DATA][pkg] = nil
                        manager_cache[const.CACHE_FIELDS.EXPIRY][pkg] = nil
                        cleaned = cleaned + 1
                        if metrics then
                            metrics.record_cache_expiry(manager_name)
                        end
                    end
                end
            end
        end
    end

    if cleaned > 0 then
        local ok, utils = pcall(require, "lvim-dependencies.utils")
        if ok and utils and utils.debug then
            utils.debug(string.format("Cleaned %d expired cache entries", cleaned), vim.log.levels.DEBUG)
        end
    end

    return cleaned
end

--- Start periodic cache cleanup timer
local cleanup_timer = nil
function M.start_cleanup_timer()
    if cleanup_timer then
        return cleanup_timer
    end

    if not config or not config.cache or not config.cache.cleanup or not config.cache.cleanup.interval then
        return nil
    end

    local interval = config.cache.cleanup.interval
    cleanup_timer = vim.loop.new_timer()
    if cleanup_timer then
        cleanup_timer:start(
            interval,
            interval,
            vim.schedule_wrap(function()
                M.cleanup_expired()
            end)
        )
    end

    return cleanup_timer
end

--- Stop the cleanup timer
function M.stop_cleanup_timer()
    if cleanup_timer then
        pcall(function()
            cleanup_timer:stop()
            cleanup_timer:close()
        end)
        cleanup_timer = nil
    end
end

return M
