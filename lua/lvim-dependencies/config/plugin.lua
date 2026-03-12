-- lvim-dependencies/config/plugin.lua
--- General plugin configuration
---@class PluginConfig

return {
    name = "lvim-dependencies",
    version = "1.0.0",
    --- Diagnostic settings
    diagnostics = {
        enabled = true, -- Enable diagnostic messages
        severity = vim.diagnostic.severity.WARN, -- Minimum severity level
    },
    --- Command settings
    commands = {
        prefix = "LvimDeps", -- Prefix for all plugin commands
        enabled = true, -- Enable/disable all commands
    },
    --- Autocommand settings
    autocommands = {
        enabled = true, -- Enable/disable all autocommands
        groups = {
            buffer = "LvimDepsBuffer", -- Autocommand group for buffer events
            lsp = "LvimDepsLSP", -- Autocommand group for LSP events
        },
    },
    --- State persistence settings
    state = {
        save_on_exit = true, -- Save plugin state when exiting Neovim
        auto_cleanup = true, -- Automatically clean up stale state
    },
}
