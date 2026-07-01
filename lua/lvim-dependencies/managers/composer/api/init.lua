-- lvim-dependencies.managers.composer.api: public API surface for composer package actions
-- (read the package under the cursor, fetch versions from packagist, update, delete). Non-UI
-- paths edit composer.json directly and refresh the open buffer; UI paths delegate to
-- composer_ops so the real `composer` binary resolves the dependency tree. Platform
-- requirements (php / ext-* / lib-* / composer-*) short-circuit — they are not on packagist.
--
---@module "lvim-dependencies.managers.composer.api"

local cache = require("lvim-dependencies.core.cache")
local vt = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")
local state = require("lvim-dependencies.core.state")
local ui = require("lvim-dependencies.ui")

local helpers = require("lvim-dependencies.managers.composer.utils.helpers")
local file_ops = require("lvim-dependencies.managers.composer.core.file_ops")
local json_ops = require("lvim-dependencies.managers.composer.core.json_ops")
local composer_ops = require("lvim-dependencies.managers.composer.core.composer_ops")
local parser = require("lvim-dependencies.managers.composer.parser")
local compare_versions = require("lvim-dependencies.managers.composer.compare_versions")
local manifest_mod = require("lvim-dependencies.managers.composer.manifest")
local data_installed = require("lvim-dependencies.managers.composer.data.installed")
local data_latest = require("lvim-dependencies.managers.composer.data.latest")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_TYPE_LATEST = const.CACHE_TYPES.LATEST

---@class ComposerActions
local M = {}

---@type string[]|nil
local cached_sections = nil

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function trigger_package_updated()
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function get_dependency_sections()
    if not cached_sections then
        cached_sections = helpers.get_dependency_sections()
    end
    return cached_sections
end

local function clear_package_caches(name)
    cache.clear("composer", CACHE_TYPE_INSTALLED, name)
    cache.clear("composer", CACHE_TYPE_LATEST, name)
    hub_installed.clear_cache("composer", name)
    hub_latest.clear_cache("composer", name)
    data_installed.clear_cache()
    data_latest.clear_cache()
    parser.clear_cache()
end

local function update_vt_after_removal(bufnr, name)
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    vt.remove_package(bufnr, name)
    vt.move_virt_texts_only(bufnr)
end

local function refresh_buffer_state(bufnr)
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    local buf_state = state.get_buffer_state(bufnr)
    buf_state.skip_next_check = true
    vim.bo[bufnr].modified = false
    api.nvim_buf_call(bufnr, function()
        vim.cmd("checktime")
    end)
end

-- ============================================================================
-- Public API
-- ============================================================================

---@param opts? {bufnr?: integer, cursor_line?: integer}
---@return string|nil
function M.get_package_at_cursor(opts)
    opts = opts or {}
    local manifest = helpers.get_manifest()
    if not manifest or not manifest.package_patterns then
        return nil
    end

    local bufnr = opts.bufnr or api.nvim_get_current_buf()
    if not api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local cursor_line = opts.cursor_line
    if cursor_line == nil then
        cursor_line = api.nvim_win_get_cursor(0)[1] - 1
    end

    local line = api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1]
    if not line then
        return nil
    end

    -- Skip special keys
    for _, key in ipairs(manifest.special_keys or {}) do
        if line:match(string.format('^%%s*"%s"%%s*:', vim.pesc(key))) then
            return nil
        end
    end

    for _, pattern in pairs(manifest.package_patterns) do
        local name = line:match(pattern)
        if name then
            return name
        end
    end
    return nil
end

---@param name string|nil
---@param callback fun(data: VersionData|nil)
function M.fetch_versions_async(name, callback)
    if not name or name == "" then
        callback(nil)
        return
    end

    debug(string.format("composer: fetching versions for %s", name), vim.log.levels.INFO)

    local current = helpers.read_current_from_lock(name)
    local package_section = helpers.find_package_section(name)

    -- Platform packages (php, ext-*, lib-*, composer-*) are not on packagist
    if not manifest_mod.is_package_actionable(name) then
        callback({ versions = {}, current = current or "n/a", section = package_section })
        return
    end

    local manifest = helpers.get_manifest()
    if not manifest then
        callback({ versions = {}, current = current or "not installed", section = package_section })
        return
    end

    local registry_base = (config.composer and config.composer.api and config.composer.api.registry_base)
        or (manifest.registry and manifest.registry.base_url)
        or "https://packagist.org"

    local endpoint = (config.composer and config.composer.api and config.composer.api.endpoint)
        or (manifest.registry and manifest.registry.package_endpoint)
        or "/packages/%s.json"

    local timeout = (config.composer and config.composer.api and config.composer.api.timeout) or 10
    local url = registry_base .. string.format(endpoint, name)

    vim.system({ "curl", "-fsS", "--max-time", tostring(timeout), url }, { text = true }, function(res)
        vim.schedule(function()
            if not res or res.code ~= 0 or not res.stdout then
                callback({ versions = {}, current = current or "not installed", section = package_section })
                return
            end

            local ok, data = pcall(vim.json.decode, res.stdout)
            if not ok or type(data) ~= "table" or not data.package then
                callback({ versions = {}, current = current or "not installed", section = package_section })
                return
            end

            local versions_map = data.package.versions
            if type(versions_map) ~= "table" then
                callback({ versions = {}, current = current or "not installed", section = package_section })
                return
            end

            local inc_pre = config.composer and config.composer.version and config.composer.version.include_prerelease

            local seen, raw_versions = {}, {}
            for ver_str in pairs(versions_map) do
                -- Strip "v" prefix
                local ver = ver_str:gsub("^v", "")
                if ver:match("^%d") and not seen[ver] then
                    -- Semver prerelease or composer-style prerelease
                    local is_pre = ver:match("%d+%.%d+%.%d+%-") ~= nil
                        or ver:lower():match("alpha") ~= nil
                        or ver:lower():match("beta") ~= nil
                        or ver:lower():match("rc%d") ~= nil
                        or ver:lower():match("%-dev") ~= nil
                    if inc_pre or not is_pre then
                        seen[ver] = true
                        raw_versions[#raw_versions + 1] = ver
                    end
                end
            end

            if config.composer and config.composer.version and config.composer.version.sort_order == "asc" then
                compare_versions.sort(raw_versions)
            else
                compare_versions.sort_desc(raw_versions)
            end

            local max_versions = (config.composer and config.composer.version and config.composer.version.max_versions)
                or 50
            if #raw_versions > max_versions then
                local limited = {}
                for i = 1, max_versions do
                    limited[i] = raw_versions[i]
                end
                raw_versions = limited
            end

            -- Get current from lock file
            data_installed.get_package_installed(name, function(_, ver)
                callback({ versions = raw_versions, current = ver or current, section = package_section })
            end)
        end)
    end)
end

---@param name string
---@param opts UpdateOptions
---@param callback InstallerCallback
function M.update_async(name, opts, callback)
    if not callback then
        callback = function() end
    else
        assert(type(callback) == "function")
    end

    if not name then
        callback({ success = false, message = "package name required", packages = {} })
        return
    end

    opts = opts or {}
    local version = opts.version
    if not version then
        callback({ success = false, message = "version required", packages = {} })
        return
    end

    local path = file_ops.find_composer_json_path()
    if not path then
        callback({ success = false, message = "composer.json not found", packages = {} })
        return
    end

    if opts.from_ui then
        composer_ops.run_composer_update(path, name, version, opts, callback)
        return
    end

    -- Non-UI: write file directly then trigger update
    local lines = file_ops.read_lines(path)
    if not lines then
        callback({ success = false, message = "unable to read composer.json", packages = {} })
        return
    end

    local section = helpers.find_package_section(name)
        or (config.composer and config.composer.sections and config.composer.sections.default)
        or "require"

    local section_idx = json_ops.find_section_index(lines, section)
    if not section_idx then
        callback({ success = false, message = "section not found: " .. section, packages = {} })
        return
    end

    local section_end = json_ops.find_section_end(lines, section_idx)
    local new_line = json_ops.format_package_line(name, version)
    local new_lines, replaced, change =
        json_ops.replace_package_in_section(lines, section_idx, section_end, name, new_line)

    if not replaced then
        new_lines, change = json_ops.insert_package_in_section(lines, section_idx, section_end, new_line)
    end

    if not new_lines then
        callback({ success = false, message = "failed to update composer.json", packages = {} })
        return
    end

    local ok, err = file_ops.write_lines(path, new_lines)
    if not ok then
        callback({ success = false, message = "failed to write: " .. tostring(err), packages = {} })
        return
    end

    if change then
        file_ops.apply_buffer_change(path, change)
    else
        file_ops.force_refresh_buffer(path, new_lines)
    end

    parser.clear_cache()
    vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
    trigger_package_updated()
    callback({ success = true, message = "written", packages = { name } })
end

---@param name string
---@param opts DeleteOptions
---@param callback InstallerCallback
function M.delete(name, opts, callback)
    assert(type(callback) == "function")
    if not name then
        callback({ success = false, message = "package name required", packages = {} })
        return
    end

    opts = opts or {}

    M.fetch_versions_async(name, function(versions_data)
        local current_version = versions_data and versions_data.current or "not installed"
        local current_section = versions_data and versions_data.section or "unknown"

        ui.select(
            "Confirm Delete",
            string.format("Package: %s", name),
            string.format("Current version: %s (in: %s)", current_version, current_section),
            { "Yes, delete", "No, cancel" },
            function(confirmed, idx)
                if not confirmed or idx ~= 1 then
                    callback({ success = false, message = "cancelled", packages = {} })
                    return
                end
                M._delete_package(name, opts, callback)
            end,
            { default_index = 2 }
        )
    end)
end

---@param name string
---@param opts DeleteOptions
---@param callback InstallerCallback
function M._delete_package(name, opts, callback)
    assert(type(callback) == "function")
    opts = opts or {}

    local path = file_ops.find_composer_json_path()
    if not path then
        callback({ success = false, message = "composer.json not found", packages = {} })
        return
    end

    local lines = file_ops.read_lines(path)
    if not lines then
        callback({ success = false, message = "unable to read composer.json", packages = {} })
        return
    end

    local sections = get_dependency_sections()
    local found_scope = nil
    local section_idx = nil
    local section_end = nil

    for _, scope in ipairs(sections) do
        local idx = json_ops.find_section_index(lines, scope)
        if idx then
            local end_idx = json_ops.find_section_end(lines, idx)
            local i, _ = json_ops.find_package_block(lines, idx, end_idx, name)
            if i then
                found_scope = scope
                section_idx = idx
                section_end = end_idx
                break
            end
        end
    end

    if not found_scope then
        callback({ success = false, message = "package " .. name .. " not found", packages = {} })
        return
    end
    -- found_scope is set together with section_idx/section_end inside the loop above.
    ---@cast section_idx integer
    ---@cast section_end integer

    local new_lines, change = json_ops.remove_package_from_section(lines, section_idx, section_end, name)
    if not new_lines then
        callback({ success = false, message = "failed to remove package", packages = {} })
        return
    end

    if opts.from_ui then
        composer_ops.run_composer_remove(path, name, opts, callback)
        return
    end

    local ok, err = file_ops.write_lines(path, new_lines)
    if not ok then
        callback({ success = false, message = "failed to write: " .. tostring(err), packages = {} })
        return
    end

    if change then
        file_ops.apply_buffer_change(path, change)
    else
        file_ops.force_refresh_buffer(path, new_lines)
    end

    clear_package_caches(name)
    local bufnr = vim.fn.bufnr(path)
    update_vt_after_removal(bufnr, name)
    refresh_buffer_state(bufnr)
    vim.g.lvim_deps_last_updated = name .. "@removed"
    trigger_package_updated()
    callback({ success = true, message = "removed successfully", packages = { name } })
end

return M
