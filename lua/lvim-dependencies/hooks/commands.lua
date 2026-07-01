-- lvim-dependencies.hooks.commands: the :LvimDeps user command — a DISPATCHER ONLY.
-- Parses the sub-command and routes it first to a core cli command, then to a
-- manager-specific command for the current buffer's manifest type, else shows help.
-- Command names are pooled (core + manager) for tab completion.
--
---@module "lvim-dependencies.hooks.commands"

local registry = require("lvim-dependencies.core.registry")
local cli = require("lvim-dependencies.core.cli")
local utils = require("lvim-dependencies.utils")

local api = vim.api
local utils_buffer = utils.buffer
local notify = utils.notify

local M = {}

--- Get manifest type for current buffer
---@return string|nil
local function get_manifest_type()
    local buf = api.nvim_get_current_buf()
    local info = utils_buffer.get_info(buf)
    return info and registry.determine_manifest_type(info.filename) or nil
end

--- Load manager commands module
---@param manifest_type string
---@return table|nil
local function get_manager_commands(manifest_type)
    local ok, mod = pcall(require, string.format("lvim-dependencies.managers.%s.commands", manifest_type))
    return ok and mod or nil
end

--- Filter a list of strings by prefix
---@param list string[]
---@param prefix string
---@return string[]
local function filter_by_prefix(list, prefix)
    return vim.tbl_filter(function(c)
        return c:find(prefix, 1, true) == 1
    end, list)
end

--- Get all commands for completion (core + manager, deduplicated and sorted)
---@return string[]
local function get_all_command_names()
    local core_names = cli.get_command_names()
    local manager_names = registry.get_all_commands and registry.get_all_commands() or {}

    local all = {}
    local seen = {}
    for _, name in ipairs(core_names) do
        all[#all + 1] = name
        seen[name] = true
    end
    for _, name in ipairs(manager_names) do
        if not seen[name] then
            all[#all + 1] = name
            seen[name] = true
        end
    end
    table.sort(all)
    return all
end

--- Try to execute a core command
---@param cmd string
---@param args string[]
---@param manifest_type string|nil
---@param bufnr integer
---@return boolean executed
local function try_core_command(cmd, args, manifest_type, bufnr)
    local core_cmd = cli.get_commands()[cmd]
    if not core_cmd then
        return false
    end

    if core_cmd.needs_manifest and not manifest_type then
        notify("No manifest type found for current buffer", vim.log.levels.WARN)
        return true
    end

    core_cmd.handler(args, manifest_type, bufnr)
    return true
end

--- Try to execute a manager-specific command
---@param cmd string
---@param args string[]
---@param manifest_type string|nil
---@param bufnr integer
---@return boolean executed
local function try_manager_command(cmd, args, manifest_type, bufnr)
    if not manifest_type then
        return false
    end

    local manager_cmds = get_manager_commands(manifest_type)
    if not manager_cmds or not manager_cmds[cmd] then
        return false
    end

    manager_cmds[cmd](args, manifest_type, bufnr)
    return true
end

--- Handle unknown command: notify and show help
---@param cmd string
---@param bufnr integer
local function handle_unknown_command(cmd, bufnr)
    notify("Unknown command: " .. cmd, vim.log.levels.WARN)
    local help_cmd = cli.get_commands()["help"]
    if help_cmd then
        help_cmd.handler({ "help", "short" }, nil, bufnr)
    end
end

--- Get subcommand completions for a given main command
---@param main_cmd string
---@param arg_lead string
---@return string[]
local function complete_subcommands(main_cmd, arg_lead)
    local core_cmd = cli.get_commands()[main_cmd]
    if core_cmd then
        local subcmds = cli.get_subcommands(main_cmd)
        return subcmds and filter_by_prefix(subcmds, arg_lead) or {}
    end

    local manifest_type = get_manifest_type()
    if manifest_type then
        local manager_cmds = get_manager_commands(manifest_type)
        if manager_cmds and manager_cmds.get_subcommands then
            local subcmds = manager_cmds.get_subcommands(main_cmd)
            return subcmds and filter_by_prefix(subcmds, arg_lead) or {}
        end
    end

    return {}
end

--- Register the :LvimDeps user command (dispatch + completion).
function M.setup()
    api.nvim_create_user_command("LvimDeps", function(opts)
        local args = vim.split(opts.args or "", "%s+", { trimempty = true })
        local cmd = args[1] or "help"
        local manifest_type = get_manifest_type()
        local bufnr = api.nvim_get_current_buf()

        if try_core_command(cmd, args, manifest_type, bufnr) then
            return
        end

        if try_manager_command(cmd, args, manifest_type, bufnr) then
            return
        end

        handle_unknown_command(cmd, bufnr)
    end, {
        desc = "Lvim Dependencies",
        nargs = "*",
        complete = function(arg_lead, cmd_line)
            local parts = vim.split(cmd_line, "%s+", { trimempty = true })

            if #parts >= 2 then
                return complete_subcommands(parts[1], arg_lead)
            end

            if #parts == 1 then
                return filter_by_prefix(get_all_command_names(), arg_lead)
            end
        end,
    })
end

return M
