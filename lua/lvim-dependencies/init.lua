-- lvim-dependencies: entry point — merges the user config in place, wires the runtime
-- together and starts everything. Order matters: highlights and colours are registered
-- before the UI/metrics/registry so the first render already has the palette, and the
-- lvim-utils colour hook re-registers them on a live colorscheme switch; state handlers
-- are bound to the virtual-text module (a one-way dependency that avoids a require cycle
-- between core.state and core.virtual_text) before the LSP, autocmd and command layers arm.
--
---@module "lvim-dependencies"

local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")
local cursor = require("lvim-dependencies.ui.cursor")
local metrics = require("lvim-dependencies.core.metrics")
local registry = require("lvim-dependencies.core.registry")
local autocommands = require("lvim-dependencies.hooks.autocommands")
local commands = require("lvim-dependencies.hooks.commands")
local state = require("lvim-dependencies.core.state")
local lsp = require("lvim-dependencies.lsp")
local virtual_text = require("lvim-dependencies.core.virtual_text")

local utils_table = utils.table
local debug = utils.debug

local M = {}

--- Configure and start lvim-dependencies. Merges `user_config` into the live config in
--- place, registers highlights (and a colorscheme-change hook), then brings up metrics,
--- registry, state, LSP, autocmds and commands. No-op with an error notice on Neovim < 0.10.
---@param user_config? table  user overrides merged into the live config
---@return nil
function M.setup(user_config)
    if vim.fn.has("nvim-0.10") == 0 then
        vim.notify("lvim-dependencies requires Neovim >= 0.10", vim.log.levels.ERROR)
        return
    end
    if user_config ~= nil then
        debug("Merging user config", vim.log.levels.DEBUG)
        -- Merge via the SHARED lvim-utils.utils.merge (the one every lvim-tech plugin uses — clean array
        -- REPLACE, recursive map merge), falling back to the local table.merge when lvim-utils is absent so the
        -- plugin still works standalone.
        local ok_uu, uu = pcall(require, "lvim-utils.utils")
        if ok_uu and type(uu.merge) == "function" then
            uu.merge(config, user_config)
        else
            utils_table.merge(config, user_config)
        end
    end
    cursor.setup()

    local ok, hl = pcall(require, "lvim-utils.highlight")
    if ok then
        local utils_ok, utils_cfg = pcall(require, "lvim-utils.config")
        if utils_ok then
            hl.register(utils_cfg.colors)
        end
        hl.register(config.build(), config.force)
        hl.setup()
        local colors_ok, colors = pcall(require, "lvim-utils.colors")
        if colors_ok then
            colors.on_change(function()
                hl.register(config.build(), config.force)
            end)
        end
    end

    metrics.setup()

    registry.setup()

    state.setup()
    state.set_handlers({
        get_loaded_packages = virtual_text.get_loaded_packages,
        find_package_line = virtual_text.find_package_line,
        move_virt_texts_only = virtual_text.move_virt_texts_only,
        display_loading = virtual_text.display_loading,
        update_package = virtual_text.update_package,
        display_loading_for_package = virtual_text.display_loading_for_package,
        remove_package = virtual_text.remove_package,
        clear_buffer = virtual_text.clear_buffer,
    })

    lsp.setup()

    autocommands.setup()
    commands.setup()
end

return M
