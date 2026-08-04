-- lvim-dependencies.managers.cargo.core.cargo_ops: runs the external `cargo` update/remove
-- process and owns the whole lifecycle around it. It writes the pending Cargo.toml, shows a
-- "working" virtual-text indicator on the package line, records pending state + a line anchor
-- that survives buffer edits, then on the async result either seeds the installed-version
-- cache and refreshes virtual text (success) or restores the original file/buffer (failure).
---@module "lvim-dependencies.managers.cargo.core.cargo_ops"

local state = require("lvim-dependencies.core.state")
local cache = require("lvim-dependencies.core.cache")
local const = require("lvim-dependencies.core.const")
local virtual_text = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_declared = require("lvim-dependencies.core.hub.declared")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local helpers = require("lvim-dependencies.managers.cargo.utils.helpers")
local file_ops = require("lvim-dependencies.managers.cargo.core.file_ops")
local indicators = require("lvim-dependencies.managers.cargo.utils.indicators")
local installed = require("lvim-dependencies.managers.cargo.data.installed")
local parser = require("lvim-dependencies.managers.cargo.parser")
local package_loader = require("lvim-dependencies.core.package_loader")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_FIELDS_DATA = const.CACHE_FIELDS.DATA
local NAMESPACE_VIRTUAL_TEXT = api.nvim_create_namespace(const.NAMESPACES.VIRTUAL_TEXT)

---@class CargoOps
local M = {}

-- ============================================================================
-- Error extraction
-- ============================================================================

---@param res table vim.system result
---@return string
local function extract_cargo_error(res)
    local output = (res.stderr and res.stderr ~= "" and res.stderr)
        or (res.stdout and res.stdout ~= "" and res.stdout)
        or ""

    if output ~= "" then
        for _, line in ipairs(vim.split(output, "\n")) do
            if line:match("^error") or line:match("failed to select") or line:match("version solving failed") then
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

-- ============================================================================
-- Cache management
-- ============================================================================

local function clear_package_cache(name)
    hub_installed.clear_cache("cargo", name)
    debug(string.format("Cleared cache for %s", name), vim.log.levels.DEBUG)
end

local function seed_installed_version(name, version)
    debug(string.format("Cache seed: %s = %s", name, version), vim.log.levels.INFO)

    if utils.clear_file_cache then
        utils.clear_file_cache()
    end

    pcall(installed.clear_cache, name)
    hub_installed.clear_cache("cargo", name)

    local entry = cache.ensure("cargo", CACHE_TYPE_INSTALLED)
    entry[CACHE_FIELDS_DATA][name] = version

    parser.clear_cache()
    hub_declared.clear_cache("cargo", name)
end

-- ============================================================================
-- Executable resolution
-- ============================================================================

local function get_executable(cmd_key)
    local configured = config.cargo and config.cargo.executables and config.cargo.executables[cmd_key]
    if configured then
        local expanded = vim.fn.expand(configured)
        local path = vim.fn.exepath(expanded)
        if path and path ~= "" then
            return path
        end
    end
    local full_path = vim.fn.exepath(cmd_key)
    if full_path and full_path ~= "" then
        return full_path
    end
    if vim.fn.executable(cmd_key) == 1 then
        return cmd_key
    end
    return nil
end

-- ============================================================================
-- Command builders
-- ============================================================================

local function build_update_command(name, version)
    local manifest = helpers.get_manifest()
    if not manifest or not manifest.commands or not manifest.commands.update then
        return nil
    end

    local cargo_cmd = get_executable("cargo")
    local cmd_template = manifest.commands.update.cargo
    if cargo_cmd and cmd_template then
        local cmd = vim.deepcopy(cmd_template)
        cmd[1] = cargo_cmd
        table.insert(cmd, "-p")
        table.insert(cmd, name)
        table.insert(cmd, "--precise")
        table.insert(cmd, version)
        return cmd
    end
    return nil
end

local function build_remove_command(pkg_name)
    local manifest = helpers.get_manifest()
    if not manifest or not manifest.commands or not manifest.commands.remove then
        return nil
    end

    local cargo_cmd = get_executable("cargo")
    local cmd_template = manifest.commands.remove.cargo
    if cargo_cmd and cmd_template then
        local cmd = vim.deepcopy(cmd_template)
        cmd[1] = cargo_cmd
        table.insert(cmd, pkg_name)
        return cmd
    end
    return nil
end

--- Public accessor for the resolved `cargo rm` command (nil if cargo is unavailable).
---@param pkg_name string
---@return string[]|nil
function M.choose_cargo_remove_cmd(pkg_name)
    return build_remove_command(pkg_name)
end

-- ============================================================================
-- Buffer operations
-- ============================================================================

local function find_package_line(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        local pkg = line:match("^%s*([%w%-_]+)%s*=")
        if pkg == name then
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

    virtual_text.display_loading_for_package(bufnr, "cargo", { name = name, line = lnum0 }, "working")
    debug(string.format("Displayed working for %s at line %d", name, lnum0), vim.log.levels.DEBUG)
end

-- ============================================================================
-- Virtual text lifecycle
-- ============================================================================

local function refresh_virtual_text(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end

    package_loader.load_package_data_async("cargo", name, function(package_data)
        if api.nvim_buf_is_valid(bufnr) then
            virtual_text.update_package(bufnr, package_data)
        end
    end, { initial = false })

    indicators.poll_for_outdated(bufnr, name, {
        callback = function()
            indicators.clear_pending_anchor(bufnr)
            if api.nvim_buf_is_valid(bufnr) then
                package_loader.load_package_data_async("cargo", name, function(package_data)
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
    debug(string.format("Operation succeeded for %s@%s", name, version), vim.log.levels.INFO)

    clear_package_cache(name)
    indicators.clear_pending_anchor(bufnr)
    refresh_virtual_text(bufnr, name)
    indicators.trigger_package_updated()

    pcall(function()
        vim.bo[bufnr].modified = false
        vim.bo[bufnr].buflisted = true
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

local function handle_failure(name, err, bufnr, original_lines, path)
    debug(string.format("Operation failed for %s: %s", name, err), vim.log.levels.ERROR)

    if original_lines then
        file_ops.write_lines(path, original_lines)
    end

    if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
        file_ops.force_refresh_buffer(path, original_lines)
        vim.bo[bufnr].modified = false
        state.clear_pending_state(bufnr)
    end

    indicators.clear_pending_anchor(bufnr)
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
        virtual_text.move_virt_texts_only(bufnr)
    end
end

-- ============================================================================
-- Cargo update execution
-- ============================================================================

---@param path string
---@param name string
---@param version string
---@param opts table
---@param callback? fun(result: InstallerResult)
function M.run_cargo_update(path, name, version, opts, callback)
    if not path or path == "" then
        if callback then
            callback({ success = false, message = "Invalid path", packages = {} })
        end
        return
    end

    opts = opts or {}
    local pending_lines = opts.pending_lines
    local change = opts.change
    local original_lines = opts.original_lines

    if not pending_lines then
        if callback then
            callback({ success = false, message = "No pending lines provided", packages = {} })
        end
        return
    end

    local cmd = build_update_command(name, version)
    if not cmd then
        debug("cargo update command not available", vim.log.levels.ERROR)
        if callback then
            callback({ success = false, message = "cargo update command not available", packages = {} })
        end
        return
    end

    debug(string.format("Running cargo update for %s@%s", name, version), vim.log.levels.INFO)

    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(path)

    local ok_write, werr = file_ops.write_lines(path, pending_lines)
    if not ok_write then
        debug(string.format("Write failed: %s", werr), vim.log.levels.ERROR)
        if callback then
            callback({ success = false, message = "Failed to write: " .. tostring(werr), packages = {} })
        end
        return
    end

    if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
        if change then
            file_ops.apply_buffer_change(path, change)
        else
            file_ops.force_refresh_buffer(path, pending_lines)
        end
        vim.bo[bufnr].modified = false
    end

    local lnum0 = find_package_line(bufnr, name)
    if lnum0 then
        display_working(bufnr, name, lnum0)
    end

    local saved_cursor = nil
    if bufnr ~= -1 and api.nvim_get_current_buf() == bufnr then
        saved_cursor = api.nvim_win_get_cursor(0)
    end

    if bufnr ~= -1 then
        -- Use state API — never access _state.buffers directly
        local buf_state = state.get_buffer_state(bufnr)
        buf_state.is_loading = true
        buf_state.pending_dep = name
        buf_state.pending_lnum = lnum0
        buf_state.pending_scope = opts.scope

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
                local error_msg = res and extract_cargo_error(res) or "unknown error"
                handle_failure(name, error_msg, bufnr, original_lines, path)
                if callback then
                    callback({ success = false, message = error_msg, packages = {}, no_retry = true })
                end
            end
        end)
    end)
end

M.extract_cargo_error = extract_cargo_error

return M
