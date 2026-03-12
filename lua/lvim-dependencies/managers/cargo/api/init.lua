-- lvim-dependencies/managers/cargo/api/init.lua
-- Public API for cargo actions

---@include "core/types.lua"

local cache = require("lvim-dependencies.core.cache")
local vt = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local helpers = require("lvim-dependencies.managers.cargo.utils.helpers")
local file_ops = require("lvim-dependencies.managers.cargo.core.file_ops")
local toml_ops = require("lvim-dependencies.managers.cargo.core.toml_ops")
local cargo_ops = require("lvim-dependencies.managers.cargo.core.cargo_ops")
local parser = require("lvim-dependencies.managers.cargo.parser")
local compare_versions = require("lvim-dependencies.managers.cargo.compare_versions")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_TYPE_LATEST = const.CACHE_TYPES.LATEST

---@class CargoActions
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

local function find_last_section_index(lines, sections)
    local last_idx = 0
    for i, line in ipairs(lines) do
        for _, sec in ipairs(sections) do
            if line:match("^%s*%[" .. vim.pesc(sec) .. "%]") then
                last_idx = i
                break
            end
        end
    end
    return last_idx > 0 and last_idx or nil
end

--- Clear all caches for a package using the public cache API
---@param name string
local function clear_package_caches(name)
    cache.clear("cargo", CACHE_TYPE_INSTALLED, name)
    cache.clear("cargo", CACHE_TYPE_LATEST, name)
    hub_installed.clear_cache("cargo", name)
    hub_latest.clear_cache("cargo", name)
    require("lvim-dependencies.managers.cargo.data.installed").clear_cache()
    require("lvim-dependencies.managers.cargo.data.latest").clear_cache()
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
    -- Use state API instead of direct struct access
    local state = require("lvim-dependencies.core.state")
    local buf_state = state.get_buffer_state(bufnr)
    buf_state.skip_next_check = true
    vim.bo[bufnr].modified = false
    api.nvim_buf_call(bufnr, function()
        vim.cmd("checktime")
    end)
end

local function resolve_scope(name, disk_lines, sections, scope)
    if scope and vim.tbl_contains(sections, scope) then
        return scope
    end
    local found = helpers.find_package_section(name)
    if found then
        return found
    end
    for _, sec in ipairs(sections) do
        local sec_idx = toml_ops.find_section_index(disk_lines, sec)
        if sec_idx then
            local sec_end = toml_ops.find_section_end(disk_lines, sec_idx)
            local i, _ = toml_ops.find_package_block(disk_lines, sec_idx, sec_end, name)
            if i then
                return sec
            end
        end
    end
    return sections[1] or "dependencies"
end

local function prepare_toml_changes(name, version, disk_lines, scope, sections)
    local section_idx = toml_ops.find_section_index(disk_lines, scope)

    if not section_idx then
        debug(string.format("Section '%s' not found, creating it", scope), vim.log.levels.INFO)
        local last_section_idx = find_last_section_index(disk_lines, sections)
        if last_section_idx then
            local section_end = toml_ops.find_section_end(disk_lines, last_section_idx)
            table.insert(disk_lines, section_end + 1, "")
            table.insert(disk_lines, section_end + 2, "[" .. scope .. "]")
            section_idx = section_end + 2
        else
            table.insert(disk_lines, "")
            table.insert(disk_lines, "[" .. scope .. "]")
            section_idx = #disk_lines
        end
        if section_idx + 1 <= #disk_lines then
            table.insert(disk_lines, section_idx + 1, "")
        end
    end

    local section_end = toml_ops.find_section_end(disk_lines, section_idx)

    local pkg_indent = ""
    local sample_ln = disk_lines[section_idx + 1]
    if sample_ln then
        local s_indent = sample_ln:match("^(%s*)") or ""
        if #s_indent > 0 then
            pkg_indent = s_indent
        end
    end

    local line_value
    local start_idx, _, current_line = toml_ops.find_package_block(disk_lines, section_idx, section_end, name)

    if start_idx and current_line then
        local existing_indent = current_line:match("^(%s*)") or ""
        if #existing_indent > 0 then
            pkg_indent = existing_indent
        end

        local current_features = {}
        if current_line:match("=") and current_line:match("{") then
            local features_match = current_line:match("features%s*=%s*%[([^%]]+)%]")
            if features_match then
                for feature in features_match:gmatch('"([^"]+)"') do
                    table.insert(current_features, feature)
                end
            end
        end

        if #current_features > 0 then
            local features_str = 'features = ["' .. table.concat(current_features, '", "') .. '"]'
            line_value = string.format('%s = { version = "%s", %s }', name, version, features_str)
        else
            line_value = string.format('%s = "%s"', name, version)
        end

        local new_line = pkg_indent .. line_value
        local new_lines, replaced, change =
            toml_ops.replace_package_in_section(disk_lines, section_idx, section_end, name, new_line)
        if replaced then
            return new_lines or {}, change, section_idx
        end
    end

    debug(string.format("Package %s not found in section, inserting", name), vim.log.levels.INFO)
    line_value = string.format('%s = "%s"', name, version)
    local new_line = pkg_indent .. line_value
    local new_lines, change = toml_ops.insert_package_in_section(disk_lines, section_idx, new_line)
    return new_lines or {}, change, section_idx
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

    local cursor_line
    if opts.cursor_line ~= nil then
        cursor_line = opts.cursor_line
    else
        cursor_line = api.nvim_win_get_cursor(0)[1] - 1
    end

    local line = api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1]
    if not line then
        return nil
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

    debug(string.format("Fetching versions for %s", name), vim.log.levels.INFO)

    local current = helpers.read_current_from_lock(name)
    local package_section = helpers.find_package_section(name)

    local manifest = helpers.get_manifest()
    if not manifest then
        callback({ versions = {}, current = current or "not installed", section = package_section })
        return
    end

    local registry_base = config.cargo.api.registry_base
        or (manifest.registry and manifest.registry.base_url)
        or manifest.default_registry
        or "https://crates.io/api/v1"

    local endpoint = config.cargo.api.endpoint
        or (manifest.registry and manifest.registry.package_endpoint)
        or "/crates/%s"

    local timeout = config.cargo.api.timeout or (manifest.api and manifest.api.timeout) or 10

    local url = registry_base .. string.format(endpoint, name)

    vim.system({ "curl", "-fsS", "--max-time", tostring(timeout), url }, { text = true }, function(res)
        vim.schedule(function()
            if not res or res.code ~= 0 or not res.stdout then
                callback({ versions = {}, current = current or "not installed", section = package_section })
                return
            end

            local ok, parsed = pcall(vim.json.decode, res.stdout)
            if not ok or type(parsed) ~= "table" then
                callback({ versions = {}, current = current or "not installed", section = package_section })
                return
            end

            local versions = {}
            if parsed.versions then
                for _, v in ipairs(parsed.versions) do
                    if type(v) == "string" then
                        table.insert(versions, v)
                    elseif type(v) == "table" and v.num then
                        table.insert(versions, v.num)
                    end
                end
            elseif parsed.versions_list then
                versions = parsed.versions_list
            end

            local seen, uniq = {}, {}
            for _, ver in ipairs(versions) do
                if not seen[ver] then
                    -- Semver prerelease: contains "-" after patch number
                    -- e.g. "1.0.0-alpha", "1.0.0-beta.1", "1.0.0-rc.3"
                    local is_prerelease = ver:match("%d+%.%d+%.%d+%-") ~= nil
                    if config.cargo.version.include_prerelease or not is_prerelease then
                        seen[ver] = true
                        uniq[#uniq + 1] = ver
                    end
                end
            end

            if config.cargo.version.sort_order == "asc" then
                compare_versions.sort_asc(uniq)
            else
                compare_versions.sort_desc(uniq)
            end

            local max_versions = config.cargo.version.max_versions or 50
            if #uniq > max_versions then
                local limited = {}
                for i = 1, max_versions do
                    limited[i] = uniq[i]
                end
                uniq = limited
            end

            callback({ versions = uniq, current = current, section = package_section })
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
        assert(type(callback) == "function", "callback must be a function")
    end

    if not name then
        callback({ success = false, message = "package name required", packages = {} })
        return
    end

    opts = opts or {}
    local version = opts.version
    if not version then
        callback({ success = false, message = "version is required", packages = {} })
        return
    end

    debug(string.format("Updating %s to %s", name, version), vim.log.levels.INFO)

    local sections = get_dependency_sections()
    local path = file_ops.find_cargo_toml_path()
    if not path then
        callback({ success = false, message = "Cargo.toml not found", packages = {} })
        return
    end

    local disk_lines = file_ops.read_lines(path)
    if not disk_lines then
        callback({ success = false, message = "unable to read Cargo.toml", packages = {} })
        return
    end

    local scope = resolve_scope(name, disk_lines, sections, opts.scope)
    local original_lines = vim.deepcopy(disk_lines)
    local new_lines, change = prepare_toml_changes(name, version, disk_lines, scope, sections)

    if opts.from_ui then
        cargo_ops.run_cargo_update(path, name, version, {
            pending_lines = new_lines,
            change = change,
            original_lines = original_lines,
            scope = scope,
        }, callback)
        return
    end

    local okw, werr = file_ops.write_lines(path, new_lines)
    if not okw then
        callback({ success = false, message = "failed to write: " .. tostring(werr), packages = {} })
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
    assert(type(callback) == "function", "callback must be a function")
    if not name then
        callback({ success = false, message = "package name required", packages = {} })
        return
    end

    opts = opts or {}
    local ui = require("lvim-dependencies.ui.popup")

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
    assert(type(callback) == "function", "callback must be a function")
    opts = opts or {}

    local path = file_ops.find_cargo_toml_path()
    if not path then
        callback({ success = false, message = "Cargo.toml not found", packages = {} })
        return
    end

    local lines = file_ops.read_lines(path)
    if not lines then
        callback({ success = false, message = "unable to read Cargo.toml", packages = {} })
        return
    end

    local sections = get_dependency_sections()
    local found_scope = nil
    local section_idx = nil
    local section_end = nil

    for _, scope in ipairs(sections) do
        local idx = toml_ops.find_section_index(lines, scope)
        if idx then
            local end_idx = toml_ops.find_section_end(lines, idx)
            local i, _ = toml_ops.find_package_block(lines, idx, end_idx, name)
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

    local new_lines, change = toml_ops.remove_package_from_section(lines, section_idx, section_end, name)
    if not new_lines then
        callback({ success = false, message = "failed to remove package", packages = {} })
        return
    end

    if opts.from_ui then
        local cmd = cargo_ops.choose_cargo_remove_cmd(name)
        if not cmd then
            callback({ success = false, message = "cargo command not available", packages = {} })
            return
        end

        file_ops.write_lines(path, new_lines)
        if change then
            file_ops.apply_buffer_change(path, change)
        else
            file_ops.force_refresh_buffer(path, new_lines)
        end

        local bufnr = vim.fn.bufnr(path)
        if bufnr ~= -1 then
            vim.bo[bufnr].modified = false
        end

        vim.system(cmd, { cwd = vim.fn.fnamemodify(path, ":h"), text = true }, function(res)
            vim.schedule(function()
                if res and res.code == 0 then
                    clear_package_caches(name)
                    update_vt_after_removal(bufnr, name)
                    refresh_buffer_state(bufnr)
                    trigger_package_updated()
                    callback({ success = true, message = "removed successfully", packages = { name } })
                else
                    file_ops.write_lines(path, lines)
                    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
                        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                        vim.bo[bufnr].modified = false
                        vt.move_virt_texts_only(bufnr)
                    end
                    local err_msg = res and cargo_ops.extract_cargo_error(res) or "remove failed"
                    callback({ success = false, message = err_msg, packages = {}, no_retry = true })
                end
            end)
        end)
        return
    end

    local okw, werr = file_ops.write_lines(path, new_lines)
    if not okw then
        callback({ success = false, message = "failed to write: " .. tostring(werr), packages = {} })
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
