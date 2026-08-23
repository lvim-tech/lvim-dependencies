-- lvim-dependencies.core: per-manager module loader. Lazily requires a manager's
-- submodules (declared, latest, manifest, virtual_text) through ONE failure-caching
-- layer — a failed require is memoised as `false` so a broken/absent module is never
-- pcall'd again. WHICH managers exist is not decided here: core.registry owns that list
-- (it discovers them off the runtimepath and honours the config's enable flags).
--
---@module "lvim-dependencies.core"

local const = require("lvim-dependencies.core.const")

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

local M = {}

-- ============================================================================
-- Single module cache
-- Eliminates double caching (module_load_cache + CACHE_TEMP).
-- All modules go through here only.
-- ============================================================================

---@type table<string, table|false>
-- false = already attempted and failed (so we don't retry)
local module_load_cache = {}

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
    end
end

--- Reload all modules for a manager (alias for clear_cache)
---@param manager_type string
function M.reload_manager(manager_type)
    M.clear_cache(manager_type)
end

return M
