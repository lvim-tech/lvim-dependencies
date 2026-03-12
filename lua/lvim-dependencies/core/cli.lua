-- lvim-dependencies/core/cli.lua
-- Core command registry and built-in command definitions

---@include "types.lua"

local registry = require("lvim-dependencies.core.registry")
local operation = require("lvim-dependencies.core.operation")
local operator = require("lvim-dependencies.core.operator")
local virtual_text = require("lvim-dependencies.core.virtual_text")
local cache = require("lvim-dependencies.core.cache")
local state = require("lvim-dependencies.core.state")
local metrics = require("lvim-dependencies.core.metrics")
local float = require("lvim-dependencies.ui.float")
local help = require("lvim-dependencies.hooks.help")
local async = require("lvim-dependencies.core.async_util")
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")

local notify = utils.notify
local M = {}

-- ============================================================================
-- Constants
-- ============================================================================
local CACHE_CATEGORIES = {
    const.CACHE_TYPES.DECLARED,
    const.CACHE_TYPES.INSTALLED,
    const.CACHE_TYPES.LATEST,
    const.CACHE_TYPES.MANIFEST,
    const.CACHE_TYPES.VIRTUAL_TEXT,
}

local CACHE_SUBCATEGORIES = vim.list_extend({ "all" }, CACHE_CATEGORIES)

local CACHE_CLEAR_COMMANDS = {
    { name = "clear-declared", cache_type = const.CACHE_TYPES.DECLARED, description = "Declared cache cleared" },
    { name = "clear-installed", cache_type = const.CACHE_TYPES.INSTALLED, description = "Installed cache cleared" },
    { name = "clear-latest", cache_type = const.CACHE_TYPES.LATEST, description = "Latest cache cleared" },
    { name = "clear-all-caches", cache_type = nil, description = "All caches cleared" },
}

-- ============================================================================
-- Registry entry type
-- ============================================================================

---@class CoreCommandEntry
---@field handler fun(args: string[], manifest_type: string|nil, bufnr: integer)
---@field needs_manifest boolean
---@field description string
---@field subcommands? string[]

---@type table<string, CoreCommandEntry>
local commands = {}

-- ============================================================================
-- Helpers
-- ============================================================================

--- Cache for manager command modules
local manager_commands_cache = {}

--- Get manager-specific commands module
---@param manifest_type string
---@return table|nil
local function get_manager_commands(manifest_type)
    if manager_commands_cache[manifest_type] then
        return manager_commands_cache[manifest_type]
    end
    local ok, cmds = pcall(require, string.format("lvim-dependencies.managers.%s.commands", manifest_type))
    if ok and cmds then
        manager_commands_cache[manifest_type] = cmds
        return cmds
    end
    return nil
end

--- Try to get package at cursor from manager-specific commands
---@param manifest_type string
---@param bufnr integer
---@return string|nil
local function get_package_from_manager(manifest_type, bufnr)
    local cmds = get_manager_commands(manifest_type)
    if cmds and cmds.get_package_at_cursor then
        return cmds.get_package_at_cursor(bufnr)
    end
    return nil
end

--- Guard that manifest_type is available
---@param manifest_type string|nil
---@return boolean
local function require_manifest(manifest_type)
    if not manifest_type then
        notify("No manifest type found", vim.log.levels.WARN)
        return false
    end
    return true
end

--- Run operation with async wrapper
---@param op_fn fun(cb: InstallerCallback)
---@param success_msg string
---@param error_msg string
local function run_operation(op_fn, success_msg, error_msg)
    async.run(function()
        local result = async.await(function(cb)
            op_fn(cb)
        end)

        if result and result.success then
            notify(success_msg, vim.log.levels.INFO)
        else
            notify((result and result.message) or error_msg, vim.log.levels.ERROR)
        end
    end)
end

--- Format title with proper capitalization
---@param str string
---@return string
local function format_title(str)
    return str:sub(1, 1):upper() .. str:sub(2)
end

-- ============================================================================
-- Command registry
-- ============================================================================

--- Register a core command
---@param name string
---@param handler fun(args: string[], manifest_type: string|nil, bufnr: integer)
---@param needs_manifest? boolean
---@param description? string
---@param subcommands? string[]|fun():string[]
function M.register(name, handler, needs_manifest, description, subcommands)
    local resolved_subs
    if type(subcommands) == "function" then
        resolved_subs = subcommands()
    else
        resolved_subs = subcommands
    end

    commands[name] = {
        handler = handler,
        needs_manifest = needs_manifest or false,
        description = description or "",
        subcommands = resolved_subs,
    }
end

--- Get all core commands
---@return table<string, CoreCommandEntry>
function M.get_commands()
    return commands
end

--- Get command names for completion
---@return string[]
function M.get_command_names()
    local names = {}
    for name in pairs(commands) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--- Get subcommands for a command
---@param cmd_name string
---@return string[]|nil
function M.get_subcommands(cmd_name)
    local cmd = commands[cmd_name]
    return cmd and cmd.subcommands
end

--- Register a cache clear command
---@param name string
---@param cache_type CacheType|nil
---@param description string
local function register_cache_clear(name, cache_type, description)
    M.register(name, function(_, manifest_type)
        if not require_manifest(manifest_type) then
            return
        end
        if cache_type then
            cache.clear(manifest_type, cache_type)
        else
            cache.clear_all(manifest_type)
        end
        notify(description, vim.log.levels.INFO)
    end, true, description)
end

-- ============================================================================
-- Help commands (no manifest needed)
-- ============================================================================

M.register(const.COMMANDS.HELP, function(args)
    if args[2] then
        if float and float.open then
            float.open(help.get_command_help(args[2]), string.format("LvimDeps help: %s", args[2]))
        else
            print(help.get_command_help(args[2])) -- fallback
        end
    else
        if float and float.open then
            float.open(help.get_main_help(), "LvimDeps Help")
        else
            print(help.get_main_help())
        end
    end
end, false, "Show help")

M.register(const.COMMANDS.SHOW_REGISTRY, function()
    float.open(registry.get_registry_info(), "LvimDeps Registry")
end, false, "Show registry information")

M.register(const.COMMANDS.SHOW_MANAGER, function(args, manifest_type)
    local manager = args[2] or manifest_type
    if not manager then
        notify("Usage: LvimDeps show-manager <manager>", vim.log.levels.WARN)
        return
    end
    local content = registry.get_manager_info(manager)
    if content then
        float.open(content, string.format("LvimDeps %s", manager))
    else
        notify(string.format("Manager '%s' not found", manager), vim.log.levels.ERROR)
    end
end, false, "Show manager information")

-- ============================================================================
-- Cache inspection commands (no manifest needed)
-- ============================================================================

M.register(const.COMMANDS.CACHE, function(args)
    local subcmd = args[2] or "all"
    local cache_data = cache.get() or {}

    if subcmd == "all" then
        local lines = { "# Cache Contents", "" }
        for _, category in ipairs(CACHE_CATEGORIES) do
            table.insert(lines, string.format("## %s", format_title(category)))
            table.insert(lines, vim.inspect(cache_data[category] or {}))
            table.insert(lines, "")
        end
        float.open(table.concat(lines, "\n"), "LvimDeps Cache")
    elseif vim.tbl_contains(CACHE_CATEGORIES, subcmd) then
        local title = format_title(subcmd)
        local lines = {
            string.format("# %s Cache", title),
            "",
            vim.inspect(cache_data[subcmd] or {}),
        }
        float.open(table.concat(lines, "\n"), string.format("LvimDeps Cache: %s", subcmd))
    else
        notify(
            string.format("Unknown cache type. Available: %s", table.concat(CACHE_SUBCATEGORIES, ", ")),
            vim.log.levels.WARN
        )
    end
end, false, "Inspect cache", CACHE_SUBCATEGORIES)

-- ============================================================================
-- State and metrics commands (no manifest needed)
-- ============================================================================

M.register(const.COMMANDS.STATE, function(_, _, bufnr)
    local buf = bufnr or vim.api.nvim_get_current_buf()
    local buffer_state = state._state.buffers[buf]
    if not buffer_state then
        notify(string.format("Buffer %d has no state", buf), vim.log.levels.WARN)
        return
    end

    local lines = {
        string.format("## Buffer %d State", buf),
        vim.inspect(buffer_state),
        "",
        "### Handlers Status:",
    }

    for name, handler in pairs(state._handlers) do
        local info = debug.getinfo(handler)
        local is_implemented = info.linedefined and info.linedefined > 0
        table.insert(lines, string.format("- %s: %s", name, is_implemented and "implemented" or "stub"))
    end

    float.open(table.concat(lines, "\n"), "LvimDeps State")
end, false, "Show buffer state")

M.register(const.COMMANDS.METRICS, function()
    if metrics.show then
        metrics.show()
    elseif metrics.report then
        local report = metrics.report()
        if type(report) == "string" then
            print(report)
        else
            notify(vim.inspect(report), vim.log.levels.INFO)
        end
    else
        notify("Metrics module has no show() or report() function", vim.log.levels.ERROR)
    end
end, false, "Show metrics")

-- ============================================================================
-- Package operations (need manifest)
-- ============================================================================

M.register(const.COMMANDS.INSTALL, function(_, manifest_type)
    if not require_manifest(manifest_type) then
        return
    end
    run_operation(function(cb)
        local op = operation.install(manifest_type, {}, {}, cb)
        operator.execute(op)
    end, "Installation completed", "Installation failed")
end, true, "Install a new package")

M.register(const.COMMANDS.UPDATE, function(args, manifest_type, bufnr)
    if not require_manifest(manifest_type) then
        return
    end
    local package = args[2] or get_package_from_manager(manifest_type, bufnr)
    run_operation(function(cb)
        local packages = package and { package } or {}
        local op = operation.update(manifest_type, packages, {}, cb)
        operator.execute(op)
    end, string.format("Update completed%s", package and (" for " .. package) or ""), "Update failed")
end, true, "Update a package")

M.register(const.COMMANDS.UPDATE_DIRECT, function(args, manifest_type, bufnr)
    if not require_manifest(manifest_type) then
        return
    end

    local package = args[2]
    local version = args[3]

    if not package or not version then
        local cmds = get_manager_commands(manifest_type)
        if cmds and cmds.get_package_and_version_at_cursor then
            local p, v = cmds.get_package_and_version_at_cursor(bufnr)
            package = package or p
            version = version or v
        end
    end

    if not package or not version then
        notify("Usage: update-direct <package> <version>", vim.log.levels.WARN)
        return
    end

    run_operation(function(cb)
        local op = operation.update_direct(manifest_type, package, version, {}, cb)
        operator.execute(op)
    end, string.format("Updated %s to %s", package, version), string.format("Update failed for %s", package))
end, true, "Direct update to specific version")

M.register(const.COMMANDS.DELETE, function(args, manifest_type, bufnr)
    if not require_manifest(manifest_type) then
        return
    end
    local package = args[2] or get_package_from_manager(manifest_type, bufnr)
    if not package then
        notify("No package specified", vim.log.levels.WARN)
        return
    end
    run_operation(function(cb)
        local op = operation.delete(manifest_type, { package }, {}, cb)
        operator.execute(op)
    end, string.format("Deleted %s", package), string.format("Delete failed for %s", package))
end, true, "Delete a package")

-- ============================================================================
-- Virtual text commands (need manifest)
-- ============================================================================

M.register(const.COMMANDS.SHOW, function(_, manifest_type, bufnr)
    if not require_manifest(manifest_type) then
        return
    end
    virtual_text.show(bufnr, manifest_type)
end, true, "Show virtual text")

M.register(const.COMMANDS.HIDE, function(_, _, bufnr)
    virtual_text.hide(bufnr)
end, true, "Hide virtual text")

M.register(const.COMMANDS.TOGGLE, function(_, manifest_type, bufnr)
    if not require_manifest(manifest_type) then
        return
    end
    virtual_text.toggle(bufnr, manifest_type)
end, true, "Toggle virtual text")

-- ============================================================================
-- Cache clear commands (need manifest)
-- ============================================================================

for _, cmd in ipairs(CACHE_CLEAR_COMMANDS) do
    register_cache_clear(cmd.name, cmd.cache_type, cmd.description)
end

return M
