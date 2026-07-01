-- lvim-dependencies.core.operator: the executor half of the Command pattern. Dispatches a
-- Command to its registered per-manager handler, optionally with bounded retries — but a
-- user cancellation or a handler-flagged deterministic failure (result.no_retry) short-
-- circuits the retry loop so we never re-run something the user aborted or that can't
-- succeed. On success it invalidates the affected packages' installed/latest cache entries.
--
---@module "lvim-dependencies.core.operator"

local cache = require("lvim-dependencies.core.cache")
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")

local debug = utils.debug
local notify = utils.notify

-- ============================================================================
-- Constants
-- ============================================================================
local DEFAULT_RETRY_COUNT = config.async.operator.retry_count or 2
local DEFAULT_RETRY_DELAY = config.async.operator.retry_delay or 2000

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_TYPE_LATEST = const.CACHE_TYPES.LATEST

-- ============================================================================
-- Handler registry
-- ============================================================================

---@type table<string, table>
local handlers = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Check if result indicates user cancellation
---@param result InstallerResult|nil
---@return boolean
local function is_cancellation(result)
    if not result then
        return false
    end
    -- Check for common cancellation messages
    local msg = result.message or ""
    return msg:match("cancelled")
        or msg:match("canceled")
        or msg:match("Cancelled")
        or msg:match("Canceled")
        or (not result.success and result.message == "cancelled")
end

---@param manager string
---@param packages string[]
local function clear_package_cache(manager, packages)
    if not packages or #packages == 0 then
        return
    end
    for _, pkg in ipairs(packages) do
        cache.clear(manager, CACHE_TYPE_INSTALLED, pkg)
        cache.clear(manager, CACHE_TYPE_LATEST, pkg)
    end
    debug(string.format("Cache cleared for %d packages in %s", #packages, manager), vim.log.levels.DEBUG)
end

---@param cmd Command
---@param result InstallerResult
local function finalize(cmd, result)
    result = result or { success = false, message = "No result returned" }

    if result.message and result.message ~= "" and result.message ~= "cancelled" then
        local level = result.success and vim.log.levels.INFO or vim.log.levels.ERROR
        local msg = string.format("[%s] %s", cmd.manager, result.message)
        if not result.success and result.data then
            msg = msg .. "\n" .. vim.inspect(result.data)
        end
        notify(msg, level)
    end

    if result.success and result.packages and #result.packages > 0 then
        clear_package_cache(cmd.manager, result.packages)
    end

    cmd.callback(result)
end

---@param cmd Command
---@return table|nil handler, string|nil err
local function resolve_handler(cmd)
    local handler = handlers[cmd.manager]
    if not handler then
        return nil, string.format("No handler registered for manager: %s", cmd.manager)
    end
    if type(handler.execute) ~= "function" then
        return nil, string.format("Handler for %s has no execute() function", cmd.manager)
    end
    return handler, nil
end

-- ============================================================================
-- Core dispatch
-- ============================================================================

---@param cmd Command
local function dispatch(cmd)
    local handler, err = resolve_handler(cmd)
    if not handler then
        finalize(cmd, { success = false, message = err })
        return
    end

    debug(
        string.format("Executing %s for %s (payload: %s)", cmd.type, cmd.manager, vim.inspect(cmd.payload)),
        vim.log.levels.INFO
    )

    handler.execute(cmd, function(result)
        finalize(cmd, result)
    end)
end

---@param cmd Command
---@param retry_count integer
---@param retry_delay integer
local function dispatch_with_retry(cmd, retry_count, retry_delay)
    local handler, err = resolve_handler(cmd)
    if not handler then
        finalize(cmd, { success = false, message = err })
        return
    end

    local attempt = 0
    local finished = false

    local function attempt_fn()
        if finished then
            return
        end
        attempt = attempt + 1

        debug(
            string.format(
                "Executing %s for %s (attempt %d/%d, payload: %s)",
                cmd.type,
                cmd.manager,
                attempt,
                retry_count,
                vim.inspect(cmd.payload)
            ),
            vim.log.levels.INFO
        )

        handler.execute(cmd, function(result)
            if finished then
                return
            end

            -- Check for user cancellation - do NOT retry
            if is_cancellation(result) then
                finished = true
                finalize(cmd, result)
                return
            end

            -- Deterministic failures (e.g. pub get dependency conflicts) - do NOT retry
            if result and result.no_retry then
                finished = true
                finalize(cmd, result)
                return
            end

            if result and result.success then
                finished = true
                finalize(cmd, result)
                return
            end

            if attempt >= retry_count then
                finished = true
                finalize(cmd, result or { success = false, message = "operation failed", packages = {} })
                return
            end

            debug(
                string.format("Retrying %s for %s (attempt %d/%d)", cmd.type, cmd.manager, attempt + 1, retry_count),
                vim.log.levels.DEBUG
            )

            vim.defer_fn(attempt_fn, retry_delay)
        end)
    end

    attempt_fn()
end

-- ============================================================================
-- Public API
-- ============================================================================

local M = {}

---@param manager_type string
---@param handler table
function M.register_handler(manager_type, handler)
    assert(type(manager_type) == "string", "manager_type must be a string")
    assert(type(handler) == "table", "handler must be a table")
    assert(type(handler.execute) == "function", "handler must have execute() function")

    handlers[manager_type] = handler
    debug(string.format("Handler registered for manager: %s", manager_type), vim.log.levels.DEBUG)
end

---@param cmd Command
---@param opts? { retry?: integer, delay?: integer }
function M.execute(cmd, opts)
    assert(type(cmd) == "table", "cmd must be a Command table")
    assert(type(cmd.type) == "string", "cmd.type must be a string")
    assert(type(cmd.manager) == "string", "cmd.manager must be a string")
    assert(type(cmd.payload) == "table", "cmd.payload must be a table")
    assert(type(cmd.callback) == "function", "cmd.callback must be a function")

    opts = opts or {}

    local retry_count = opts.retry or DEFAULT_RETRY_COUNT
    local retry_delay = opts.delay or DEFAULT_RETRY_DELAY

    if retry_count > 1 then
        dispatch_with_retry(cmd, retry_count, retry_delay)
    else
        dispatch(cmd)
    end
end

---@param manager_type string
---@return boolean
function M.has_handler(manager_type)
    return handlers[manager_type] ~= nil
end

---@param manager_type string
function M.unregister_handler(manager_type)
    handlers[manager_type] = nil
end

return M
