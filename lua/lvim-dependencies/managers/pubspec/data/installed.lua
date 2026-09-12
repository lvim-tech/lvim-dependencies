-- lvim-dependencies.managers.pubspec.data.installed: resolves the installed version of each
-- dependency from pubspec.lock. Finds the lock file by upward search (root_dir → buffer dir → cwd),
-- parses it with tinyyaml, and looks a package up in its `packages` map (case-insensitive fallback).
-- SDK packages report "sdk" without touching the lock file. The real version cache lives in
-- core.hub.installed — this module just does the lookup and clear_cache delegates to that hub.
--
---@module "lvim-dependencies.managers.pubspec.data.installed"

local utils = require("lvim-dependencies.utils")
local tinyyaml = require("lvim-dependencies.libs.tinyyaml")
local init = require("lvim-dependencies.core.init")
local project = require("lvim-dependencies.core.project")

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

--- Find lock file by searching upward from the project root (core.project: config root_dir,
--- else the manifest buffer's directory, else cwd).
---@param lock_file string
---@param opts? { root?: string, bufnr?: integer }
---@return string|nil
local function find_lock_file(lock_file, opts)
    local start_path = project.search_root("pubspec", opts)
    local found = vim.fs.find(lock_file, { upward = true, path = start_path, type = "file" })
    return found and found[1] or nil
end

--- Parsed pubspec.lock cache keyed by path + mtime + size. On a project-wide open every
--- declared package goes through get_package_installed separately; without this each one
--- re-read AND re-YAML-parsed the whole lock. Parse once per signature and serve all packages.
---@type table<string, { sig: string, data: table|false }>
local lock_cache = {}

--- Read and parse a lock file (cached by path + mtime + size).
---@param lock_file string
---@param opts? { root?: string, bufnr?: integer }
---@return table|nil
local function read_and_parse_lock(lock_file, opts)
    local lock_path = find_lock_file(lock_file, opts)
    if not lock_path then
        return nil
    end

    local stat = vim.uv.fs_stat(lock_path)
    local sig = string.format("%d:%d", stat and stat.mtime and stat.mtime.sec or 0, stat and stat.size or 0)
    local cached = lock_cache[lock_path]
    if cached and cached.sig == sig then
        return cached.data or nil
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
    if not ok or type(data) ~= "table" then
        debug(string.format("Failed to parse YAML %s: %s", lock_file, tostring(data)), vim.log.levels.WARN)
        lock_cache[lock_path] = { sig = sig, data = false }
        return nil
    end

    lock_cache[lock_path] = { sig = sig, data = data }
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

--- Check if package is an SDK package (manifest built-ins + config.pubspec.sdk_packages)
---@param package_name string
---@param _ ManagerManifest
---@return string|nil
local function get_sdk_version(package_name, _)
    local helpers = require("lvim-dependencies.managers.pubspec.utils.helpers")
    return helpers.is_sdk_package(package_name) and "sdk" or nil
end

--- Load all lock file data
---@param manifest_data ManagerManifest
---@param opts? { root?: string, bufnr?: integer }
---@return table<string, table>
local function load_all_lock_data(manifest_data, opts)
    local lock_files = manifest_data.lock_files or { "pubspec.lock" }
    local result = {}

    for _, lock_file in ipairs(lock_files) do
        local data = read_and_parse_lock(lock_file, opts)
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
---@param opts? { root?: string }  project root the lock is looked up from
function M.get_package_installed(package_name, callback, opts)
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

    local version = nil
    local lock_files = manifest_data.lock_files or { "pubspec.lock" }

    for _, lock_file in ipairs(lock_files) do
        local data = read_and_parse_lock(lock_file, opts)
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
---@param opts? { root?: string, bufnr?: integer }
---@return table<string, string|nil>
function M.get_data(declared_packages, opts)
    if not declared_packages then
        return {}
    end

    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No manifest data, cannot get installed data", vim.log.levels.ERROR)
        return {}
    end

    local lock_data = load_all_lock_data(manifest_data, opts or { bufnr = vim.api.nvim_get_current_buf() })
    local result = {}

    for package_name in pairs(declared_packages) do
        result[package_name] = resolve_version(package_name, manifest_data, lock_data)
    end

    return result
end

--- Clear cache — delegates to hub/installed which owns caching.
--- Kept for backward compatibility with pub_ops.lua and api/init.lua.
function M.clear_cache()
    lock_cache = {}
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("pubspec")
    debug("Installed cache cleared (via hub)", vim.log.levels.INFO)
end

return M
