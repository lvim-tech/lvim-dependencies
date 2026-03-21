-- lvim-dependencies/managers/pubspec/core/pub_ops.lua
-- Pub/Dart command execution — owns the full install lifecycle

---@include "core/types.lua"

local state = require("lvim-dependencies.core.state")
local cache = require("lvim-dependencies.core.cache")
local const = require("lvim-dependencies.core.const")
local virtual_text = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")

local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local helpers = require("lvim-dependencies.managers.pubspec.utils.helpers")
local file_ops = require("lvim-dependencies.managers.pubspec.core.file_ops")
local indicators = require("lvim-dependencies.managers.pubspec.utils.indicators")
local installed = require("lvim-dependencies.managers.pubspec.data.installed")
local parser = require("lvim-dependencies.managers.pubspec.parser")
local package_loader = require("lvim-dependencies.core.package_loader")

local debug = utils.debug
local api = vim.api

-- ============================================================================
-- Constants
-- ============================================================================
local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_FIELDS_DATA = const.CACHE_FIELDS.DATA
local NAMESPACE_VIRTUAL_TEXT = api.nvim_create_namespace(const.NAMESPACES.VIRTUAL_TEXT)

---@class PubspecPubOps
local M = {}

-- ============================================================================
-- Error extraction
-- ============================================================================

--- Extract the most meaningful error message from a pub CLI result.
--- pub/flutter write the actual reason on lines starting with "Because",
--- "Error:", or similar — not on the first line ("Resolving dependencies...").
---@param res table vim.system result
---@return string
local function extract_pub_error(res)
    -- Prefer stderr; fall back to stdout (dart pub get writes some errors there)
    local output = (res.stderr and res.stderr ~= "" and res.stderr)
        or (res.stdout and res.stdout ~= "" and res.stdout)
        or ""

    if output ~= "" then
        -- Priority: lines that carry the real reason
        for _, line in ipairs(vim.split(output, "\n")) do
            if line:match("^Error:") or line:match("^Because ") or line:match("version solving failed") then
                return line
            end
        end
        -- Fall back to last non-empty line (usually the summary)
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

---@param name string
local function clear_package_cache(name)
    hub_installed.clear_cache("pubspec", name)
    debug(string.format("Cleared cache for %s", name), vim.log.levels.DEBUG)
end

---@param name string
---@param version string
local function seed_installed_version(name, version)
    debug(string.format("Cache seed: %s = %s", name, version), vim.log.levels.INFO)

    if utils.clear_file_cache then
        utils.clear_file_cache()
    end

    pcall(installed.clear_cache, name)

    hub_installed.clear_cache("pubspec", name)
    local entry = cache.ensure("pubspec", CACHE_TYPE_INSTALLED)
    entry[CACHE_FIELDS_DATA][name] = version

    parser.clear_cache()
    require("lvim-dependencies.core.hub.declared").clear_cache("pubspec", name)
end

-- ============================================================================
-- Executable resolution
-- ============================================================================

---@param cmd_key string
---@return string|nil
local function get_executable(cmd_key)
    -- Get from config.pubspec.executables first
    local configured = config.pubspec and config.pubspec.executables and config.pubspec.executables[cmd_key]
    if configured then
        -- Expand ~ to home directory
        local expanded = vim.fn.expand(configured)
        local path = vim.fn.exepath(expanded)
        if path and path ~= "" then
            return path
        end
    end

    -- Try full path from exepath
    local full_path = vim.fn.exepath(cmd_key)
    if full_path and full_path ~= "" then
        return full_path
    end

    -- Check if executable in PATH
    if vim.fn.executable(cmd_key) == 1 then
        return cmd_key
    end

    return nil
end

-- ============================================================================
-- Project type detection
-- ============================================================================

---@param pubspec_path string
---@return boolean
function M.has_flutter(pubspec_path)
    local lines = file_ops.read_lines(pubspec_path)
    if not lines then
        return false
    end

    local manifest = helpers.get_manifest()
    if not manifest then
        return false
    end

    local flutter_pattern = (manifest.project_type_detectors and manifest.project_type_detectors.flutter)
        or "^%s*flutter%s*:"

    for _, line in ipairs(lines) do
        if line:match(flutter_pattern) then
            return true
        end
    end

    return false
end

-- ============================================================================
-- Command builders
-- ============================================================================

---@param pubspec_path string
---@return string[]|nil
local function build_get_command(pubspec_path)
    local manifest = helpers.get_manifest()
    if not manifest or not manifest.commands or not manifest.commands.get then
        return nil
    end

    if M.has_flutter(pubspec_path) then
        local flutter_cmd = get_executable("flutter")
        local cmd_template = manifest.commands.get.flutter
        if flutter_cmd and cmd_template then
            local cmd = vim.deepcopy(cmd_template)
            cmd[1] = flutter_cmd
            return cmd
        end
    end

    local dart_cmd = get_executable("dart")
    local cmd_template = manifest.commands.get.dart
    if dart_cmd and cmd_template then
        local cmd = vim.deepcopy(cmd_template)
        cmd[1] = dart_cmd
        return cmd
    end

    return nil
end

---@param pubspec_path string
---@param pkg_name string
---@return string[]|nil
local function build_remove_command(pubspec_path, pkg_name)
    local manifest = helpers.get_manifest()
    if not manifest or not manifest.commands or not manifest.commands.remove then
        return nil
    end

    if M.has_flutter(pubspec_path) then
        local flutter_cmd = get_executable("flutter")
        local cmd_template = manifest.commands.remove.flutter
        if flutter_cmd and cmd_template then
            local cmd = vim.deepcopy(cmd_template)
            cmd[1] = flutter_cmd
            table.insert(cmd, pkg_name)
            return cmd
        end
    end

    local dart_cmd = get_executable("dart")
    local cmd_template = manifest.commands.remove.dart
    if dart_cmd and cmd_template then
        local cmd = vim.deepcopy(cmd_template)
        cmd[1] = dart_cmd
        table.insert(cmd, pkg_name)
        return cmd
    end

    return nil
end

---@param pubspec_path string
---@param pkg_name string
---@return string[]|nil
function M.choose_pub_remove_cmd(pubspec_path, pkg_name)
    return build_remove_command(pubspec_path, pkg_name)
end

-- ============================================================================
-- Buffer operations
-- ============================================================================

---@param bufnr integer
---@param name string
---@return integer|nil
local function find_package_line(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
        local pkg = line:match("^%s*([^%s:]+)%s*:")
        if pkg == name then
            return i - 1
        end
    end

    return nil
end

---@param bufnr integer
---@param name string
---@param lnum0 integer
local function display_working(bufnr, name, lnum0)
    if not api.nvim_buf_is_valid(bufnr) then
        return
    end

    local extmarks = api.nvim_buf_get_extmarks(bufnr, NAMESPACE_VIRTUAL_TEXT, { lnum0, 0 }, { lnum0, -1 }, {})
    for _, extmark in ipairs(extmarks) do
        pcall(api.nvim_buf_del_extmark, bufnr, NAMESPACE_VIRTUAL_TEXT, extmark[1])
    end

    virtual_text.display_loading_for_package(bufnr, "pubspec", {
        name = name,
        line = lnum0,
    }, "working")

    debug(string.format("Displayed working for %s at line %d", name, lnum0), vim.log.levels.DEBUG)
end

-- ============================================================================
-- Virtual text lifecycle
-- ============================================================================

---@param bufnr integer
---@param name string
local function refresh_virtual_text(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end

    virtual_text.move_virt_texts_only(bufnr)

    package_loader.load_package_data_async("pubspec", name, function(package_data)
        if api.nvim_buf_is_valid(bufnr) then
            virtual_text.update_package(bufnr, package_data)
        end
    end, { initial = false })

    indicators.poll_for_outdated(bufnr, name, function()
        indicators.clear_pending_anchor(bufnr)
        if api.nvim_buf_is_valid(bufnr) then
            virtual_text.move_virt_texts_only(bufnr)
            package_loader.load_package_data_async("pubspec", name, function(package_data)
                if api.nvim_buf_is_valid(bufnr) then
                    virtual_text.update_package(bufnr, package_data)
                end
            end, { initial = false })
        end
    end)
end

-- ============================================================================
-- Success / failure handlers
-- ============================================================================

---@param name string
---@param version string
---@param bufnr integer
---@param saved_cursor table|nil
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

    -- Restore cursor position if this buffer is still the current one
    if saved_cursor and api.nvim_buf_is_valid(bufnr) and api.nvim_get_current_buf() == bufnr then
        local line_count = api.nvim_buf_line_count(bufnr)
        local target_line = math.min(saved_cursor[1], line_count)
        pcall(api.nvim_win_set_cursor, 0, { target_line, saved_cursor[2] })
    end
end

---@param name string
---@param err string
---@param bufnr integer
---@param original_lines string[]|nil
---@param path string
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
        -- Restore virtual text from cache — clears is_transient so "Working..." disappears
        package_loader.load_package_data_async("pubspec", name, function(package_data)
            if api.nvim_buf_is_valid(bufnr) then
                virtual_text.update_package(bufnr, package_data)
            end
        end, { initial = false })
    end
end

-- ============================================================================
-- Pub get execution
-- ============================================================================

---@param path string
---@param name string
---@param version string
---@param opts table
---@param callback? fun(result: InstallerResult)
function M.run_pub_get(path, name, version, opts, callback)
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

    local cmd = build_get_command(path)
    if not cmd then
        debug("No flutter/dart CLI available", vim.log.levels.ERROR)
        if callback then
            callback({ success = false, message = "Neither flutter nor dart CLI available", packages = {} })
        end
        return
    end

    debug(string.format("Running pub get for %s@%s", name, version), vim.log.levels.INFO)

    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(path)

    -- Save cursor position before any buffer modifications
    local saved_cursor = nil
    if bufnr ~= -1 and api.nvim_get_current_buf() == bufnr then
        saved_cursor = api.nvim_win_get_cursor(0)
    end

    -- Write file without backup/formatting
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

    if bufnr ~= -1 then
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
                        message = string.format("installed %s@%s", name, version),
                        packages = { name },
                    })
                end
            else
                local error_msg = res and extract_pub_error(res) or "unknown error"

                handle_failure(name, error_msg, bufnr, original_lines, path)

                if callback then
                    -- pub get failures are deterministic (dependency conflicts, SDK mismatch…)
                    -- retrying the same operation will produce the same error, so flag no_retry
                    callback({ success = false, message = error_msg, packages = {}, no_retry = true })
                end
            end
        end)
    end)
end

M.extract_pub_error = extract_pub_error

return M
