-- lvim-dependencies.core.registry: discovers and holds every manager. On setup it scans
-- the runtime for managers/*/manifest.lua, registers each manifest + its file patterns,
-- then runs each manager's optional register module (commands/lsp/hover/actions). The
-- filename → manifest-type lookup is memoised in a BOUNDED, TTL'd cache with LRU eviction
-- so repeated buffer events on many files can't grow it without limit.
--
---@module "lvim-dependencies.core.registry"

local api = vim.api
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")
local config = require("lvim-dependencies.config")

local utils_module = utils.module
local debug = utils.debug
local now = vim.loop.now

-- ============================================================================
-- Constants
-- ============================================================================
local CORE_COMMANDS = {
    const.COMMANDS.HELP,
    const.COMMANDS.SHOW_REGISTRY,
    const.COMMANDS.SHOW_MANAGER,
    const.COMMANDS.CACHE,
    const.COMMANDS.STATE,
    const.COMMANDS.METRICS,
    const.COMMANDS.INSTALL,
    const.COMMANDS.UPDATE,
    const.COMMANDS.UPDATE_DIRECT,
    const.COMMANDS.DELETE,
    const.COMMANDS.SHOW,
    const.COMMANDS.HIDE,
    const.COMMANDS.TOGGLE,
    const.COMMANDS.CLEAR_DECLARED,
    const.COMMANDS.CLEAR_INSTALLED,
    const.COMMANDS.CLEAR_LATEST,
    const.COMMANDS.CLEAR_ALL,
}

local MANAGER_PATHS = const.MANAGER_PATHS
local MANAGER_KEY_PATTERN = "managers%.([^%.]+)%.manifest$"
local MANIFEST_CACHE_TTL = config.cache.manifest_type_cache_ttl or 5000

-- Maximum number of entries in manifest_type_cache before eviction
local MANIFEST_CACHE_MAX = config.cache.manifest_type_cache_max or 200

---@class RegistryModule
local M = {
    manifests = {},
    file_patterns = {},
    file_patterns_all = {},
    manager_commands = {},
    manager_lsp_handlers = {},
    manager_hover = {},
    manager_actions = {},
}

---@type table<string, boolean>
local initialized_managers = {}

---@type table<string, boolean>
local loaded_extensions = {}

-- ============================================================================
-- Bounded manifest_type_cache with automatic eviction
-- Solves the problem of unbounded cache growth.
-- ============================================================================

---@class ManifestCacheEntry
---@field result string|nil
---@field timestamp integer
---@field last_access integer

---@type table<string, ManifestCacheEntry>
local manifest_type_cache = {}
local manifest_type_cache_count = 0

--- Evict all expired entries and, if still over limit, oldest by last_access
local function evict_manifest_cache()
    local current_time = now()

    -- Safe to nil the current key during pairs() iteration per Lua spec
    for filename, entry in pairs(manifest_type_cache) do
        if (current_time - entry.timestamp) >= MANIFEST_CACHE_TTL then
            manifest_type_cache[filename] = nil
            manifest_type_cache_count = manifest_type_cache_count - 1
        end
    end

    -- If still over limit, evict oldest accessed entries
    if manifest_type_cache_count > MANIFEST_CACHE_MAX then
        local entries = {}
        for filename, entry in pairs(manifest_type_cache) do
            entries[#entries + 1] = { filename = filename, last_access = entry.last_access }
        end
        table.sort(entries, function(a, b)
            return a.last_access < b.last_access
        end)

        local to_remove = manifest_type_cache_count - math.floor(MANIFEST_CACHE_MAX * 0.75)
        for i = 1, to_remove do
            manifest_type_cache[entries[i].filename] = nil
            manifest_type_cache_count = manifest_type_cache_count - 1
        end
    end
end

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function update_metrics(manager_key)
    if metrics and metrics.stats and metrics.stats.cache and metrics.stats.cache.by_manager then
        metrics.stats.cache.by_manager[manager_key] = { hits = 0, misses = 0 }
    end
end

local function rebuild_flat_patterns()
    local patterns_all = {}
    local seen = {}
    for _, patterns in pairs(M.file_patterns) do
        for _, pattern in ipairs(patterns) do
            if not seen[pattern] then
                seen[pattern] = true
                patterns_all[#patterns_all + 1] = pattern
            end
        end
    end
    M.file_patterns_all = patterns_all
end

local function discover_manifests()
    local manifest_files = api.nvim_get_runtime_file(MANAGER_PATHS.MANIFEST_PATTERN, true)
    local module_paths = {}
    for _, file_path in ipairs(manifest_files) do
        local modpath = utils_module.filepath_to_modpath(file_path)
        if modpath then
            module_paths[#module_paths + 1] = modpath
        end
    end
    return module_paths
end

local function extract_manager_key(modpath)
    return modpath:match(MANAGER_KEY_PATTERN)
end

local function initialize_manager(manager_key)
    if initialized_managers[manager_key] then
        return
    end
    initialized_managers[manager_key] = true
end

local function register_manager(modpath)
    local manifest_module = utils_module.safe_require(modpath, true)
    if not manifest_module then
        debug(string.format("Failed to load manifest: %s", modpath), vim.log.levels.ERROR)
        return false
    end

    local key = manifest_module.key or extract_manager_key(modpath)
    if not key then
        debug(string.format("No manager key for: %s", modpath), vim.log.levels.ERROR)
        return false
    end

    M.manifests[key] = manifest_module
    M.file_patterns[key] = manifest_module.file_patterns or {}
    initialize_manager(key)

    local type_count = vim.tbl_count(manifest_module.dependency_types or {})
    debug(string.format("Registered %s with %d types", key, type_count), vim.log.levels.INFO)
    update_metrics(key)
    return true
end

local function load_all_manifests()
    local module_paths = discover_manifests()
    local count = 0
    for _, modpath in ipairs(module_paths) do
        if register_manager(modpath) then
            count = count + 1
        end
    end
    return count
end

local function register_all_extensions()
    for manager_key in pairs(M.manifests) do
        if not loaded_extensions[manager_key] then
            loaded_extensions[manager_key] = true
            local register_path = string.format(MANAGER_PATHS.REGISTER_MODULE, manager_key)
            local ok, register_mod = pcall(require, register_path)
            if ok and register_mod then
                if register_mod.register then
                    local reg_ok, reg_err = pcall(register_mod.register)
                    if not reg_ok then
                        debug(
                            string.format("Failed to register extensions for %s: %s", manager_key, tostring(reg_err)),
                            vim.log.levels.ERROR
                        )
                    else
                        debug(string.format("Registered extensions for %s", manager_key), vim.log.levels.DEBUG)
                    end
                end
                if register_mod.register_lsp then
                    local handlers = register_mod.register_lsp()
                    if handlers then
                        M.manager_lsp_handlers[manager_key] = handlers
                    end
                end
                if register_mod.register_hover then
                    local hover = register_mod.register_hover()
                    if hover then
                        M.manager_hover[manager_key] = hover
                    end
                end
                if register_mod.register_actions then
                    local actions = register_mod.register_actions()
                    if actions then
                        M.manager_actions[manager_key] = actions
                    end
                end
            end
        end
    end
end

local function clear_state()
    M.manifests = {}
    M.file_patterns = {}
    M.file_patterns_all = {}
    M.manager_commands = {}
    M.manager_lsp_handlers = {}
    M.manager_hover = {}
    M.manager_actions = {}
    initialized_managers = {}
    manifest_type_cache = {}
    manifest_type_cache_count = 0
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Discover and register all managers, then run their register modules.
function M.setup()
    local count = load_all_manifests()
    rebuild_flat_patterns()
    register_all_extensions()
    debug(string.format("Registry setup: %d managers registered", count), vim.log.levels.INFO)
end

--- Register a single manager by module path (e.g. for a dynamically added manager).
---@param modpath string
---@return boolean success
function M.register_modpath(modpath)
    local ok = register_manager(modpath)
    if ok then
        rebuild_flat_patterns()
    end
    return ok
end

--- Clear all registry state and re-discover every manager from scratch.
function M.reload()
    clear_state()
    local count = load_all_manifests()
    rebuild_flat_patterns()
    register_all_extensions()
    debug(string.format("Registry reloaded: %d managers", count), vim.log.levels.INFO)
end

--- Determine manifest type based on filename (bounded cache with eviction)
---@param filename string
---@return string|nil
function M.determine_manifest_type(filename)
    if not filename or type(filename) ~= "string" then
        return nil
    end

    local current_time = now()

    local cached = manifest_type_cache[filename]
    if cached and (current_time - cached.timestamp) < MANIFEST_CACHE_TTL then
        cached.last_access = current_time
        return cached.result
    end

    -- Lookup
    local result = nil
    for manager_key, patterns in pairs(M.file_patterns) do
        for _, pattern in ipairs(patterns) do
            if filename:match(pattern) then
                result = manager_key
                break
            end
        end
        if result then
            break
        end
    end

    -- Evict before inserting if at limit
    if not cached then
        if manifest_type_cache_count >= MANIFEST_CACHE_MAX then
            evict_manifest_cache()
        end
        manifest_type_cache_count = manifest_type_cache_count + 1
    end

    manifest_type_cache[filename] = {
        result = result,
        timestamp = current_time,
        last_access = current_time,
    }

    return result
end

--- All registered manager keys.
---@return string[]
function M.get_manifest_keys()
    local keys = {}
    for key in pairs(M.manifests) do
        keys[#keys + 1] = key
    end
    return keys
end

--- File patterns registered for a manager.
---@param manager_key string
---@return string[]|nil
function M.get_file_patterns(manager_key)
    return M.file_patterns[manager_key]
end

--- The manifest module registered for a manager.
---@param manager_key string
---@return ManagerManifest|nil
function M.get_manager(manager_key)
    return M.manifests[manager_key]
end

--- Whether a filename matches any registered manager's file patterns.
---@param filename string
---@return boolean
function M.is_manifest_file(filename)
    if not filename or type(filename) ~= "string" then
        return false
    end
    for _, pattern in ipairs(M.file_patterns_all) do
        if filename:match(pattern) then
            return true
        end
    end
    return false
end

local function format_type_indicators(type_def)
    return type_def.detect and "yes" or "no", type_def.extract and "yes" or "no"
end

--- Markdown summary of every registered manager (for the show-registry command).
---@return string
function M.get_registry_info()
    local lines = { "# Registry Information", "", "## Registered Managers", "" }
    local count = 0
    for name, manifest in pairs(M.manifests) do
        count = count + 1
        lines[#lines + 1] = string.format("### %s", name)
        lines[#lines + 1] = ""
        if manifest.dependency_types then
            lines[#lines + 1] = "**Dependency Types:**"
            for type_name, type_def in pairs(manifest.dependency_types) do
                local detect, extract = format_type_indicators(type_def)
                lines[#lines + 1] = string.format("- `%s` (detect: %s, extract: %s)", type_name, detect, extract)
            end
            lines[#lines + 1] = ""
        end
        local patterns = M.file_patterns[name] or {}
        if #patterns > 0 then
            lines[#lines + 1] = "**File Patterns:**"
            for _, pattern in ipairs(patterns) do
                lines[#lines + 1] = string.format("- `%s`", pattern)
            end
            lines[#lines + 1] = ""
        end
    end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = string.format("Total: **%d** managers registered", count)
    return table.concat(lines, "\n")
end

--- Markdown detail for a single manager (for the show-manager command).
---@param manager_key string
---@return string|nil
function M.get_manager_info(manager_key)
    local manifest = M.manifests[manager_key]
    if not manifest then
        return nil
    end

    local lines = { string.format("# Manager: %s", manager_key), "" }
    if manifest.dependency_types then
        lines[#lines + 1] = "## Dependency Types"
        lines[#lines + 1] = ""
        local max_type_len = 4
        for type_name in pairs(manifest.dependency_types) do
            max_type_len = math.max(max_type_len, #type_name)
        end
        lines[#lines + 1] = string.format("| %-" .. max_type_len .. "s | Detect | Extract |", "Type")
        lines[#lines + 1] = string.format("|%s|--------|---------|", string.rep("-", max_type_len + 2))
        for type_name, type_def in pairs(manifest.dependency_types) do
            local detect, extract = format_type_indicators(type_def)
            local name_padded = type_name .. string.rep(" ", max_type_len - #type_name)
            lines[#lines + 1] = string.format("| %s | %-6s | %-7s |", name_padded, detect, extract)
        end
        lines[#lines + 1] = ""
    end
    local patterns = M.file_patterns[manager_key] or {}
    if #patterns > 0 then
        lines[#lines + 1] = "## File Patterns"
        lines[#lines + 1] = ""
        for _, pattern in ipairs(patterns) do
            lines[#lines + 1] = string.format("- `%s`", pattern)
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

--- Register a manager-specific command handler.
---@param manager_type string
---@param command_name string
---@param handler fun(args: string[], manager_type: string, bufnr: integer)
function M.register_command(manager_type, command_name, handler)
    local cmds = M.manager_commands[manager_type]
    if not cmds then
        cmds = {}
        M.manager_commands[manager_type] = cmds
    end
    cmds[command_name] = handler
    debug(string.format("Registered command '%s' for %s", command_name, manager_type), vim.log.levels.DEBUG)
end

--- Register a manager's LSP handler table.
---@param manager_type string
---@param handlers table
function M.register_lsp_handlers(manager_type, handlers)
    M.manager_lsp_handlers[manager_type] = handlers
end

--- Register a manager's hover provider.
---@param manager_type string
---@param handler any
function M.register_hover(manager_type, handler)
    M.manager_hover[manager_type] = handler
end

--- Register a manager's code-actions provider.
---@param manager_type string
---@param handler any
function M.register_actions(manager_type, handler)
    M.manager_actions[manager_type] = handler
end

--- The hover provider registered for a manager, if any.
---@param manager_type string
---@return any
function M.get_hover_provider(manager_type)
    return M.manager_hover[manager_type]
end

--- The code-actions provider registered for a manager, if any.
---@param manager_type string
---@return any
function M.get_actions_provider(manager_type)
    return M.manager_actions[manager_type]
end

--- LSP handlers for a manager, lazily loading its register module on first use.
---@param manager_type string
---@return table|nil
function M.get_lsp_handlers(manager_type)
    if M.manager_lsp_handlers[manager_type] then
        return M.manager_lsp_handlers[manager_type]
    end
    local register_path = string.format(MANAGER_PATHS.REGISTER_MODULE, manager_type)
    local ok, register_mod = pcall(require, register_path)
    if ok and register_mod and register_mod.register_lsp then
        local handlers = register_mod.register_lsp()
        if handlers then
            M.manager_lsp_handlers[manager_type] = handlers
            return handlers
        end
    end
    return nil
end

--- The command table registered for a manager (name → handler).
---@param manager_type string
---@return table<string, function>
function M.get_manager_commands(manager_type)
    return M.manager_commands[manager_type] or {}
end

--- Run a manager-specific command; returns false if it isn't registered.
---@param manager_type string
---@param command_name string
---@param args string[]
---@param bufnr integer
---@return boolean handled
function M.execute_command(manager_type, command_name, args, bufnr)
    local cmds = M.manager_commands[manager_type]
    if not cmds or not cmds[command_name] then
        return false
    end
    cmds[command_name](args, manager_type, bufnr)
    return true
end

--- All command names (core + every manager's), sorted and de-duplicated.
---@return string[]
function M.get_all_commands()
    local commands = {}
    local seen = {}
    for _, cmd in ipairs(CORE_COMMANDS) do
        commands[#commands + 1] = cmd
        seen[cmd] = true
    end
    for _, cmds in pairs(M.manager_commands) do
        for cmd_name in pairs(cmds) do
            if not seen[cmd_name] then
                seen[cmd_name] = true
                commands[#commands + 1] = cmd_name
            end
        end
    end
    table.sort(commands)
    return commands
end

return M
