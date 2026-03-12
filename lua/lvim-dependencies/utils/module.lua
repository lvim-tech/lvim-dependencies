-- lvim-dependencies/utils/module.lua
-- Module loading utilities with error handling and cache management

local notify = require("lvim-dependencies.utils.notify")
local debug = require("lvim-dependencies.utils.debug")

local M = {}

--- Safely require a module with error handling
---@param mod_path string Module path to require
---@param silent boolean|nil If true, suppress notifications
---@return table|nil Loaded module or nil if failed
function M.safe_require(mod_path, silent)
    if type(mod_path) ~= "string" or mod_path == "" then
        if not silent then
            pcall(notify, "Invalid module path: " .. tostring(mod_path), vim.log.levels.WARN)
        end
        return nil
    end

    local ok, mod = pcall(require, mod_path)

    if not ok then
        if not silent then
            local msg = string.format("Failed to require module '%s'", mod_path)
            pcall(notify, msg, vim.log.levels.WARN)
            pcall(debug, msg .. ": " .. tostring(mod), vim.log.levels.ERROR)
        end
        return nil
    end

    return mod
end

--- Normalize file path separators to Unix style
---@param file_path string File path to normalize
---@return string Normalized path
local function normalize_path(file_path)
    if type(file_path) ~= "string" then
        return ""
    end

    local normalized = file_path:gsub("\\", "/")
    return normalized
end

--- Extract module name from file path
--- Assumes path contains "/lua/" followed by module path and .lua extension
---@param normalized_path string Normalized file path
---@return string|nil Module name (dots separated) or nil if not found
local function extract_module_name(normalized_path)
    return normalized_path:match("/lua/(.+)%.lua$")
end

--- Convert dots to slashes in module path
---@param mod_path string Module path with dots
---@return string Path with slashes
local function dots_to_slashes(mod_path)
    if type(mod_path) ~= "string" then
        return ""
    end

    local result = mod_path:gsub("%.", "/")
    return result
end

--- Convert file path to module path
--- Example: "/path/to/lua/module/submodule.lua" -> "module.submodule"
---@param file_path string File path to convert
---@return string|nil Module path or nil if conversion failed
function M.filepath_to_modpath(file_path)
    if type(file_path) ~= "string" or file_path == "" then
        return nil
    end

    local normalized = normalize_path(file_path)
    local mod = extract_module_name(normalized)

    if not mod then
        return nil
    end

    local result = mod:gsub("/", ".")
    return result
end

--- Check if a file exists
---@param path string File path to check
---@return boolean True if file exists
local function file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end

    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

--- Check if module exists without loading it
--- Searches in package.path
---@param mod_path string Module path to check
---@return boolean True if module exists
function M.exists(mod_path)
    if type(mod_path) ~= "string" or mod_path == "" then
        return false
    end

    local search_path = dots_to_slashes(mod_path) .. ".lua"

    for path in package.path:gmatch("[^;]+") do
        local full_path = path:gsub("%?", search_path)
        if file_exists(full_path) then
            return true
        end
    end

    return false
end

--- Clear module from package.loaded cache
---@param mod_path string Module path to clear
function M.clear_cache(mod_path)
    if type(mod_path) ~= "string" or mod_path == "" then
        return
    end
    package.loaded[mod_path] = nil
end

--- Reload a module (clear cache and require again)
---@param mod_path string Module path to reload
---@param silent boolean|nil If true, suppress notifications
---@return table|nil Reloaded module or nil if failed
function M.reload(mod_path, silent)
    M.clear_cache(mod_path)
    return M.safe_require(mod_path, silent)
end

--- Get full filesystem path of a module
---@param mod_path string Module path to locate
---@return string|nil Full path to module file or nil if not found
function M.where(mod_path)
    if type(mod_path) ~= "string" or mod_path == "" then
        return nil
    end

    local search_path = dots_to_slashes(mod_path) .. ".lua"

    for path in package.path:gmatch("[^;]+") do
        local full_path = path:gsub("%?", search_path)
        if file_exists(full_path) then
            return full_path
        end
    end

    return nil
end

--- Check if module is already loaded (in package.loaded)
---@param mod_path string Module path to check
---@return boolean True if module is loaded
function M.is_loaded(mod_path)
    if type(mod_path) ~= "string" or mod_path == "" then
        return false
    end
    return package.loaded[mod_path] ~= nil
end

return M
