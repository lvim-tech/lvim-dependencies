-- lvim-dependencies.managers.cargo.core.file_ops: filesystem + buffer helpers for Cargo.toml.
-- Locates the manifest (upward search), reads/writes its lines, and syncs a loaded buffer to
-- disk changes — either a minimal in-place FileChange or a full refresh — always saving and
-- restoring the cursor and clearing the 'modified' flag so an external write does not leave a
-- dirty buffer.
---@module "lvim-dependencies.managers.cargo.core.file_ops"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")

local debug = utils.debug
local api = vim.api

---@class CargoFileOps
local M = {}

--- Get file patterns from manifest
---@return string[]
local function get_file_patterns()
    local manifest = init.get_manifest("cargo")
    return (manifest and manifest.file_patterns) or { "Cargo.toml" }
end

--- Find Cargo.toml path by searching upward
---@return string|nil
function M.find_cargo_toml_path()
    local patterns = get_file_patterns()
    local cwd = config.cargo and config.cargo.file_ops and config.cargo.file_ops.root_dir or vim.fn.getcwd()

    for _, pattern in ipairs(patterns) do
        local found = vim.fs.find(pattern, { upward = true, path = cwd, type = "file" })
        if found and found[1] then
            debug(string.format("Found Cargo.toml at: %s", found[1]), vim.log.levels.DEBUG)
            return found[1]
        end
    end

    debug("No Cargo.toml file found", vim.log.levels.WARN)
    return nil
end

--- Read file lines safely
---@param path string|nil
---@return string[]|nil
function M.read_lines(path)
    if not path or type(path) ~= "string" or path == "" then
        return nil
    end

    local file = io.open(path, "r")
    if not file then
        return nil
    end
    file:close()

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        debug(string.format("Failed to read file: %s", path), vim.log.levels.WARN)
        return nil
    end

    return lines
end

--- Write lines to file
---@param path string
---@param lines string[]
---@return boolean success
---@return string|nil error
function M.write_lines(path, lines)
    if not path or type(path) ~= "string" or path == "" then
        return false, "Invalid file path"
    end

    if type(lines) ~= "table" then
        return false, "Lines must be a table"
    end

    local dir = vim.fn.fnamemodify(path, ":h")
    if dir and dir ~= "" and dir ~= "." then
        vim.fn.mkdir(dir, "p")
    end

    local ok, res = pcall(vim.fn.writefile, lines, path)
    if not ok then
        return false, tostring(res)
    end

    if res ~= 0 then
        return false, string.format("Write failed with code: %d", res)
    end

    debug(string.format("Successfully wrote %d lines to %s", #lines, path), vim.log.levels.DEBUG)
    return true, nil
end

--- Save cursor position for buffer
---@param bufnr integer
---@return table|nil
local function save_cursor_position(bufnr)
    local cur_buf = api.nvim_get_current_buf()
    if cur_buf ~= bufnr then
        return nil
    end
    return api.nvim_win_get_cursor(0)
end

--- Apply change to buffer
---@param path string
---@param change FileChange|nil
---@return boolean
function M.apply_buffer_change(path, change)
    if not change then
        return false
    end

    if type(change.start0) ~= "number" or type(change.end0) ~= "number" then
        debug("Invalid change object: missing line numbers", vim.log.levels.WARN)
        return false
    end

    local bufnr = vim.fn.bufnr(path)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return false
    end

    local saved_cursor = save_cursor_position(bufnr)

    local start0 = change.start0
    local end0 = change.end0
    local replacement = change.lines or {}

    api.nvim_buf_set_lines(bufnr, start0, end0, false, replacement)

    -- Restore the original cursor position instead of recalculating it.
    if saved_cursor then
        local line_count = api.nvim_buf_line_count(bufnr)
        local row = math.min(saved_cursor[1], line_count)
        pcall(api.nvim_win_set_cursor, 0, { row, saved_cursor[2] })
    end

    vim.bo[bufnr].modified = false

    debug(string.format("Applied change to buffer %d", bufnr), vim.log.levels.DEBUG)
    return true
end

--- Force refresh buffer with new lines
---@param path string
---@param fresh_lines string[]|nil
function M.force_refresh_buffer(path, fresh_lines)
    if type(fresh_lines) ~= "table" then
        return
    end

    local bufnr = vim.fn.bufnr(path)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return
    end

    local saved_cursor = save_cursor_position(bufnr)

    api.nvim_buf_set_lines(bufnr, 0, -1, false, fresh_lines)

    if saved_cursor then
        local line_count = api.nvim_buf_line_count(bufnr)
        local new_row = math.min(saved_cursor[1], line_count)
        api.nvim_win_set_cursor(0, { new_row, saved_cursor[2] })
    end

    vim.bo[bufnr].modified = false
    debug(string.format("Refreshed buffer %d", bufnr), vim.log.levels.DEBUG)
end

--- Check if buffer has unsaved changes
---@param path string
---@return boolean
function M.has_unsaved_changes(path)
    local bufnr = vim.fn.bufnr(path)
    if not bufnr or bufnr == -1 then
        return false
    end
    return vim.bo[bufnr].modified
end

--- Reload buffer from disk
---@param path string
---@return boolean
function M.reload_buffer(path)
    local bufnr = vim.fn.bufnr(path)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return false
    end

    local fresh_lines = M.read_lines(path)
    if not fresh_lines then
        return false
    end

    M.force_refresh_buffer(path, fresh_lines)
    return true
end

return M
