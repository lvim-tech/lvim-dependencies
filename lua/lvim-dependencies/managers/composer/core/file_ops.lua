-- lvim-dependencies.managers.composer.core.file_ops: locate and read/write composer.json on
-- disk, and keep the open buffer in sync after a write. Writes go to the file first; the
-- buffer is then patched in place (apply_buffer_change) or hard-refreshed, and marked
-- unmodified so nvim does not raise a "file changed" prompt.
--
---@module "lvim-dependencies.managers.composer.core.file_ops"

local utils = require("lvim-dependencies.utils")
local project = require("lvim-dependencies.core.project")

local debug = utils.debug

---@class ComposerFileOps
local M = {}

--- composer.json searched upward from `bufnr`'s directory, else from the current manifest's
--- project (core.project.current_root — config root_dir, the current buffer when it is a
--- composer.json, else cwd).
---@param bufnr? integer
---@return string|nil
function M.find_composer_json_path(bufnr)
    local start_path = project.buffer_root(bufnr) or project.current_root("composer")

    local found = vim.fs.find("composer.json", {
        upward = true,
        path = start_path,
        type = "file",
    })
    return found and found[1] or nil
end

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
    f:write("\n")
    f:close()
    return true, nil
end

---@param path string
---@param change FileChange
function M.apply_buffer_change(path, change)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    pcall(vim.api.nvim_buf_set_lines, bufnr, change.start0, change.end0, false, change.lines)
    vim.bo[bufnr].modified = false
end

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
