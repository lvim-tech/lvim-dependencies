-- lvim-dependencies.managers.go.core.file_ops: low-level go.mod file I/O — locating the
-- nearest go.mod, reading/writing it as line arrays, and pushing edits back into an already
-- loaded buffer. Buffer writes always reset 'modified' so the in-editor copy stays in sync
-- with the on-disk file that `go get` rewrote, without prompting the user about changes.
--
---@module "lvim-dependencies.managers.go.core.file_ops"

local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")

local debug = utils.debug
local api = vim.api

---@class GoFileOps
local M = {}

-- ============================================================================
-- Path resolution
-- ============================================================================

---@return string|nil
function M.find_go_mod_path()
    local root_dir = config.go and config.go.file_ops and config.go.file_ops.root_dir
    local search = root_dir and vim.fn.expand(root_dir) or vim.fn.getcwd()

    local found = vim.fs.find("go.mod", { upward = true, path = search, type = "file" })
    return found and found[1] or nil
end

-- ============================================================================
-- File I/O
-- ============================================================================

---@param path string
---@return string[]|nil, string|nil
function M.read_lines(path)
    local f = io.open(path, "r")
    if not f then
        return nil, "cannot open " .. path
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines, nil
end

---@param path string
---@param lines string[]
---@return boolean, string|nil
function M.write_lines(path, lines)
    local f = io.open(path, "w")
    if not f then
        return false, "cannot write " .. path
    end
    for _, line in ipairs(lines) do
        f:write(line .. "\n")
    end
    f:close()
    debug(string.format("go: wrote %d lines to %s", #lines, path), vim.log.levels.DEBUG)
    return true, nil
end

-- ============================================================================
-- Buffer refresh
-- ============================================================================

---@param path string
---@param lines string[]
function M.force_refresh_buffer(path, lines)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return
    end

    local ok = pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    if ok then
        vim.bo[bufnr].modified = false
        debug(string.format("go: force refreshed buffer %d", bufnr), vim.log.levels.DEBUG)
    end
end

---@param path string
---@param change table  {lnum: integer, new_line: string}
function M.apply_buffer_change(path, change)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return
    end
    if not change or not change.lnum or not change.new_line then
        return
    end

    local line_count = api.nvim_buf_line_count(bufnr)
    if change.lnum < line_count then
        pcall(api.nvim_buf_set_lines, bufnr, change.lnum, change.lnum + 1, false, { change.new_line })
        vim.bo[bufnr].modified = false
    end
end

return M
