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

function M.setup(user_config)
    if user_config ~= nil then
        debug("Merging user config", vim.log.levels.DEBUG)
        utils_table.merge(config, user_config)
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
        check_for_new_packages = virtual_text.check_for_new_packages,
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
