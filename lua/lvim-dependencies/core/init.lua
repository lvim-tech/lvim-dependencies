-- lvim-dependencies.core: per-manager module loader. Lazily requires a manager's
-- submodules (declared, latest, manifest, virtual_text) through ONE failure-caching
-- layer — a failed require is memoised as `false` so a broken/absent module is never
-- pcall'd again, and the available-manager list is scanned from package.path with a
-- short TTL so directory reads don't happen on every lookup.
--
---@module "lvim-dependencies.core"

local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")

-- ============================================================================
-- Constants
-- ============================================================================
local MANAGERS_PATH = "lvim-dependencies.managers"

local MODULE_FILES = {
    [const.MODULE_TYPES.DECLARED] = "declared",
    [const.MODULE_TYPES.LATEST] = "latest",
    [const.MODULE_TYPES.MANIFEST] = "manifest",
    [const.MODULE_TYPES.VIRTUAL_TEXT] = "virtual_text",
}

local REQUIRED_MODULES = {
    const.MODULE_TYPES.DECLARED,
    const.MODULE_TYPES.MANIFEST,
    const.MODULE_TYPES.VIRTUAL_TEXT,
}

local AVAILABLE_MANAGERS_TTL = config.cache.managers_cache_ttl or 5000

local M = {}

-- ============================================================================
-- Single module cache
-- Eliminates double caching (module_load_cache + CACHE_TEMP).
-- All modules go through here only.
-- ============================================================================

---@type table<string, table|false>
-- false = already attempted and failed (so we don't retry)
local module_load_cache = {}

local available_managers_cache = nil
local available_managers_timestamp = 0

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Load a manager module and cache it in the single cache.
--- Returns nil on failure; caches false so we don't pcall again.
---@param manager_type string
---@param module_type ManagerModuleType
---@return table|nil
local function load_manager_module(manager_type, module_type)
    local cache_key = manager_type .. ":" .. module_type

    local cached = module_load_cache[cache_key]
    if cached ~= nil then
        -- false means already attempted and failed
        return cached ~= false and cached or nil
    end

    local file_name = MODULE_FILES[module_type] or module_type
    local module_path = string.format("%s.%s.%s", MANAGERS_PATH, manager_type, file_name)

    local ok, mod = pcall(require, module_path)
    if ok and mod then
        module_load_cache[cache_key] = mod
        return mod
    end

    -- Mark as failed — do not retry
    module_load_cache[cache_key] = false
    return nil
end

--- Batch load multiple modules for a manager
---@param manager_type string
---@param module_types ManagerModuleType[]
---@return table<string, table|nil>
local function batch_load_modules(manager_type, module_types)
    local results = {}
    for _, mt in ipairs(module_types) do
        results[mt] = load_manager_module(manager_type, mt)
    end
    return results
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Get the loader module for a specific cache type
---@param manager_type string
---@param cache_type "declared"|"latest"
---@return table|nil
function M.get_loader(manager_type, cache_type)
    return load_manager_module(manager_type, cache_type)
end

--- Get the manifest module for a manager
---@param manager_type string
---@return ManagerManifest|nil
function M.get_manifest(manager_type)
    return load_manager_module(manager_type, const.MODULE_TYPES.MANIFEST)
end

--- Get the virtual text module for a manager
---@param manager_type string
---@return VirtualTextDef|nil
function M.get_virtual_text(manager_type)
    return load_manager_module(manager_type, const.MODULE_TYPES.VIRTUAL_TEXT)
end

--- Get all core modules for a manager in one call
---@param manager_type string
---@return table
function M.get_all_modules(manager_type)
    return batch_load_modules(manager_type, REQUIRED_MODULES)
end

--- Check if a manager has all required modules
---@param manager_type string
---@return boolean
function M.has_all_modules(manager_type)
    local modules = batch_load_modules(manager_type, REQUIRED_MODULES)
    for _, mt in ipairs(REQUIRED_MODULES) do
        if not modules[mt] then
            return false
        end
    end
    return true
end

--- Get all available manager types (with time-based caching)
---@return string[]
function M.get_available_managers()
    local now = vim.uv.now()

    if available_managers_cache and (now - available_managers_timestamp) < AVAILABLE_MANAGERS_TTL then
        return available_managers_cache
    end

    local managers = {}
    local scan_paths = {}
    local seen_dirs = {}
    local seen_managers = {}

    for path in package.path:gmatch("[^;]+") do
        if path:match("lvim%-dependencies") then
            local dir = path:gsub("/[^/]+$", "") .. "/managers"
            if not seen_dirs[dir] and vim.fn.isdirectory(dir) == 1 then
                seen_dirs[dir] = true
                table.insert(scan_paths, dir)
            end
        end
    end

    for _, path in ipairs(scan_paths) do
        local entries = vim.fn.readdir(path)
        if entries then
            for _, entry in ipairs(entries) do
                local full = path .. "/" .. entry
                if vim.fn.isdirectory(full) == 1 and not seen_managers[entry] then
                    seen_managers[entry] = true
                    table.insert(managers, entry)
                end
            end
        end
    end

    table.sort(managers)
    available_managers_cache = managers
    available_managers_timestamp = now
    return managers
end

--- Get a lazy-loaded manager proxy object
---@param manager_type string
---@return table
function M.get_manager(manager_type)
    local manager = { type = manager_type, _loaded = {} }

    setmetatable(manager, {
        __index = function(t, key)
            if MODULE_FILES[key] then
                local mod = load_manager_module(manager_type, key)
                t._loaded[key] = mod
                return mod
            end
            return nil
        end,
    })

    return manager
end

--- Clear module cache for a specific manager or all managers.
--- Also resets the available_managers_cache when clearing all.
---@param manager_type? string
function M.clear_cache(manager_type)
    if manager_type then
        local prefix = manager_type .. ":"
        for key in pairs(module_load_cache) do
            if key:sub(1, #prefix) == prefix then
                module_load_cache[key] = nil
            end
        end
    else
        module_load_cache = {}
        available_managers_cache = nil
        available_managers_timestamp = 0
    end
end

--- Reload all modules for a manager (alias for clear_cache)
---@param manager_type string
function M.reload_manager(manager_type)
    M.clear_cache(manager_type)
end

return M
