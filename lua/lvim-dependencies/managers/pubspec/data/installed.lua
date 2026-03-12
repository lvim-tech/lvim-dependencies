-- lvim-dependencies/managers/pubspec/data/installed.lua
-- Installed package manager for pubspec.lock using manifest configuration

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local tinyyaml = require("lvim-dependencies.libs.tinyyaml")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class PubspecInstalled
local M = {}

-- ============================================================================
-- Manifest cache
-- init.get_manifest() already caches the result — keep a local alias
-- to avoid repeating the string key on every call.
-- ============================================================================

--- Get manifest data (init.lua owns the cache)
---@return ManagerManifest|nil
local function get_manifest()
    return init.get_manifest("pubspec")
end

-- ============================================================================
-- Lock file helpers
-- ============================================================================

--- Find lock file by searching upward
---@param lock_file string
---@param bufnr? integer
---@return string|nil
local function find_lock_file(lock_file, bufnr)
    local start_path

    local root_dir = config.pubspec and config.pubspec.file_ops and config.pubspec.file_ops.root_dir
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

    local found = vim.fs.find(lock_file, { upward = true, path = start_path, type = "file" })
    return found and found[1] or nil
end

--- Read and parse a lock file
---@param lock_file string
---@param bufnr? integer
---@return table|nil
local function read_and_parse_lock(lock_file, bufnr)
    local lock_path = find_lock_file(lock_file, bufnr)
    if not lock_path then
        return nil
    end

    local file, open_err = io.open(lock_path, "r")
    if not file then
        debug(string.format("Cannot open lock file: %s", open_err or "unknown"), vim.log.levels.WARN)
        return nil
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil
    end

    local ok, data = pcall(tinyyaml.parse, content)
    if not ok then
        debug(string.format("Failed to parse YAML %s: %s", lock_file, tostring(data)), vim.log.levels.WARN)
        return nil
    end

    return data
end

--- Find package version in parsed lock data
---@param data table
---@param package_name string
---@return string|nil
local function find_package_in_lock(data, package_name)
    if not data or not data.packages then
        return nil
    end

    local exact = data.packages[package_name]
    if exact and exact.version then
        return exact.version
    end

    local lower_name = package_name:lower()
    for pkg_name, pkg_data in pairs(data.packages) do
        if pkg_name:lower() == lower_name and pkg_data and pkg_data.version then
            return pkg_data.version
        end
    end

    return nil
end

--- Check if package is an SDK package
---@param package_name string
---@param manifest_data ManagerManifest
---@return string|nil
local function get_sdk_version(package_name, manifest_data)
    local sdk_packages = manifest_data.sdk_packages or {}
    return sdk_packages[package_name] and "sdk" or nil
end

--- Load all lock file data
---@param manifest_data ManagerManifest
---@param bufnr integer
---@return table<string, table>
local function load_all_lock_data(manifest_data, bufnr)
    local lock_files = manifest_data.lock_files or { "pubspec.lock" }
    local result = {}

    for _, lock_file in ipairs(lock_files) do
        local data = read_and_parse_lock(lock_file, bufnr)
        if data and data.packages then
            result[lock_file] = data
            debug(
                string.format("Loaded lock file: %s (%d packages)", lock_file, vim.tbl_count(data.packages or {})),
                vim.log.levels.DEBUG
            )
        end
    end

    return result
end

--- Resolve installed version (SDK → lock files → nil)
---@param package_name string
---@param manifest_data ManagerManifest
---@param lock_data table<string, table>
---@return string|nil
local function resolve_version(package_name, manifest_data, lock_data)
    local sdk_ver = get_sdk_version(package_name, manifest_data)
    if sdk_ver then
        return sdk_ver
    end

    for _, data in pairs(lock_data) do
        local version = find_package_in_lock(data, package_name)
        if version then
            return version
        end
    end

    return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get installed version for a package.
--- NOTE: hub/installed.lua owns the version cache.
--- This function performs the actual lock-file lookup every time it is called
--- by hub/installed (which will cache the result itself).
---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
function M.get_package_installed(package_name, callback)
    local manifest_data = get_manifest()
    if not manifest_data then
        callback("No manifest data for pubspec", nil)
        return
    end

    -- SDK fast path (no lock file needed)
    local sdk_ver = get_sdk_version(package_name, manifest_data)
    if sdk_ver then
        debug(string.format("SDK package %s", package_name), vim.log.levels.INFO)
        callback(nil, sdk_ver)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local version = nil
    local lock_files = manifest_data.lock_files or { "pubspec.lock" }

    for _, lock_file in ipairs(lock_files) do
        local data = read_and_parse_lock(lock_file, bufnr)
        if data then
            version = find_package_in_lock(data, package_name)
            if version then
                break
            end
        end
    end

    if version then
        debug(string.format("Found %s: %s", package_name, version), vim.log.levels.INFO)
    else
        debug(string.format("Package not installed: %s", package_name), vim.log.levels.INFO)
    end

    callback(nil, version)
end

--- Get all installed data for declared packages.
--- Used for bulk lookups (avoids per-package lock file parsing).
---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end

    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No manifest data, cannot get installed data", vim.log.levels.ERROR)
        return {}
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local lock_data = load_all_lock_data(manifest_data, bufnr)
    local result = {}

    for package_name in pairs(declared_packages) do
        result[package_name] = resolve_version(package_name, manifest_data, lock_data)
    end

    return result
end

--- Clear cache — delegates to hub/installed which owns caching.
--- Kept for backward compatibility with pub_ops.lua and api/init.lua.
function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("pubspec")
    debug("Installed cache cleared (via hub)", vim.log.levels.INFO)
end

return M
