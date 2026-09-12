-- lvim-dependencies.managers.cargo.data.installed: reads installed versions from Cargo.lock.
-- Finds the lock file (config root_dir → buffer dir → cwd, searched upward), parses it, and
-- returns a single package's version or a bulk map for the declared set. The version CACHE is
-- owned by core.hub.installed — this module only reads lock files; clear_cache() delegates to
-- the hub (required inline to break the hub↔data circular dependency).
---@module "lvim-dependencies.managers.cargo.data.installed"

local utils = require("lvim-dependencies.utils")
local toml = require("lvim-dependencies.libs.toml")
local init = require("lvim-dependencies.core.init")
local project = require("lvim-dependencies.core.project")

local debug = utils.debug

---@class CargoInstalled
local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get manifest (init.lua owns the cache)
---@return CargoManifest|nil
local function get_manifest()
    local m = init.get_manifest("cargo")
    ---@cast m CargoManifest|nil
    return m
end

--- Find lock file by searching upward from the project root (core.project: config root_dir,
--- else the manifest buffer's directory, else cwd). Cargo.lock sits at the WORKSPACE root, so
--- the upward search from a member finds it either way.
---@param lock_file string
---@param opts? { root?: string, bufnr?: integer }
---@return string|nil
local function find_lock_file(lock_file, opts)
    local start_path = project.search_root("cargo", opts)
    local found = vim.fs.find(lock_file, { upward = true, path = start_path, type = "file" })
    return found and found[1] or nil
end

--- Parsed-lock cache keyed by absolute path. On a project-wide open every declared package
--- hits get_package_installed separately; without this each one re-read AND re-TOML-parsed the
--- whole Cargo.lock synchronously. We parse once per (mtime,size) signature and serve all.
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

    local ok, data = pcall(toml.parse, content)
    if not ok or type(data) ~= "table" then
        debug(string.format("Failed to parse TOML %s: %s", lock_file, tostring(data)), vim.log.levels.WARN)
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
    if not data or not data.package then
        return nil
    end
    for _, pkg in ipairs(data.package) do
        if pkg.name == package_name and pkg.version then
            return pkg.version
        end
    end
    return nil
end

--- Load all lock file data
---@param manifest_data CargoManifest
---@param opts? { root?: string, bufnr?: integer }
---@return table<string, table>
local function load_all_lock_data(manifest_data, opts)
    local lock_files = manifest_data.lock_files or { "Cargo.lock" }
    local result = {}
    for _, lock_file in ipairs(lock_files) do
        local data = read_and_parse_lock(lock_file, opts)
        if data and data.package then
            result[lock_file] = data
            debug(
                string.format("Loaded lock file: %s (%d packages)", lock_file, #(data.package or {})),
                vim.log.levels.DEBUG
            )
        end
    end
    return result
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get installed version for a package.
--- hub/installed.lua owns the version cache — this just reads lock files.
---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
---@param opts? { root?: string }  project root the lock is looked up from
function M.get_package_installed(package_name, callback, opts)
    local manifest_data = get_manifest()
    if not manifest_data then
        callback("No manifest data for cargo", nil)
        return
    end

    local version = nil
    local lock_files = manifest_data.lock_files or { "Cargo.lock" }

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

--- Get all installed data for declared packages (bulk lookup).
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
        for _, data in pairs(lock_data) do
            local version = find_package_in_lock(data, package_name)
            if version then
                result[package_name] = version
                break
            end
        end
    end

    return result
end

--- Clear cache — delegates to hub/installed which owns caching.
function M.clear_cache()
    lock_cache = {}
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("cargo")
    debug("Installed cache cleared (via hub)", vim.log.levels.INFO)
end

return M
