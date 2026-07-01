-- lvim-dependencies.managers.cargo.register: cargo manager registration in two phases.
-- register() runs at plugin startup and wires only what is always needed (the command
-- handler with the executor + the cargo user commands). register_lsp() is deferred and only
-- runs when an LSP client actually needs cargo features (hover/actions/completion) — the
-- LSP-only modules stay unloaded until then, so LSP costs nothing when unused. The requires
-- inside both functions are inline ON PURPOSE (this lazy load is the module's whole reason).
---@module "lvim-dependencies.managers.cargo.register"

---@class CargoRegister
local M = {}

-- ============================================================================
-- PHASE 1: Startup Registration
-- Called once when the plugin initializes
-- Registers components that are always needed
-- ============================================================================

--- Register cargo manager core components. This runs at plugin startup.
---@return nil
function M.register()
    -- 1. Register the command handler with executor
    -- This must happen early because executor needs to know about cargo
    require("lvim-dependencies.managers.cargo.handler")

    -- 2. Setup cargo-specific commands
    -- These commands are available immediately after startup
    local commands = require("lvim-dependencies.managers.cargo.commands")
    commands.setup()

    -- Note: LSP features are NOT registered here!
    -- They will be lazy-loaded only when needed (see register_lsp below)
    -- This saves resources when LSP is not used
end

-- ============================================================================
-- PHASE 2: Lazy LSP Registration
-- Called only when an LSP client is active and needs cargo features
-- This optimizes startup time and memory usage
-- ============================================================================

--- Register cargo LSP features (hover, actions, completion).
--- Called lazily when get_lsp_handlers() is invoked.
---@return table|nil handlers Table containing LSP handlers, or nil if not available
function M.register_lsp()
    -- Get required modules
    -- These are loaded NOW, not at startup
    local registry = require("lvim-dependencies.core.registry")
    local lsp = require("lvim-dependencies.managers.cargo.lsp")

    -- Register code actions provider
    -- This enables LSP to show actions like "Update package", "Delete package", "Manage features"
    registry.register_actions("cargo", lsp.get_actions)

    -- Register hover provider
    -- This enables showing package info when hovering over dependencies
    registry.register_hover("cargo", lsp.get_hover)

    -- Setup any LSP-specific commands
    lsp.setup()

    -- Return handlers for the registry's lazy loading system
    -- These will be cached and used for future LSP requests
    return {
        hover = lsp.get_hover, -- Function to get hover information
        actions = lsp.get_actions, -- Function to get code actions
    }
end

return M
