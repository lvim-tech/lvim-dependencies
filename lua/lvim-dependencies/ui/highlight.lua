-- lua/lvim-dependencies/ui/highlight.lua
-- Highlight group definitions for UI components

local utils_highlight = require("lvim-dependencies.utils.highlight")
local config_highlight = require("lvim-dependencies.config.highlight")

local config_highlight_groups = config_highlight.groups
local config_highlight_colors = config_highlight.colors

local M = {}

--- Initialize all plugin highlight groups
function M.setup()
    utils_highlight.define_if_missing(config_highlight_groups.loading, {
        fg = config_highlight_colors.loading,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.separator, {
        fg = config_highlight_colors.separator,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.info, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.info),
        fg = config_highlight_colors.info,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.declared, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.declared),
        fg = config_highlight_colors.declared,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.installed, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.installed),
        fg = config_highlight_colors.installed,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.up_to_date, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.success),
        fg = config_highlight_colors.success,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.outdated, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.error),
        fg = config_highlight_colors.error,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.normal, {
        bg = config_highlight_colors.bg,
        fg = config_highlight_colors.fg,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.cursor_line, {
        bg = utils_highlight.lighten(config_highlight_colors.bg),
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.border, {
        bg = config_highlight_colors.bg,
        fg = config_highlight_colors.fg,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.title, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.title),
        fg = config_highlight_colors.title,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.sub_title, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.sub_title),
        fg = config_highlight_colors.sub_title,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.subject, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.subject),
        fg = config_highlight_colors.subject,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.navigation, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.navigation),
        fg = config_highlight_colors.navigation,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.line_active, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.line_active),
        fg = config_highlight_colors.line_active,
        bold = true,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.line_inactive, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.line_inactive),
        fg = config_highlight_colors.line_inactive,
        default = true,
    })

    utils_highlight.define_if_missing(config_highlight_groups.input, {
        bg = utils_highlight.blend_with_background(config_highlight_colors.input),
        fg = config_highlight_colors.input,
        default = true,
    })
end

return M
