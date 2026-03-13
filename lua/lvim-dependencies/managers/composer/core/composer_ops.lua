-- lvim-dependencies/managers/composer/core/composer_ops.lua
-- composer require/remove command execution

---@include "core/types.lua"

local state = require("lvim-dependencies.core.state")
local cache = require("lvim-dependencies.core.cache")
local const = require("lvim-dependencies.core.const")
local virtual_text = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local file_ops = require("lvim-dependencies.managers.composer.core.file_ops")
local indicators = require("lvim-dependencies.managers.composer.utils.indicators")
local parser = require("lvim-dependencies.managers.composer.parser")
local package_loader = require("lvim-dependencies.core.package_loader")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_FIELDS_DATA = const.CACHE_FIELDS.DATA

---@class ComposerOps
local M = {}

-- ============================================================================
-- Error extraction
-- ============================================================================

---@param res table vim.system result
---@return string
local function extract_composer_error(res)
    local output = (res.stderr and res.stderr ~= "" and res.stderr)
        or (res.stdout and res.stdout ~= "" and res.stdout)
        or ""

    if output ~= "" then
        for _, line in ipairs(vim.split(output, "\n")) do
            if
                line:match("%[RuntimeException%]")
                or line:match("%[SolverProblemsException%]")
                or line:match("^  Problem")
                or line:match("could not be resolved")
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

local function clear_package_cache(name)
    hub_installed.clear_cache("composer", name)
    hub_latest.clear_cache("composer", name)
end

local function seed_installed_version(name, version)
    hub_installed.clear_cache("composer", name)
    local entry = cache.ensure("composer", CACHE_TYPE_INSTALLED)
    entry[CACHE_FIELDS_DATA][name] = version
    parser.clear_cache()
    require("lvim-dependencies.core.hub.declared").clear_cache("composer", name)
end

local function get_executable()
    local configured = config.composer and config.composer.executables and config.composer.executables.composer
    if configured then
        local expanded = vim.fn.expand(configured)
        local path = vim.fn.exepath(expanded)
        if path and path ~= "" then
            return path
        end
    end
    local full_path = vim.fn.exepath("composer")
    if full_path and full_path ~= "" then
        return full_path
    end
    if vim.fn.executable("composer") == 1 then
        return "composer"
    end
    return nil
end

function M.build_require_cmd(exe, name, version, section)
    local pkg_spec = name .. ":" .. version
    local cmd = { exe, "require", pkg_spec }
    if section == "require-dev" then
        table.insert(cmd, "--dev")
    end
    return cmd
end

function M.build_remove_cmd(exe, name)
    return { exe, "remove", name }
end

local function find_package_line_in_buf(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local escaped = vim.pesc(name)
    local pattern = string.format('^%%s*"%s"%%s*:', escaped)
    for i, line in ipairs(lines) do
        if line:match(pattern) then
            return i - 1
        end
    end
    return nil
end

local function is_platform_package(name)
    local manifest = require("lvim-dependencies.managers.composer.manifest")
    return not manifest.is_package_actionable(name)
end

local function display_working(bufnr, name, lnum0)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    if not lnum0 then
        return
    end
    virtual_text.display_loading_for_package(bufnr, "composer", { name = name, line = lnum0 }, "working")
    debug(string.format("Displayed working for %s at line %d", name, lnum0), vim.log.levels.DEBUG)
end

local function refresh_virtual_text(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    -- Platform packages have no latest version — skip refresh to preserve existing VT
    if is_platform_package(name) then
        return
    end
    package_loader.load_package_data_async("composer", name, function(package_data)
        if api.nvim_buf_is_valid(bufnr) then
            virtual_text.update_package(bufnr, package_data)
        end
    end, { initial = false })
    indicators.poll_for_outdated(bufnr, name, {
        callback = function()
            indicators.clear_pending_anchor(bufnr)
            if api.nvim_buf_is_valid(bufnr) then
                package_loader.load_package_data_async("composer", name, function(package_data)
                    if api.nvim_buf_is_valid(bufnr) then
                        virtual_text.update_package(bufnr, package_data)
                    end
                end, { initial = false })
            end
        end,
    })
end

local function handle_success(name, version, bufnr, saved_cursor)
    debug(string.format("composer: successfully updated %s to %s", name, version), vim.log.levels.INFO)
    clear_package_cache(name)
    indicators.clear_pending_anchor(bufnr)
    refresh_virtual_text(bufnr, name)
    indicators.trigger_package_updated()

    pcall(function()
        vim.bo[bufnr].modified = false
        local buf_state = state.get_buffer_state(bufnr)
        buf_state.skip_next_check = true
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
    debug(string.format("composer: failed for %s: %s", name, err), vim.log.levels.ERROR)
    indicators.clear_pending_anchor(bufnr)
    -- Restore virtual text to pre-update state
    refresh_virtual_text(bufnr, name)
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
        virtual_text.move_virt_texts_only(bufnr)
    end
end

function M.run_composer_update(path, name, version, opts, callback)
    opts = opts or {}

    local exe = get_executable()
    if not exe then
        if callback then
            callback({ success = false, message = "composer not found", packages = {} })
        end
        return
    end

    local all_deps = parser.get_dependencies()
    local pkg_raw = all_deps[name]
    local section = (pkg_raw and pkg_raw.section)
        or (config.composer and config.composer.sections and config.composer.sections.default)
        or "require"

    local cmd = M.build_require_cmd(exe, name, version, section)
    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(file_ops.find_composer_json_path() or path)

    debug(string.format("composer: %s", table.concat(cmd, " ")), vim.log.levels.INFO)

    local lnum0 = find_package_line_in_buf(bufnr, name)

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
            display_working(bufnr, name, lnum0)
        end
    end

    local callback_called = false
    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            if callback_called then
                return
            end
            callback_called = true

            local code = res and res.code or -1
            local stderr = (res and res.stderr) or ""
            local stdout = (res and res.stdout) or ""

            -- composer may exit non-zero due to PHP Warnings while the update succeeded.
            -- Treat as success if exit=0 OR if stderr contains only PHP Warnings.
            local only_warnings = code ~= 0
                and not stderr:match("[Ee]rror")
                and not stderr:match("[Ff]atal")
                and not stderr:match("[Ee]xception")
                and not stderr:match("Your requirements could not be resolved")
                and not stderr:match("Installation failed")
            debug(string.format("composer: stderr_first_200=%s", stderr:sub(1, 200)), vim.log.levels.DEBUG)
            debug(
                string.format(
                    "composer: has_requirements=%s has_installation=%s",
                    tostring(stderr:match("Your requirements could not be resolved") ~= nil),
                    tostring(stderr:match("Installation failed") ~= nil)
                ),
                vim.log.levels.DEBUG
            )

            if code == 0 or only_warnings then
                if only_warnings then
                    debug(
                        string.format("composer: non-zero exit for %s but only warnings — treating as success", name),
                        vim.log.levels.WARN
                    )
                end
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
                local err_msg = extract_composer_error(res)
                handle_failure(name, err_msg, bufnr)
                if callback then
                    callback({ success = false, message = err_msg, packages = {}, no_retry = true })
                end
            end
        end)
    end)
end

function M.run_composer_remove(path, name, opts, callback)
    opts = opts or {}

    local exe = get_executable()
    if not exe then
        if callback then
            callback({ success = false, message = "composer not found", packages = {} })
        end
        return
    end

    local cmd = M.build_remove_cmd(exe, name)
    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(file_ops.find_composer_json_path() or path)

    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            local code = res and res.code or -1
            local stderr = (res and res.stderr) or ""

            if code == 0 then
                parser.clear_cache()
                hub_installed.clear_cache("composer", name)
                hub_latest.clear_cache("composer", name)
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
                local err_msg = extract_composer_error(res)
                if callback then
                    callback({ success = false, message = err_msg, packages = {}, no_retry = true })
                end
            end
        end)
    end)
end

return M
