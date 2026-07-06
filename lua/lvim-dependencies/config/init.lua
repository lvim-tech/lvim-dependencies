-- lvim-dependencies.config: the aggregate config facade. Pulls every config submodule up onto
-- one table so callers require this single module and reach any setting via M.<area> or the
-- dotted M.get("area", "key"). The submodules are the live tables (setup merges into them in
-- place), so this facade always exposes the effective values.
---@module "lvim-dependencies.config"

local config_message = require("lvim-dependencies.config.message")
local config_manager = require("lvim-dependencies.config.manager")
local config_highlight = require("lvim-dependencies.config.highlight")
local config_groups = require("lvim-dependencies.config.groups")
local config_ui = require("lvim-dependencies.config.ui")
local config_lsp = require("lvim-dependencies.config.lsp")
local config_cache = require("lvim-dependencies.config.cache")
local config_async = require("lvim-dependencies.config.async")
local config_plugin = require("lvim-dependencies.config.plugin")
local config_pubspec = require("lvim-dependencies.config.pubspec")
local config_cargo = require("lvim-dependencies.config.cargo")
local config_npm = require("lvim-dependencies.config.npm")
local config_composer = require("lvim-dependencies.config.composer")
local config_go = require("lvim-dependencies.config.go")
local config_dock = require("lvim-dependencies.config.dock")

---@class Config
local M = {}

-- Existing modules
M.notify = config_message.notify
M.debug = config_message.debug
M.metrics = config_message.metrics
M.managers = config_manager
M.groups = config_groups
M.build = config_highlight.build
M.force = config_highlight.force
M.ui = config_ui
M.lsp = config_lsp
M.cache = config_cache
M.async = config_async
M.plugin = config_plugin
M.pubspec = config_pubspec
M.cargo = config_cargo
M.npm = config_npm
M.composer = config_composer
M.go = config_go
-- Dock-stack integration (namespaced to avoid colliding with the highlight-override `M.force`).
M.dock = config_dock

--- Get all configuration values as a single table
---@return table
function M.get_all()
    return {
        notify = M.notify,
        debug = M.debug,
        metrics = M.metrics,
        managers = M.managers,
        groups = M.groups,
        ui = M.ui,
        lsp = M.lsp,
        cache = M.cache,
        async = M.async,
        plugin = M.plugin,
        pubspec = M.pubspec,
        cargo = M.cargo,
        npm = M.npm,
        composer = M.composer,
        go = M.go,
        dock = M.dock,
    }
end

--- Get a specific configuration value using dot notation
---@param key string First level key
---@param ... string Additional keys for nested access
---@return any
function M.get(key, ...)
    local keys = { key, ... }
    local current = M
    for i = 1, #keys do
        current = current[keys[i]]
        if current == nil then
            return nil
        end
    end
    return current
end

return M
