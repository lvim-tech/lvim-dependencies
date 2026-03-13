-- Highlight group setup — uses lvim-utils.highlight for persistent re-application
-- after colorscheme changes, and for color transforms (blend, lighten).

local config_highlight = require("lvim-dependencies.config.highlight")

local G = config_highlight.groups
local C = config_highlight.colors

local M = {}

function M.setup()
    local hl = require("lvim-utils").highlight
    hl.setup()
    hl.register({
        [G.loading] = { fg = C.loading, bold = true, default = true },
        [G.separator] = { fg = C.separator, bold = true, default = true },
        [G.info] = { bg = hl.blend(C.info, C.bg, C.alpha), fg = C.info, bold = true, default = true },
        [G.declared] = {
            bg = hl.blend(C.declared, C.bg, C.alpha),
            fg = C.declared,
            bold = true,
            default = true,
        },
        [G.installed] = {
            bg = hl.blend(C.installed, C.bg, C.alpha),
            fg = C.installed,
            bold = true,
            default = true,
        },
        [G.up_to_date] = {
            bg = hl.blend(C.success, C.bg, C.alpha),
            fg = C.success,
            bold = true,
            default = true,
        },
        [G.outdated] = {
            bg = hl.blend(C.error, C.bg, C.alpha),
            fg = C.error,
            bold = true,
            default = true,
        },
        [G.normal] = { bg = C.bg, fg = C.fg, default = true },
        [G.cursor_line] = {
            bg = hl.lighten(C.bg, C.light_amount),
            default = true,
        },
        [G.border] = { bg = C.bg, fg = C.fg, default = true },
        [G.title] = { bg = hl.blend(C.title, C.bg, C.alpha), fg = C.title, bold = true, default = true },
        [G.sub_title] = {
            bg = hl.blend(C.sub_title, C.bg, C.alpha),
            fg = C.sub_title,
            default = true,
        },
        [G.subject] = { bg = hl.blend(C.subject, C.bg, C.alpha), fg = C.subject, default = true },
        [G.navigation] = {
            bg = hl.blend(C.navigation, C.bg, C.alpha),
            fg = C.navigation,
            bold = true,
            default = true,
        },
        [G.line_active] = {
            bg = hl.blend(C.line_active, C.bg, C.alpha),
            fg = C.line_active,
            bold = true,
            default = true,
        },
        [G.line_inactive] = {
            bg = hl.blend(C.line_inactive, C.bg, C.alpha),
            fg = C.line_inactive,
            default = true,
        },
        [G.input] = { bg = hl.blend(C.input, C.bg, C.alpha), fg = C.input, default = true },
    })
end

return M
