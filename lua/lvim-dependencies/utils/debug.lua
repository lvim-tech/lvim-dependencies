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

-- Rotate the log once it passes this size so an enabled logger can't grow the debug file
-- without bound over a long session. One previous generation is kept as "<file>.1".
local MAX_LOG_BYTES = 5 * 1024 * 1024

-- Kept-open writer state (only ever touched inside vim.schedule). Caching the expanded path,
-- the ensured directory and an OPEN append handle means a message costs one write+flush — not
-- an expand + mkdir + open/close every time, which is what made an enabled logger expensive.
---@class DebugWriter
---@field source string|nil the config.debug.file value the cache was built from
---@field expanded string|nil resolved absolute log path (expanded once)
---@field handle file*|nil append-mode handle kept open across writes
---@field size integer bytes in the current file
local writer = { source = nil, expanded = nil, handle = nil, size = 0 }

--- Close and reset the writer (config change or rotation).
local function reset_writer()
    if writer.handle then
        pcall(function()
            writer.handle:close()
        end)
    end
    writer.handle = nil
    writer.expanded = nil
    writer.size = 0
end

--- Ensure the append handle is open for the current config.debug.file. Runs scheduled (safe).
---@return file*|nil
local function ensure_handle()
    local file = config.debug.file
    if not file or file == "" then
        return nil
    end
    if writer.source ~= file then
        reset_writer()
        writer.source = file
    end
    if not writer.expanded then
        writer.expanded = vim.fn.expand(file)
        file_system.ensure_dir(writer.expanded)
    end
    if not writer.handle then
        writer.handle = io.open(writer.expanded, "a")
        local stat = writer.expanded and vim.uv.fs_stat(writer.expanded)
        writer.size = stat and stat.size or 0
    end
    return writer.handle
end

--- Write log message to debug file (always in scheduled context)
---@param msg string Message to log
---@param level_num integer Log level number
local function write_to_file(msg, level_num)
    local file = config.debug.file
    if not file or file == "" then
        return
    end

    -- Always schedule file operations (fn.expand and file I/O are illegal in a fast event).
    vim.schedule(function()
        local handle = ensure_handle()
        if not handle then
            return
        end
        local log_line = format_log_line(msg, level_num)
        local ok = pcall(function()
            handle:write(log_line)
            handle:flush()
        end)
        if not ok then
            reset_writer()
            return
        end
        writer.size = writer.size + #log_line
        if writer.size >= MAX_LOG_BYTES then
            local path = writer.expanded
            reset_writer()
            if path then
                pcall(os.rename, path, path .. ".1")
            end
        end
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
