-- lvim-dependencies.core.hub.declared: synchronous access to a manager's DECLARED
-- packages (what the manifest file asks for). Reads the whole manifest once through the
-- manager's data.declared module, caches it in core.cache, and serves deepcopies so
-- callers can't mutate the cached table. Declared data has no TTL — it's refreshed
-- explicitly (force_refresh) when the buffer changes, not by expiry.
--
---@module "lvim-dependencies.core.hub.declared"

local cache = require("lvim-dependencies.core.cache")
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")
local project = require("lvim-dependencies.core.project")

local debug = utils.debug
local deepcopy = vim.deepcopy
local tbl_count = vim.tbl_count

local CACHE_TYPE_DECLARED = const.CACHE_TYPES.DECLARED

---@class DeclaredHub
local M = {}

--- Cache for loaded manager modules
---@type table<string, DeclaredModule>
local manager_modules = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Load declared module for a manager, caching the result
---@param manager_type string
---@return DeclaredModule|nil
local function load_declared_module(manager_type)
    if manager_modules[manager_type] then
        return manager_modules[manager_type]
    end

    local module_token = metrics.start_measure("module:declared:" .. manager_type)

    local module_path = string.format("lvim-dependencies.managers.%s.data.declared", manager_type)
    local ok, mod = pcall(require, module_path)

    local duration = metrics.end_measure(module_token)
    metrics.record_operation("module_load", duration)

    if not ok or not mod then
        debug(string.format("Failed to load declared module for %s", manager_type), vim.log.levels.ERROR)
        metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
        return nil
    end

    manager_modules[manager_type] = mod
    debug(string.format("Loaded declared module for %s", manager_type), vim.log.levels.DEBUG)
    return mod
end

--- Load fresh declared data from the loader module into the cache entry
---@param manager_type string
---@param entry table
---@param root string  directory the manifest search starts from
---@return table<string, any>
local function load_fresh_data(manager_type, entry, root)
    local loader = load_declared_module(manager_type)
    if not loader or not loader.get_data then
        debug(string.format("No valid declared module for %s", manager_type), vim.log.levels.ERROR)
        return {}
    end

    local load_token = metrics.start_measure("declared:load:" .. manager_type)

    local ok, data = pcall(loader.get_data, { root = root })

    if not ok then
        metrics.end_measure(load_token)
        debug(
            string.format("Failed to load declared data for %s: %s", manager_type, tostring(data)),
            vim.log.levels.ERROR
        )
        metrics.record_error(manager_type, const.METRICS.ERROR_TYPES.OTHER)
        return {}
    end

    local duration = metrics.end_measure(load_token)
    metrics.record_operation("declared_load", duration)
    if metrics.stats then
        metrics.stats.operations.total_loads = (metrics.stats.operations.total_loads or 0) + 1
    end

    if data then
        entry[const.CACHE_FIELDS.DATA] = data
    end
    -- Remember which project the entry describes and that a load happened at all: the fast
    -- path used to test `next(data) ~= nil`, so an empty manifest was re-parsed on every call.
    entry.root = root
    entry.loaded = true

    local count = tbl_count(entry[const.CACHE_FIELDS.DATA])
    debug(string.format("Loaded %d declared packages for %s", count, manager_type), vim.log.levels.INFO)
    return entry[const.CACHE_FIELDS.DATA]
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get declared packages data for a manager.
--- Returns cached data if available, otherwise loads from the declared module. The cache
--- holds ONE project per manager: a request for a different root (another workspace member's
--- manifest) re-reads, so the entry always describes the manifest the caller is looking at.
---@param manager_type string
---@param opts? { force_refresh?: boolean, root?: string, bufnr?: integer }
---@return table<string, any>
function M.get_data(manager_type, opts)
    opts = opts or {}
    local entry = cache.ensure(manager_type, CACHE_TYPE_DECLARED)
    local root = project.search_root(manager_type, opts)
    local same_project = entry.root == nil or entry.root == root

    -- Fast path: use cached data
    if not opts.force_refresh and entry.loaded and same_project then
        local count = tbl_count(entry[const.CACHE_FIELDS.DATA])
        debug(
            string.format("Using cached declared data for %s (%d packages)", manager_type, count),
            vim.log.levels.DEBUG
        )

        -- Single source of truth for cache hit recording
        metrics.record_cache_event(manager_type, true)

        return deepcopy(entry[const.CACHE_FIELDS.DATA])
    end

    -- Cache miss
    metrics.record_cache_event(manager_type, false)

    if opts.force_refresh then
        entry[const.CACHE_FIELDS.DATA] = {}
        debug(string.format("Force refreshing declared data for %s", manager_type), vim.log.levels.INFO)
    elseif not same_project then
        entry[const.CACHE_FIELDS.DATA] = {}
        debug(string.format("Declared data for %s belongs to %s, reloading for %s", manager_type, entry.root, root), vim.log.levels.INFO)
    else
        debug(string.format("Loading declared data for %s", manager_type), vim.log.levels.INFO)
    end

    load_fresh_data(manager_type, entry, root)
    return deepcopy(entry[const.CACHE_FIELDS.DATA])
end

--- Clear declared cache for a manager (or all).
---@param manager_type? string
---@param package_name? string
function M.clear_cache(manager_type, package_name)
    if not manager_type then
        debug("Clearing all declared cache", vim.log.levels.INFO)
        cache.get()[CACHE_TYPE_DECLARED] = {}
        return
    end

    if package_name then
        debug(string.format("Clearing cache for %s/%s", manager_type, package_name), vim.log.levels.INFO)
    else
        debug(string.format("Clearing all cache for %s", manager_type), vim.log.levels.INFO)
    end

    cache.clear(manager_type, CACHE_TYPE_DECLARED, package_name)
end

--- Force refresh declared data (synchronous). Without `opts` the project last loaded for this
--- manager is re-read (the one an install / update just rewrote).
---@param manager_type string
---@param opts? { root?: string, bufnr?: integer }
---@return table<string, any>
function M.refresh_data(manager_type, opts)
    local entry = cache.ensure(manager_type, CACHE_TYPE_DECLARED)
    local o = { force_refresh = true }
    if opts then
        o.root, o.bufnr = opts.root, opts.bufnr
    elseif entry.root then
        o.root = entry.root
    end
    return M.get_data(manager_type, o)
end

return M
