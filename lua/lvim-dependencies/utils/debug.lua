-- lvim-dependencies.utils.debug: the debug logger. It is callable from fast-event context,
-- so it emits the "debug" event synchronously (wrapped in pcall so a bad handler cannot
-- abort the caller) and defers all file I/O and `vim.fn.expand` through `vim.schedule` —
-- those are illegal in a fast event and only run once it is safe.
--
---@module "lvim-dependencies.utils.debug"

local config = require("lvim-dependencies.config")
local file_system = require("lvim-dependencies.utils.file_system")
local levels = require("lvim-dependencies.utils.levels")
local events = require("lvim-dependencies.core.events")

--- Format log line with timestamp and level
---@param msg string Message to log
---@param level_num integer Log level number
---@return string Formatted log line
local function format_log_line(msg, level_num)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local level_name = levels.get_level_name(level_num)
    return string.format("%s [%s] %s\n", timestamp, level_name, tostring(msg))
end

--- Write log message to debug file (always in scheduled context)
---@param msg string Message to log
---@param level_num integer Log level number
local function write_to_file(msg, level_num)
    local file = config.debug.file
    if not file or file == "" then
        return
    end

    -- Always schedule file operations
    vim.schedule(function()
        -- Expand path in scheduled context (safe)
        local fn = vim.fn
        local expanded_file = fn.expand(file)
        local log_line = format_log_line(msg, level_num)

        file_system.ensure_dir(expanded_file)
        file_system.append_line(expanded_file, log_line)
    end)
end

--- Main debug function
---@param msg string Message to log
---@param level string|integer Log level
return function(msg, level)
    -- Emit event first (safe in fast-event context)
    -- Use pcall so a handler error does not abort execution
    pcall(events.emit, "debug", msg, level)

    -- Check if debug logging is enabled
    if not config.debug.enabled then
        return
    end

    -- Check log level threshold
    local min_level = config.debug.min_level or levels.DEBUG
    if not levels.should_show(level, min_level) then
        return
    end

    -- Convert level to number and write to file (always scheduled)
    local level_num = levels.to_level_number(level)
    write_to_file(msg, level_num)
end
