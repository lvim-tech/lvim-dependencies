-- lvim-dependencies/config/async.lua
--- Asynchronous operations configuration
---@class AsyncConfig

return {
    --- Default settings for all async operations
    defaults = {
        concurrency = 10, -- Maximum parallel operations
        timeout = 5000, -- Default timeout in milliseconds
        retry_count = 3, -- Number of retry attempts on failure
        retry_delay = 1000, -- Delay between retries (ms)
        max_retry_delay = 5000, -- Maximum delay for exponential backoff
    },
    --- Package loader specific settings
    package_loader = {
        concurrency = 10, -- Maximum concurrent package loads (default: 10)
        retry_count = 3, -- Number of retry attempts for package loading (default: 3)
        retry_delay = 1000, -- Delay between retry attempts in ms (default: 1000ms)
    },
    --- Executor-specific settings for command execution
    operator = {
        retry_count = 2, -- Number of retry attempts for command execution (default: 2)
        retry_delay = 2000, -- Delay in milliseconds between retry attempts (default: 2000ms)
    },
    --- File operation specific settings
    file_operations = {
        read_timeout = 3000, -- Timeout for file read operations (ms)
    },
    --- Debounce settings (delay execution until activity stops)
    debounce = {
        save = 200, -- Debounce for save events (ms)
        move = 50, -- Debounce for virtual text movement (ms)
    },
    --- Throttle settings (limit execution rate)
    throttle = {
        default_limit = 100, -- Minimum time between executions (ms)
    },
}
