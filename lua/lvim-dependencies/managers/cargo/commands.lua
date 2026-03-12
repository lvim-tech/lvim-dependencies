-- lvim-dependencies/managers/cargo/commands.lua
-- Cargo manager commands

local api = require("lvim-dependencies.managers.cargo.api")
local features = require("lvim-dependencies.managers.cargo.features")
local registry = require("lvim-dependencies.core.registry")
local utils = require("lvim-dependencies.utils")

local notify = utils.notify
local debug = utils.debug

---@class CargoCommands
local M = {}

--- Get subcommands for completion
---@param cmd_name string
---@return string[]|nil
function M.get_subcommands(cmd_name)
    local subcommands = {
        features = { "<package>" },
    }
    return subcommands[cmd_name]
end

-- ============================================================================
-- Features command
-- ============================================================================

--- FEATURES COMMAND: LvimDepsFeatures [package]
--- Shows and manages features for a package
---@param args string[] Command arguments
---@param manifest_type string Manager type (always "cargo")
---@param bufnr integer Buffer number
---@diagnostic disable-next-line: unused-local
function M.features(args, manifest_type, bufnr)
    local package = args[2]

    if not package then
        package = api.get_package_at_cursor({ bufnr = bufnr })
    end

    if not package then
        notify("No package specified", vim.log.levels.WARN)
        return
    end

    features.show_ui(package, bufnr)
end

-- ============================================================================
-- Setup
-- ============================================================================

--- Register all cargo commands with the registry
function M.setup()
    registry.register_command("cargo", "features", M.features)

    debug("Cargo commands registered", vim.log.levels.DEBUG)
end

return M
