-- lvim-dependencies.managers.cargo.data.installed: reads installed versions from Cargo.lock.
-- Finds the lock file (config root_dir → buffer dir → cwd, searched upward), parses it, and
-- returns a single package's version or a bulk map for the declared set. The version CACHE is
-- owned by core.hub.installed — this module only reads lock files; clear_cache() delegates to
-- the hub (required inline to break the hub↔data circular dependency).
---@module "lvim-dependencies.managers.cargo.data.installed"

local utils = require("lvim-dependencies.utils")
local toml = require("lvim-dependencies.libs.toml")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

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

--- Find lock file by searching upward
---@param lock_file string
---@param bufnr? integer
---@return string|nil
local function find_lock_file(lock_file, bufnr)
    local start_path

    local root_dir = config.cargo and config.cargo.file_ops and config.cargo.file_ops.root_dir
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

    local ok, data = pcall(toml.parse, content)
    if not ok then
        debug(string.format("Failed to parse TOML %s: %s", lock_file, tostring(data)), vim.log.levels.WARN)
        return nil
    end

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
---@param bufnr integer
---@return table<string, table>
local function load_all_lock_data(manifest_data, bufnr)
    local lock_files = manifest_data.lock_files or { "Cargo.lock" }
    local result = {}
    for _, lock_file in ipairs(lock_files) do
        local data = read_and_parse_lock(lock_file, bufnr)
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
function M.get_package_installed(package_name, callback)
    local manifest_data = get_manifest()
    if not manifest_data then
        callback("No manifest data for cargo", nil)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local version = nil
    local lock_files = manifest_data.lock_files or { "Cargo.lock" }

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

--- Get all installed data for declared packages (bulk lookup).
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
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("cargo")
    debug("Installed cache cleared (via hub)", vim.log.levels.INFO)
end

return M
