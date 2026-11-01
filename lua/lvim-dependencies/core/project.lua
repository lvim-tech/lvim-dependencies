-- lvim-dependencies.core.project: where a manager's manifest and lock files are looked for.
-- Every lookup used to start at the current working directory, so a manifest opened outside
-- the cwd project — or a sub-package of a workspace / monorepo (cargo workspace members,
-- npm/pnpm workspaces, melos packages, go multi-module repos) — read the ROOT project's
-- manifest instead of its own: wrong declared versions, wrong lock, or nothing at all. The
-- buffer that triggered the work knows its own directory, so that directory is the search
-- root; the explicit `config.<manager>.file_ops.root_dir` still wins, and the cwd is only the
-- last resort (no buffer in hand).
--
---@module "lvim-dependencies.core.project"

local api = vim.api

local M = {}

--- The configured root override for a manager (`config.<manager>.file_ops.root_dir`), expanded.
---@param manager_type string
---@return string|nil
local function configured_root(manager_type)
    local config = require("lvim-dependencies.config")
    local mgr = config[manager_type]
    local root_dir = type(mgr) == "table" and type(mgr.file_ops) == "table" and mgr.file_ops.root_dir or nil
    if type(root_dir) == "string" and root_dir ~= "" then
        return vim.fn.expand(root_dir)
    end
    return nil
end

--- Directory of a buffer's file, or nil for an unnamed / invalid buffer.
---@param bufnr integer|nil
---@return string|nil
function M.buffer_root(bufnr)
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local name = api.nvim_buf_get_name(bufnr)
    if name == "" then
        return nil
    end
    return vim.fs.dirname(name)
end

--- Directory to start a manifest / lock search from: the configured root_dir, else the
--- explicit `opts.root`, else the directory of `opts.bufnr`, else `current_root`: a caller that
--- names no buffer means the manifest being edited, which in a sub-project is not the cwd's.
---@param manager_type string
---@param opts? { root?: string, bufnr?: integer }
---@return string
function M.search_root(manager_type, opts)
    local configured = configured_root(manager_type)
    if configured then
        return configured
    end
    if opts then
        if type(opts.root) == "string" and opts.root ~= "" then
            return opts.root
        end
        local from_buf = M.buffer_root(opts.bufnr)
        if from_buf then
            return from_buf
        end
    end
    return M.current_root(manager_type)
end

--- Search root for an action taken "in the current manifest": the configured root_dir, else
--- the directory of the current buffer when it IS one of this manager's manifest files, else
--- the cwd. Used by the api / helpers layer (update, delete, version lookups), which acts on
--- the buffer the user is editing.
---@param manager_type string
---@return string
function M.current_root(manager_type)
    local configured = configured_root(manager_type)
    if configured then
        return configured
    end
    local buf = api.nvim_get_current_buf()
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" then
        local registry = require("lvim-dependencies.core.registry")
        if registry.determine_manifest_type(name) == manager_type then
            return vim.fs.dirname(name)
        end
    end
    return vim.fn.getcwd()
end

--- The dependency section holding the declaration under the cursor in `path`'s window, when the
--- cursor is on one. A package may be declared in several sections and only the line says which
--- one is meant. The manifest's own window is asked, since a picker may be current by now.
---@param path string
---@param sections string[]
---@param locate fun(lines: string[], section: string): integer|nil, integer|nil  1-indexed block
---@return string|nil
function M.section_at_cursor(path, sections, locate)
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return nil
    end
    local win = api.nvim_win_get_buf(0) == bufnr and api.nvim_get_current_win() or vim.fn.bufwinid(bufnr)
    if win == -1 then
        return nil
    end
    local row = api.nvim_win_get_cursor(win)[1]
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for _, section in ipairs(sections) do
        local first, last = locate(lines, section)
        if first and last and first <= row and row <= last then
            return section
        end
    end
    return nil
end

return M
