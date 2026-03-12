-- lvim-dependencies/managers/go/core/go_ops.lua
-- Go command execution — owns the full update/remove lifecycle

---@include "core/types.lua"

local state = require("lvim-dependencies.core.state")
local cache = require("lvim-dependencies.core.cache")
local const = require("lvim-dependencies.core.const")
local virtual_text = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local indicators = require("lvim-dependencies.managers.go.utils.indicators")
local parser = require("lvim-dependencies.managers.go.parser")
local package_loader = require("lvim-dependencies.core.package_loader")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_FIELDS_DATA = const.CACHE_FIELDS.DATA
local NAMESPACE_VIRTUAL_TEXT = api.nvim_create_namespace(const.NAMESPACES.VIRTUAL_TEXT)

---@class GoOps
local M = {}

-- ============================================================================
-- Error extraction
-- ============================================================================

---@param res table vim.system result
---@return string
local function extract_go_error(res)
    local output = (res.stderr and res.stderr ~= "" and res.stderr)
        or (res.stdout and res.stdout ~= "" and res.stdout)
        or ""

    if output ~= "" then
        for _, line in ipairs(vim.split(output, "\n")) do
            if
                line:match("^go: ")
                or line:match("no required module provides")
                or line:match("cannot find module")
                or line:match("invalid version")
                or line:match("unknown revision")
            then
                return line
            end
        end
        local last = ""
        for _, line in ipairs(vim.split(output, "\n")) do
            if line:match("%S") then
                last = line
            end
        end
        if last ~= "" then
            return last
        end
    end

    if res.code then
        return string.format("exit code %d", res.code)
    end
    return "unknown error"
end

M.extract_go_error = extract_go_error

-- ============================================================================
-- Cache management
-- ============================================================================

local function clear_package_cache(name)
    hub_installed.clear_cache("go", name)
    hub_latest.clear_cache("go", name)
    debug(string.format("go: cleared cache for %s", name), vim.log.levels.DEBUG)
end

local function seed_installed_version(name, version)
    debug(string.format("go: cache seed %s = %s", name, version), vim.log.levels.INFO)

    hub_installed.clear_cache("go", name)

    local entry = cache.ensure("go", CACHE_TYPE_INSTALLED)
    entry[CACHE_FIELDS_DATA][name] = version

    hub_latest.clear_cache("go", name)
    parser.clear_cache()
    require("lvim-dependencies.core.hub.declared").clear_cache("go", name)
end

-- ============================================================================
-- Executable resolution
-- ============================================================================

local function get_executable()
    local configured = config.go and config.go.executables and config.go.executables.go
    if configured then
        local expanded = vim.fn.expand(configured)
        local path = vim.fn.exepath(expanded)
        if path and path ~= "" then
            return path
        end
    end
    local full_path = vim.fn.exepath("go")
    if full_path and full_path ~= "" then
        return full_path
    end
    if vim.fn.executable("go") == 1 then
        return "go"
    end
    return nil
end

-- ============================================================================
-- Buffer operations
-- ============================================================================

local function find_package_line(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local escaped = vim.pesc(name)
    for i, line in ipairs(lines) do
        if line:match("^%s*" .. escaped .. "%s+v") then
            return i - 1
        end
    end
    return nil
end

local function display_working(bufnr, name, lnum0)
    if not api.nvim_buf_is_valid(bufnr) then
        return
    end

    local extmarks = api.nvim_buf_get_extmarks(bufnr, NAMESPACE_VIRTUAL_TEXT, { lnum0, 0 }, { lnum0, -1 }, {})
    for _, extmark in ipairs(extmarks) do
        pcall(api.nvim_buf_del_extmark, bufnr, NAMESPACE_VIRTUAL_TEXT, extmark[1])
    end

    virtual_text.display_loading_for_package(bufnr, "go", { name = name, line = lnum0 }, "working")
    debug(string.format("go: displayed working for %s at line %d", name, lnum0), vim.log.levels.DEBUG)
end

-- ============================================================================
-- Virtual text lifecycle
-- ============================================================================

local function refresh_virtual_text(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end

    package_loader.load_package_data_async("go", name, function(package_data)
        if api.nvim_buf_is_valid(bufnr) then
            virtual_text.update_package(bufnr, package_data)
        end
    end, { initial = false })

    indicators.poll_for_outdated(bufnr, name, {
        callback = function()
            indicators.clear_pending_anchor(bufnr)
            if api.nvim_buf_is_valid(bufnr) then
                package_loader.load_package_data_async("go", name, function(package_data)
                    if api.nvim_buf_is_valid(bufnr) then
                        virtual_text.update_package(bufnr, package_data)
                    end
                end, { initial = false })
            end
        end,
    })
end

-- ============================================================================
-- Success / failure handlers
-- ============================================================================

local function handle_success(name, version, bufnr, saved_cursor)
    debug(string.format("go: succeeded for %s@%s", name, version), vim.log.levels.INFO)

    clear_package_cache(name)
    indicators.clear_pending_anchor(bufnr)
    refresh_virtual_text(bufnr, name)
    indicators.trigger_package_updated()

    pcall(function()
        vim.bo[bufnr].modified = false
        api.nvim_buf_call(bufnr, function()
            vim.cmd("checktime")
        end)
    end)

    if saved_cursor and api.nvim_buf_is_valid(bufnr) and api.nvim_get_current_buf() == bufnr then
        local line_count = api.nvim_buf_line_count(bufnr)
        local target_line = math.min(saved_cursor[1], line_count)
        pcall(api.nvim_win_set_cursor, 0, { target_line, saved_cursor[2] })
    end
end

local function handle_failure(name, err, bufnr)
    debug(string.format("go: failed for %s: %s", name, err), vim.log.levels.ERROR)
    indicators.clear_pending_anchor(bufnr)
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
        virtual_text.move_virt_texts_only(bufnr)
    end
end

-- ============================================================================
-- Public: run update
-- ============================================================================

---@param path string  Path to go.mod
---@param name string
---@param version string
---@param opts table
---@param callback? fun(result: InstallerResult)
function M.run_go_update(path, name, version, opts, callback)
    opts = opts or {}

    local exe = get_executable()
    if not exe then
        if callback then
            callback({ success = false, message = "go not found", packages = {} })
        end
        return
    end

    -- go get pkg@version
    local pkg_spec = name .. "@" .. version
    local cmd = { exe, "get", pkg_spec }
    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(M.find_go_mod_path() or path)

    debug(string.format("go: %s", table.concat(cmd, " ")), vim.log.levels.INFO)

    local lnum0 = find_package_line(bufnr, name)
    if lnum0 then
        display_working(bufnr, name, lnum0)
    end

    local saved_cursor = nil
    if bufnr ~= -1 and api.nvim_get_current_buf() == bufnr then
        saved_cursor = api.nvim_win_get_cursor(0)
    end

    if bufnr ~= -1 then
        local buf_state = state.get_buffer_state(bufnr)
        buf_state.is_loading = true
        buf_state.pending_dep = name
        buf_state.pending_lnum = lnum0
        indicators.clear_pending_anchor(bufnr)
        if lnum0 then
            buf_state.pending_anchor_id = indicators.set_pending_anchor(bufnr, lnum0 + 1)
        end
    end

    local callback_called = false
    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            if callback_called then
                return
            end
            callback_called = true

            if res and res.code == 0 then
                seed_installed_version(name, version)
                handle_success(name, version, bufnr, saved_cursor)
                vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
                if callback then
                    callback({
                        success = true,
                        message = string.format("updated %s@%s", name, version),
                        packages = { name },
                    })
                end
            else
                local err_msg = res and extract_go_error(res) or "unknown error"
                handle_failure(name, err_msg, bufnr)
                if callback then
                    callback({ success = false, message = err_msg, packages = {}, no_retry = true })
                end
            end
        end)
    end)
end

-- ============================================================================
-- Public: run remove
-- ============================================================================

---@param path string
---@param name string
---@param opts table
---@param callback? fun(result: InstallerResult)
function M.run_go_remove(path, name, opts, callback)
    opts = opts or {}

    local exe = get_executable()
    if not exe then
        if callback then
            callback({ success = false, message = "go not found", packages = {} })
        end
        return
    end

    -- go get pkg@none removes the dependency
    local cmd = { exe, "get", name .. "@none" }
    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(path)

    debug(string.format("go: %s", table.concat(cmd, " ")), vim.log.levels.INFO)

    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            if res and res.code == 0 then
                parser.clear_cache()
                hub_installed.clear_cache("go", name)
                hub_latest.clear_cache("go", name)
                if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
                    virtual_text.remove_package(bufnr, name)
                    local buf_state = state.get_buffer_state(bufnr)
                    buf_state.skip_next_check = true
                    vim.bo[bufnr].modified = false
                    api.nvim_buf_call(bufnr, function()
                        vim.cmd("checktime")
                    end)
                end
                indicators.trigger_package_updated()
                if callback then
                    callback({ success = true, message = "removed " .. name, packages = { name } })
                end
            else
                local err_msg = res and extract_go_error(res) or "unknown error"
                if callback then
                    callback({ success = false, message = err_msg, packages = {}, no_retry = true })
                end
            end
        end)
    end)
end

---@return string|nil
function M.find_go_mod_path()
    return require("lvim-dependencies.managers.go.core.file_ops").find_go_mod_path()
end

return M
