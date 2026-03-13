-- lvim-dependencies/managers/cargo/features.lua
-- Centralized feature management for Cargo dependencies

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local notify = utils.notify
local parser = require("lvim-dependencies.managers.cargo.parser")
local file_ops = require("lvim-dependencies.managers.cargo.core.file_ops")
local toml_ops = require("lvim-dependencies.managers.cargo.core.toml_ops")
local ui = require("lvim-dependencies.ui")
local http = require("lvim-dependencies.utils.http")
local config = require("lvim-dependencies.config")
local vt = require("lvim-dependencies.core.virtual_text")
local hub_declared = require("lvim-dependencies.core.hub.declared")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local package_loader = require("lvim-dependencies.core.package_loader")

local debug = utils.debug
local api = vim.api

---@class CargoFeatures
local M = {}

local features_cache = {}
local in_flight = {}

-- ============================================================================
-- Feature parsing utilities
-- ============================================================================

---@param package_data any
---@return {features: string[], default_features: boolean, optional: boolean, version: string|nil}
function M.parse_dependency_data(package_data)
    local result = { features = {}, default_features = true, optional = false, version = nil }

    if type(package_data) == "string" then
        result.version = package_data
        return result
    end

    if type(package_data) == "table" then
        result.version = package_data.version
        result.features = package_data.features or {}
        result.optional = package_data.optional or false
        if package_data["default-features"] == false then
            result.default_features = false
        end
    end

    return result
end

---@param name string
---@param version string
---@param features string[]
---@param default_features boolean
---@param optional boolean
---@return string
function M.build_dependency_line(name, version, features, default_features, optional)
    if (not features or #features == 0) and default_features and not optional then
        return string.format('%s = "%s"', name, version)
    end

    local parts = { string.format('version = "%s"', version) }

    if features and #features > 0 then
        local sorted = vim.deepcopy(features)
        table.sort(sorted)
        table.insert(parts, 'features = ["' .. table.concat(sorted, '", "') .. '"]')
    end
    if not default_features then
        table.insert(parts, "default-features = false")
    end
    if optional then
        table.insert(parts, "optional = true")
    end

    return string.format("%s = { %s }", name, table.concat(parts, ", "))
end

---@param package_name string
---@return {features: string[], default_features: boolean, optional: boolean, version: string|nil}
function M.get_current_features(package_name)
    local all_deps = parser.get_dependencies() or {}
    local pkg_data = all_deps[package_name]
    if not pkg_data then
        return { features = {}, default_features = true, optional = false, version = nil }
    end
    return M.parse_dependency_data(pkg_data)
end

-- ============================================================================
-- Fetch available features from crates.io
-- ============================================================================

---@param package_name string
---@param callback fun(features: string[], err: string|nil)
function M.fetch_available_features(package_name, callback)
    if features_cache[package_name] then
        callback(features_cache[package_name], nil)
        return
    end

    if in_flight[package_name] then
        table.insert(in_flight[package_name], callback)
        return
    end

    in_flight[package_name] = { callback }

    local url = string.format("https://crates.io/api/v1/crates/%s", package_name)
    local timeout = config.cargo.api.timeout or 10

    local function notify_all(feats, err)
        local waiters = in_flight[package_name] or {}
        in_flight[package_name] = nil
        for _, cb in ipairs(waiters) do
            cb(feats, err)
        end
    end

    http.get(url, function(output, err)
        if err then
            notify_all(nil, err)
            return
        end

        local ok, data = pcall(vim.json.decode, output)
        if not ok or not data then
            notify_all(nil, "Failed to parse response")
            return
        end

        local features = {}
        if data.versions and #data.versions > 0 then
            for _, version in ipairs(data.versions) do
                if not version.yanked then
                    if version.features then
                        for feature in pairs(version.features) do
                            table.insert(features, feature)
                        end
                    end
                    break
                end
            end
        end

        table.sort(features)
        features_cache[package_name] = features
        notify_all(features, nil)
    end, timeout)
end

---@param package_name? string
function M.clear_cache(package_name)
    if package_name then
        features_cache[package_name] = nil
        in_flight[package_name] = nil
    else
        features_cache = {}
        in_flight = {}
    end
end

-- ============================================================================
-- Update features in Cargo.toml
-- ============================================================================

---@param package_name string
---@param opts {features?: string[], default_features?: boolean, optional?: boolean}
---@param callback fun(success: boolean, message: string|nil)
function M.update_features(package_name, opts, callback)
    debug(string.format("Updating features for %s", package_name), vim.log.levels.INFO)

    local path = file_ops.find_cargo_toml_path()
    if not path then
        callback(false, "Cargo.toml not found")
        return
    end

    local all_deps = parser.get_dependencies() or {}
    local current_pkg = all_deps[package_name]
    if not current_pkg then
        callback(false, string.format("Package %s not found", package_name))
        return
    end

    local current = M.parse_dependency_data(current_pkg)
    if not current.version then
        callback(false, "Could not determine current version")
        return
    end

    local lines = file_ops.read_lines(path)
    if not lines then
        callback(false, "Failed to read Cargo.toml")
        return
    end

    local sections = require("lvim-dependencies.managers.cargo.utils.helpers").get_dependency_sections()
    local bufnr = opts.bufnr or vim.fn.bufnr(path)

    local target_section_idx = nil
    local target_section_end = nil

    for _, section in ipairs(sections) do
        local idx = toml_ops.find_section_index(lines, section)
        if idx then
            local end_idx = toml_ops.find_section_end(lines, idx)
            local start_idx = toml_ops.find_package_line(lines, idx, end_idx, package_name)
            if start_idx then
                target_section_idx = idx
                target_section_end = end_idx
                break
            end
        end
    end

    if not target_section_idx then
        callback(false, string.format("Could not find package %s", package_name))
        return
    end

    local saved_view = nil
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
        saved_view = vim.fn.winsaveview()
    end

    local new_features = opts.features ~= nil and opts.features or current.features
    local new_default_features = opts.default_features ~= nil and opts.default_features or current.default_features
    local new_optional = opts.optional ~= nil and opts.optional or current.optional

    local new_line =
        M.build_dependency_line(package_name, current.version, new_features, new_default_features, new_optional)
    local new_lines, replaced, change =
        toml_ops.replace_package_in_section(lines, target_section_idx, target_section_end, package_name, new_line)

    if not replaced then
        callback(false, string.format("Failed to replace package %s in Cargo.toml", package_name))
        return
    end

    local write_ok, write_err = file_ops.write_lines(path, new_lines)
    if not write_ok then
        callback(false, write_err)
        return
    end

    if change then
        file_ops.apply_buffer_change(path, change)
    end

    -- ==========================================================================
    -- Clear caches
    -- ==========================================================================
    parser.clear_cache()
    M.clear_cache(package_name)
    hub_declared.clear_cache("cargo", package_name)
    hub_declared.refresh_data("cargo")
    package_loader.clear_cache(package_name)
    hub_installed.clear_cache("cargo", package_name)
    hub_latest.clear_cache("cargo", package_name)
    require("lvim-dependencies.managers.cargo.data.installed").clear_cache()
    require("lvim-dependencies.managers.cargo.data.latest").clear_cache()

    -- ==========================================================================
    -- Refresh virtual text via the public vt API (no direct virt_texts access)
    -- ==========================================================================
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
        vim.defer_fn(function()
            package_loader.load_package_data_async("cargo", package_name, function(package_data)
                if api.nvim_buf_is_valid(bufnr) then
                    vt.update_package(bufnr, package_data)
                end
                if saved_view and vim.api.nvim_get_current_buf() == bufnr then
                    vim.schedule(function()
                        pcall(vim.fn.winrestview, saved_view)
                    end)
                end
            end, { initial = false })
        end, 50)
    end

    callback(true, "Features updated successfully")
end

-- ============================================================================
-- UI
-- ============================================================================

---@param package_name string
---@param callback fun(features: string[]|nil, default_features: boolean|nil, optional: boolean|nil)
function M.show_features_ui(package_name, callback)
    local current = M.get_current_features(package_name)

    M.fetch_available_features(package_name, function(available_features, err)
        if err then
            notify("Failed to fetch features: " .. err, vim.log.levels.ERROR)
            callback(nil, nil, nil)
            return
        end

        if not available_features or #available_features == 0 then
            notify("No features available for " .. package_name, vim.log.levels.INFO)
            callback(current.features, current.default_features, current.optional)
            return
        end

        local initial_selected = {}
        for _, f in ipairs(current.features) do
            initial_selected[f] = true
        end

        vim.schedule(function()
            ui.multiselect(
                "Cargo Features",
                string.format("Select features for %s", package_name),
                string.format("Current version: %s", current.version or "unknown"),
                available_features,
                function(confirmed, selected)
                    if not confirmed then
                        callback(nil, nil, nil)
                        return
                    end
                    local features = {}
                    for feature, enabled in pairs(selected) do
                        if enabled then
                            table.insert(features, feature)
                        end
                    end
                    table.sort(features)
                    callback(features, current.default_features, current.optional)
                end,
                { initial_selected = initial_selected }
            )
        end)
    end)
end

---@param package_name string
---@param bufnr integer
function M.show_ui(package_name, bufnr)
    M.show_features_ui(package_name, function(features, default_features, optional)
        if not features then
            return
        end
        M.update_features(package_name, {
            features = features,
            default_features = default_features,
            optional = optional,
            bufnr = bufnr,
        }, function(success, message)
            if success then
                notify(string.format("Features updated for %s", package_name), vim.log.levels.INFO)
            else
                notify(message or "Failed to update features", vim.log.levels.ERROR)
            end
        end)
    end)
end

return M
