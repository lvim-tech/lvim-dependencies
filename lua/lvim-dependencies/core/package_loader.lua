-- lvim-dependencies/core/package_loader.lua
-- Coroutine-based package data loader

---@include "types.lua"

local hub_declared = require("lvim-dependencies.core.hub.declared")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local utils = require("lvim-dependencies.utils")
local async = require("lvim-dependencies.core.async_util")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")
local config = require("lvim-dependencies.config")

local debug = utils.debug
local M = {}

-- ============================================================================
-- Constants — sourced from config
-- ============================================================================
local DEFAULT_CONCURRENCY = config.async.package_loader.concurrency or 10
local DEFAULT_RETRY_COUNT = config.async.package_loader.retry_count or 3
local DEFAULT_RETRY_DELAY = config.async.package_loader.retry_delay or 1000

-- ============================================================================
-- Helpers
-- ============================================================================

--- Create a PackageResult with given fields
---@param manifest_type string
---@param package_name string
---@param fields? table
---@return PackageResult
local function make_result(manifest_type, package_name, fields)
    local result = {
        manifest = manifest_type,
        package = package_name,
        declared = nil,
        installed = nil,
        latest = nil,
        installed_err = nil,
        latest_err = nil,
    }
    if fields then
        for k, v in pairs(fields) do
            result[k] = v
        end
    end
    return result
end

--- Normalize error value to string or nil
---@param err any
---@return string|nil
local function normalize_error(err)
    return type(err) == "string" and err or nil
end

--- Load declared data for a package.
--- Delegates to hub/declared which already handles caching — no local cache needed.
---@param manifest_type string
---@param package_name string
---@return table|nil
local function load_declared(manifest_type, package_name)
    -- hub_declared.get_data already caches the entire manifest; just read from it.
    local all_declared = hub_declared.get_data(manifest_type)
    return all_declared and all_declared[package_name] or nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Load package data asynchronously
---@param manifest_type string
---@param package_name string
---@param callback PackageLoaderCallback
---@param opts? PackageLoaderOptions
function M.load_package_data_async(manifest_type, package_name, callback, opts)
    opts = opts or {}

    metrics.start_measure("package:load:" .. manifest_type .. ":" .. package_name)

    async.run(function()
        local declared = load_declared(manifest_type, package_name)

        local installed_task = function(cb)
            hub_installed.get_package_installed(manifest_type, package_name, cb)
        end

        local latest_task = function(cb)
            hub_latest.get_package_latest(manifest_type, package_name, cb)
        end

        local results = async.all_settled(installed_task, latest_task)

        if #results < 2 then
            local err_msg = "Failed to get results"
            debug(string.format("Invalid results for %s/%s", manifest_type, package_name), vim.log.levels.ERROR)
            metrics.record_error(manifest_type, const.METRICS.ERROR_TYPES.OTHER)

            local duration = metrics.end_measure()
            metrics.record_operation("package_load_failed", duration)

            callback(make_result(manifest_type, package_name, {
                declared = declared,
                installed_err = err_msg,
                latest_err = err_msg,
            }))
            return
        end

        local installed_result = results[1] or {}
        local latest_result = results[2] or {}

        local duration = metrics.end_measure()
        metrics.record_operation("package_load", duration)
        if metrics.stats then
            metrics.stats.operations.total_loads = (metrics.stats.operations.total_loads or 0) + 1
        end

        callback(make_result(manifest_type, package_name, {
            declared = declared,
            installed = installed_result[2],
            latest = latest_result[2],
            installed_err = normalize_error(installed_result[1]),
            latest_err = normalize_error(latest_result[1]),
        }))
    end)
end

--- Load package data with retry on failure
---@param manifest_type string
---@param package_name string
---@param callback PackageLoaderCallback
---@param opts? {max_retries?: integer, delay?: integer}
function M.load_package_data_with_retry(manifest_type, package_name, callback, opts)
    opts = opts or {}
    local max_retries = opts.max_retries or DEFAULT_RETRY_COUNT
    local delay = opts.delay or DEFAULT_RETRY_DELAY
    local attempt = 1

    local function attempt_load()
        M.load_package_data_async(manifest_type, package_name, function(result)
            local has_error = result.installed_err or result.latest_err
            if not has_error or attempt >= max_retries then
                callback(result)
                return
            end

            attempt = attempt + 1
            debug(
                string.format(
                    "Retrying load for %s/%s (attempt %d/%d)",
                    manifest_type,
                    package_name,
                    attempt,
                    max_retries
                ),
                vim.log.levels.DEBUG
            )

            vim.defer_fn(attempt_load, delay)
        end)
    end

    attempt_load()
end

--- Synchronous version — must be called from within a coroutine
---@param manifest_type string
---@param package_name string
---@param opts? PackageLoaderOptions
---@return PackageResult
function M.load_package_data(manifest_type, package_name, opts)
    local co = coroutine.running()
    if not co then
        error("load_package_data must be called inside a coroutine")
    end

    local result
    local has_result = false

    local ok, err = pcall(M.load_package_data_async, manifest_type, package_name, function(res)
        result = res
        has_result = true
        coroutine.resume(co)
    end, opts)

    if not ok then
        debug(
            string.format("Error in async load for %s/%s: %s", manifest_type, package_name, err),
            vim.log.levels.ERROR
        )
        metrics.record_error(manifest_type)
        return make_result(manifest_type, package_name, {
            installed_err = "Async load failed: " .. tostring(err),
            latest_err = "Async load failed: " .. tostring(err),
        })
    end

    if not has_result then
        coroutine.yield()
    end
    return result
end

--- Load multiple packages in parallel with concurrency limit
---@param manifest_type string
---@param package_names string[]
---@param callback fun(results: table<string, PackageResult>)
---@param concurrency? integer
function M.load_multiple_packages_async(manifest_type, package_names, callback, concurrency)
    concurrency = concurrency or DEFAULT_CONCURRENCY
    local count = #package_names
    if count == 0 then
        callback({})
        return
    end

    local results = {}
    local remaining = count
    local running = 0
    local next_idx = 1

    local function start_next()
        while running < concurrency and next_idx <= count do
            local idx = next_idx
            next_idx = next_idx + 1
            running = running + 1
            local package_name = package_names[idx]

            M.load_package_data_async(manifest_type, package_name, function(result)
                results[package_name] = result
                remaining = remaining - 1
                running = running - 1
                if remaining == 0 then
                    callback(results)
                else
                    start_next()
                end
            end)
        end
    end

    start_next()
end

--- Load multiple packages with a timeout
---@param manifest_type string
---@param package_names string[]
---@param timeout_ms number
---@param callback fun(results: table<string, PackageResult>, timed_out: boolean)
function M.load_multiple_packages_with_timeout(manifest_type, package_names, timeout_ms, callback)
    local count = #package_names
    if count == 0 then
        callback({}, false)
        return
    end

    local results = {}
    local remaining = count
    local timed_out = false
    local timer = vim.loop.new_timer()

    if not timer then
        callback({}, false)
        return
    end

    timer:start(
        timeout_ms,
        0,
        vim.schedule_wrap(function()
            if timed_out then
                return
            end
            timed_out = true
            if not timer:is_closing() then
                timer:close()
            end
            metrics.record_error(manifest_type, const.METRICS.ERROR_TYPES.TIMEOUT)
            callback(results, true)
        end)
    )

    local function on_complete(package_name, result)
        if timed_out then
            return
        end
        results[package_name] = result
        remaining = remaining - 1
        if remaining == 0 then
            timed_out = true -- prevent any already-queued timer callback from firing
            if not timer:is_closing() then
                timer:close()
            end
            callback(results, false)
        end
    end

    for _, package_name in ipairs(package_names) do
        M.load_package_data_async(manifest_type, package_name, function(result)
            on_complete(package_name, result)
        end)
    end
end

--- Clear declared cache for a manifest type.
--- Delegates to hub_declared which owns the cache.
---@param manifest_type? string
function M.clear_cache(manifest_type)
    hub_declared.clear_cache(manifest_type)
end

return M
