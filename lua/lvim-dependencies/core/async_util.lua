-- lvim-dependencies.core.async_util: coroutine-based async primitives (Neovim 0.10+).
-- await/run turn callback-style APIs into straight-line coroutine code; the combinators
-- (all/all_with_limit/race/all_settled) and the retry/debounce/throttle helpers all sit
-- on the same safe_resume core, which reschedules any coroutine error onto the main loop
-- (errors thrown inside a resume can't propagate normally, so they must be re-raised via
-- vim.schedule to surface at all).
--
---@module "lvim-dependencies.core.async_util"

local uv = vim.uv
local schedule = vim.schedule
local defer_fn = vim.defer_fn
local system = vim.system
local config = require("lvim-dependencies.config")

local coroutine_running = coroutine.running
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_wrap = coroutine.wrap

local M = {}

--- Safely resume a coroutine with error handling
---@param co thread The coroutine to resume
---@param ... any Arguments to pass to coroutine.resume
local function safe_resume(co, ...)
    if not co then
        schedule(function()
            error("Cannot resume nil coroutine")
        end)
        return
    end

    local ok, err = coroutine_resume(co, ...)
    if not ok then
        schedule(function()
            error(debug.traceback(co, err))
        end)
    end
end

--- Ensure function is called within a coroutine
---@param fn_name string Function name for error context
---@return thread co The current coroutine
local function assert_coroutine(fn_name)
    local co = coroutine_running()
    if not co then
        error(string.format("%s must be called inside a coroutine", fn_name))
    end
    return co
end

--- Wait for an async function that accepts a callback
---@param fn function Async function accepting a callback as last argument
---@param ... any Additional arguments for fn
---@return any ... Callback results
function M.await(fn, ...)
    local co = assert_coroutine("await")
    local args = { ... }
    local arg_count = select("#", ...)
    local done = false
    local results
    local result_count = 0
    local yielded = false

    fn(unpack(args, 1, arg_count), function(...)
        done = true
        results = { ... }
        result_count = select("#", ...)
        if yielded then
            safe_resume(co, ...)
        end
    end)

    if done then
        return unpack(results, 1, result_count)
    end
    yielded = true
    return coroutine_yield()
end

--- Wait for an async function with timeout
---@param fn function Async function accepting a callback as last argument
---@param timeout_ms? integer Optional timeout in milliseconds (uses config if nil)
---@param ... any Additional arguments for fn
---@return any ... Callback results, or `nil, "timeout"` on timeout
function M.await_with_timeout(fn, timeout_ms, ...)
    -- Fall back to config value if not provided
    timeout_ms = timeout_ms or config.async.defaults.timeout

    local co = assert_coroutine("await_with_timeout")
    local args = { ... }
    local arg_count = select("#", ...)
    local timed_out = false
    local timer
    local done = false
    local results
    local result_count = 0
    local yielded = false

    timer = defer_fn(function()
        timed_out = true
        done = true
        results = { nil, "timeout" }
        result_count = 2
        if yielded then
            safe_resume(co, nil, "timeout")
        end
    end, timeout_ms)

    fn(unpack(args, 1, arg_count), function(...)
        if timer then
            pcall(function()
                if timer:is_active() then
                    timer:stop()
                end
                if not timer:is_closing() then
                    timer:close()
                end
            end)
            timer = nil
        end
        if not timed_out then
            done = true
            results = { ... }
            result_count = select("#", ...)
            if yielded then
                safe_resume(co, ...)
            end
        end
    end)

    if done then
        return unpack(results, 1, result_count)
    end
    yielded = true
    return coroutine_yield()
end

--- Run an async function in a new coroutine
---@param fn fun(): any Function to execute asynchronously
---@return any Function return value
function M.run(fn)
    return coroutine_wrap(fn)()
end

--- Non-blocking sleep for specified milliseconds
---@param ms number Sleep duration in milliseconds
function M.sleep(ms)
    local co = assert_coroutine("sleep")
    defer_fn(function()
        safe_resume(co)
    end, ms)
    return coroutine_yield()
end

--- Asynchronous file read using libuv with timeout
---@param path string File path
---@param timeout_ms? integer Optional timeout in milliseconds (uses config if nil)
---@param callback fun(err: string|nil, content: string|nil) Completion callback
function M.read_file_async(path, timeout_ms, callback)
    if type(timeout_ms) == "function" then
        callback = timeout_ms
        timeout_ms = config.async.file_operations.read_timeout -- fallback to config value
    end

    local timer
    local timed_out = false

    if timeout_ms then
        timer = defer_fn(function()
            timed_out = true
            callback("timeout", nil)
        end, timeout_ms)
    end

    uv.fs_open(path, "r", 438, function(open_err, fd)
        if timed_out then
            -- the timeout already resolved the callback; still close the fd we just opened, or it leaks
            if fd then
                uv.fs_close(fd, function() end)
            end
            return
        end
        if timer then
            timer:close()
        end

        if open_err then
            callback(open_err, nil)
            return
        end

        uv.fs_fstat(fd, function(stat_err, stat)
            if timed_out then
                uv.fs_close(fd, function() end) -- close before bailing on the late timeout
                return
            end

            if stat_err then
                uv.fs_close(fd, function()
                    callback(stat_err, nil)
                end)
                return
            end

            uv.fs_read(fd, stat.size, 0, function(read_err, data)
                if timed_out then
                    uv.fs_close(fd, function() end) -- close before bailing on the late timeout
                    return
                end

                uv.fs_close(fd, function()
                    callback(read_err, read_err and nil or data)
                end)
            end)
        end)
    end)
end

--- Async command execution wrapper around vim.system
---@param cmd string[] Command argv (vim.system takes a list, never a shell string)
---@param opts? SystemOpts|function System options or callback
---@param callback? fun(obj: SystemCompleted) Completion callback
function M.system_async(cmd, opts, callback)
    if type(opts) == "function" then
        callback = opts
        opts = {}
    end
    ---@cast opts SystemOpts?
    system(cmd, opts or {}, callback or function() end)
end

--- Retry an async operation with exponential backoff
---@param fn function Async function that accepts a callback
---@param opts? {max_attempts?: integer, base_delay?: integer, max_delay?: integer} (uses config if nil)
---@param ... any Additional arguments for fn
---@return any ... Callback results
---@return string|nil error Last error if all attempts fail
function M.retry(fn, opts, ...)
    opts = opts or {}

    -- Fall back to config values if not provided
    local max_attempts = opts.max_attempts or config.async.defaults.retry_count
    local base_delay = opts.base_delay or config.async.defaults.retry_delay
    local max_delay = opts.max_delay or config.async.defaults.max_retry_delay

    local co = assert_coroutine("retry")
    local args = { ... }
    local arg_count = select("#", ...)
    local attempt = 1

    local function attempt_operation()
        fn(unpack(args, 1, arg_count), function(err, ...)
            if not err or attempt >= max_attempts then
                safe_resume(co, err, ...)
                return
            end

            local delay = math.min(base_delay * (2 ^ (attempt - 1)), max_delay)
            delay = delay * (0.5 + math.random())

            attempt = attempt + 1
            defer_fn(attempt_operation, delay)
        end)
    end

    attempt_operation()
    return coroutine_yield()
end

--- Wait for multiple async operations in parallel (fail-fast)
---@param ... async_task_function Variable number of async tasks
---@return table results Combined results
---@return string|nil error First error encountered
function M.all(...)
    local tasks = { ... }
    local co = assert_coroutine("all")

    if #tasks == 0 then
        return {}, nil
    end

    local results = {}
    local completed = 0
    local has_error = false

    for i, task in ipairs(tasks) do
        schedule(function()
            if has_error then
                return
            end

            task(function(err, ...)
                if has_error then
                    return
                end

                if err then
                    has_error = true
                    safe_resume(co, nil, err)
                    return
                end

                local args = { ... }
                results[i] = #args == 1 and args[1] or args
                completed = completed + 1

                if completed == #tasks then
                    safe_resume(co, results, nil)
                end
            end)
        end)
    end

    return coroutine_yield()
end

--- Wait for multiple async operations with concurrency limit
---@param tasks async_task_function[] List of async tasks
---@param concurrency? integer Maximum concurrent tasks (default: from config)
---@return table results Combined results
---@return string|nil error First error encountered
function M.all_with_limit(tasks, concurrency)
    concurrency = concurrency or config.async.defaults.concurrency -- fallback to config value
    local co = assert_coroutine("all_with_limit")

    if #tasks == 0 then
        return {}, nil
    end

    local results = {}
    local running = 0
    local next_task = 1
    local completed = 0
    local has_error = false

    local function start_next()
        while running < concurrency and next_task <= #tasks and not has_error do
            local task_idx = next_task
            next_task = next_task + 1
            running = running + 1

            schedule(function()
                tasks[task_idx](function(err, ...)
                    if has_error then
                        return
                    end

                    if err then
                        has_error = true
                        safe_resume(co, nil, err)
                        return
                    end

                    running = running - 1
                    completed = completed + 1
                    local args = { ... }
                    results[task_idx] = #args == 1 and args[1] or args

                    if completed == #tasks then
                        safe_resume(co, results, nil)
                    else
                        start_next()
                    end
                end)
            end)
        end
    end

    start_next()
    return coroutine_yield()
end

--- Wait for the first successful async operation
---@param ... async_task_function Variable number of async tasks
---@return any result Result from first successful task
---@return string|nil error Error if all tasks fail
function M.race(...)
    local tasks = { ... }
    local co = assert_coroutine("race")

    if #tasks == 0 then
        return nil, "no tasks provided"
    end

    local completed = false
    local errors = {}
    local err_count = 0 -- a COUNTER, not #errors: out-of-order failures make `errors` sparse and #errors undefined

    for i, task in ipairs(tasks) do
        schedule(function()
            if completed then
                return
            end

            task(function(err, ...)
                if completed then
                    return
                end

                if err then
                    if errors[i] == nil then
                        err_count = err_count + 1
                    end
                    errors[i] = err
                    if err_count == #tasks then
                        safe_resume(co, nil, table.concat(errors, ", "))
                    end
                    return
                end

                completed = true
                local args = { ... }
                safe_resume(co, #args == 1 and args[1] or args, nil)
            end)
        end)
    end

    return coroutine_yield()
end

--- Wait for multiple async operations (collect all results regardless of errors)
---@param ... async_task_function Variable number of async tasks
---@return table[] results List of tuples {err, ...} for each task
function M.all_settled(...)
    local tasks = { ... }
    local co = assert_coroutine("all_settled")

    if #tasks == 0 then
        return {}
    end

    local results = {}
    local completed = 0

    for i, task in ipairs(tasks) do
        schedule(function()
            task(function(err, ...)
                results[i] = { err, ... }
                completed = completed + 1

                if completed == #tasks then
                    safe_resume(co, results)
                end
            end)
        end)
    end

    return coroutine_yield()
end

--- Create a cancellable async operation
---@param fn async_task_function
---@return {start: fun(callback: async_callback), cancel: fun()}
function M.cancellable(fn)
    local cancelled = false

    return {
        start = function(callback)
            if cancelled then
                callback("cancelled", nil)
                return
            end

            fn(function(err, ...)
                if cancelled then
                    callback("cancelled", nil)
                else
                    callback(err, ...)
                end
            end)
        end,
        cancel = function()
            cancelled = true
        end,
    }
end

--- Create a debounced async function
---@param fn function The function to debounce
---@param delay_ms? integer Debounce delay in milliseconds (uses config if nil)
---@return function Debounced function
function M.debounce(fn, delay_ms)
    delay_ms = delay_ms or config.async.debounce.save -- fallback to config value
    local timer

    return function(...)
        local args = { ... }

        if timer then
            pcall(function()
                if timer:is_active() then
                    timer:stop()
                end
                if not timer:is_closing() then
                    timer:close()
                end
            end)
            timer = nil
        end

        timer = defer_fn(function()
            timer = nil
            fn(unpack(args))
        end, delay_ms)
    end
end

--- Create a throttled async function
---@param fn function The function to throttle
---@param limit_ms? integer Throttle limit in milliseconds (uses config if nil)
---@return function Throttled function
function M.throttle(fn, limit_ms)
    limit_ms = limit_ms or config.async.throttle.default_limit -- fallback to config value
    local last_run = 0
    local timeout

    return function(...)
        local args = { ... }
        local now = uv.now()

        if now - last_run >= limit_ms then
            -- Cancel any pending trailing call — it would fire with stale args
            if timeout then
                pcall(function()
                    if timeout:is_active() then
                        timeout:stop()
                    end
                    if not timeout:is_closing() then
                        timeout:close()
                    end
                end)
                timeout = nil
            end
            last_run = now
            fn(unpack(args))
        elseif not timeout then
            local remaining = limit_ms - (now - last_run)
            timeout = defer_fn(function()
                timeout = nil
                last_run = uv.now()
                fn(unpack(args))
            end, remaining)
        end
    end
end

-- Exported so other core modules resume coroutines through the SAME error-rethrow guard instead of a
-- bare coroutine.resume (which swallows a resumed caller's error).
M.safe_resume = safe_resume

return M
