-- lvim-dependencies.core.package_loader: fetches the three facts about a package —
-- declared (sync, from the manifest), installed and latest (both async) — and merges them
-- into one PackageResult. A dependency the manager declares as not coming from the registry
-- (path, git, sdk, workspace) is never asked for a latest version — there is none to have. installed+latest run in parallel via async.all_settled so one
-- failing lookup never blocks the other; the per-manifest concurrency cap lives in
-- core.state (async.all_with_limit).
--
---@module "lvim-dependencies.core.package_loader"

local init = require("lvim-dependencies.core.init")
local hub_declared = require("lvim-dependencies.core.hub.declared")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local utils = require("lvim-dependencies.utils")
local async = require("lvim-dependencies.core.async_util")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")

local debug = utils.debug
local M = {}

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
---@param root string|nil  directory of the manifest being loaded (nil = cwd fallback)
---@return table|nil
local function load_declared(manifest_type, package_name, root)
    -- hub_declared.get_data already caches the entire manifest; just read from it.
    local all_declared = hub_declared.get_data(manifest_type, { root = root })
    return all_declared and all_declared[package_name] or nil
end

--- Is there a version of this dependency IN THE REGISTRY to look up?
--- A dependency whose source is not the registry — a local path, a git URL, an SDK, another
--- package of the same workspace — has none. The request was made anyway, came back 404, and
--- the failure then stood on the line INSTEAD of the declared and installed versions, which
--- were already known. A manager marks such kinds with `registry_latest = false` on the
--- dependency type; anything it does not mark is still looked up.
---@param manifest_type string
---@param declared any
---@return boolean
local function has_registry_latest(manifest_type, declared)
    local dep_type = type(declared) == "table" and declared.type or nil
    if type(dep_type) ~= "string" then
        return true
    end
    local manifest = init.get_manifest(manifest_type)
    local def = manifest and manifest.dependency_types and manifest.dependency_types[dep_type]
    return not (def and def.registry_latest == false)
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

    local load_token = metrics.start_measure("package:load:" .. manifest_type .. ":" .. package_name)

    async.run(function()
        local declared = load_declared(manifest_type, package_name, opts.root)

        local installed_task = function(cb)
            hub_installed.get_package_installed(manifest_type, package_name, cb, { root = opts.root })
        end

        local latest_task = function(cb)
            if not has_registry_latest(manifest_type, declared) then
                cb(nil, nil)
                return
            end
            hub_latest.get_package_latest(manifest_type, package_name, cb)
        end

        local results = async.all_settled(installed_task, latest_task)

        if #results < 2 then
            local err_msg = "Failed to get results"
            debug(string.format("Invalid results for %s/%s", manifest_type, package_name), vim.log.levels.ERROR)
            metrics.record_error(manifest_type, const.METRICS.ERROR_TYPES.OTHER)

            local duration = metrics.end_measure(load_token)
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

        local duration = metrics.end_measure(load_token)
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
        async.safe_resume(co) -- not a bare coroutine.resume: rethrow a resumed caller's error (module convention)
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

--- Clear declared cache for a manifest type.
--- Delegates to hub_declared which owns the cache.
---@param manifest_type? string
function M.clear_cache(manifest_type)
    hub_declared.clear_cache(manifest_type)
end

return M
