-- lvim-dependencies.managers.npm.core.file_ops: filesystem + buffer plumbing for package.json.
-- Resolves the manifest path (configured root, else buffer dir, else cwd, searched upward),
-- reads/writes it as lines or a whole string (preserving a trailing newline), and syncs edits
-- back into the live Neovim buffer — either a minimal line-range change or a full reload — while
-- clearing 'modified' so the write does not look like an unsaved user edit.
--
---@module "lvim-dependencies.managers.npm.core.file_ops"

local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class NpmFileOps
local M = {}

-- ============================================================================
-- Path resolution
-- ============================================================================

--- Find package.json by searching upward from cwd or configured root
---@param bufnr? integer
---@return string|nil
function M.find_package_json_path(bufnr)
    local start_path

    local root_dir = config.npm and config.npm.file_ops and config.npm.file_ops.root_dir
    if root_dir then
        start_path = vim.fn.expand(root_dir)
    elseif bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        local buf_path = vim.api.nvim_buf_get_name(bufnr)
        if buf_path ~= "" then
            start_path = vim.fn.fnamemodify(buf_path, ":h")
        end
    else
        start_path = vim.fn.getcwd()
    end

    local found = vim.fs.find("package.json", {
        upward = true,
        path = start_path,
        type = "file",
    })
    return found and found[1] or nil
end

-- ============================================================================
-- Read / Write
-- ============================================================================

--- Read all lines from a file
---@param path string
---@return string[]|nil
function M.read_lines(path)
    local f = io.open(path, "r")
    if not f then
        debug(string.format("Cannot open file: %s", path), vim.log.levels.WARN)
        return nil
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

--- Read full file content as string
---@param path string
---@return string|nil
function M.read_content(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- Write lines to a file
---@param path string
---@param lines string[]
---@return boolean ok
---@return string|nil err
function M.write_lines(path, lines)
    local f, err = io.open(path, "w")
    if not f then
        debug(string.format("Cannot write file %s: %s", path, tostring(err)), vim.log.levels.ERROR)
        return false, err
    end
    f:write(table.concat(lines, "\n"))
    -- Preserve trailing newline
    f:write("\n")
    f:close()
    debug(string.format("Written %d lines to %s", #lines, path), vim.log.levels.DEBUG)
    return true, nil
end

--- Write content string to a file
---@param path string
---@param content string
---@return boolean ok
---@return string|nil err
function M.write_content(path, content)
    local f, err = io.open(path, "w")
    if not f then
        debug(string.format("Cannot write file %s: %s", path, tostring(err)), vim.log.levels.ERROR)
        return false, err
    end
    f:write(content)
    f:close()
    return true, nil
end

-- ============================================================================
-- Buffer sync
-- ============================================================================

--- Apply a minimal line-range change to the Neovim buffer
---@param path string
---@param change FileChange
function M.apply_buffer_change(path, change)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, change.start0, change.end0, false, change.lines)
    if ok then
        vim.bo[bufnr].modified = false
        debug(string.format("Applied buffer change at lines %d-%d", change.start0, change.end0), vim.log.levels.DEBUG)
    end
end

--- Force reload buffer from disk (when line-range change is not possible)
---@param path string
---@param lines? string[]
function M.force_refresh_buffer(path, lines)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
        return
    end

    if lines then
        pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    else
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! checktime")
        end)
    end
    vim.bo[bufnr].modified = false
end

return M
