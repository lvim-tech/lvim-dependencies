-- Highlight group setup — uses lvim-utils.highlight for persistent re-application
-- after colorscheme changes, and for color transforms (blend, lighten).

local G = require("lvim-dependencies.config.highlight").groups

local M = {}

function M.setup()
    local hl = require("lvim-utils").highlight
    local c  = require("lvim-utils.colors")
    hl.setup()
    hl.register({
        [G.loading]   = { fg = c.terminal_bg, bold = true, default = true },
        [G.separator] = { fg = c.cyan_dark, bold = true, default = true },
        [G.info]      = { bg = hl.blend(c.blue, c.bg_dark, 0.2), fg = c.blue, bold = true, default = true },
        [G.declared]  = {
            bg = hl.blend(c.magenta, c.bg_dark, 0.2),
            fg = c.magenta,
            bold = true,
            default = true,
        },
        [G.installed] = {
            bg = hl.blend(c.yellow, c.bg_dark, 0.2),
            fg = c.yellow,
            bold = true,
            default = true,
        },
        [G.up_to_date] = {
            bg = hl.blend(c.blue_dark, c.bg_dark, 0.2),
            fg = c.blue_dark,
            bold = true,
            default = true,
        },
        [G.outdated] = {
            bg = hl.blend(c.git.delete, c.bg_dark, 0.2),
            fg = c.git.delete,
            bold = true,
            default = true,
        },
        [G.normal]      = { bg = c.bg_dark, fg = c.fg_light, default = true },
        [G.cursor_line] = { bg = hl.lighten(c.bg_dark, 0.05), default = true },
        [G.border]      = { bg = c.bg_dark, fg = c.fg_light, default = true },
        [G.title] = {
            bg = hl.blend(c.purple, c.bg_dark, 0.2),
            fg = c.purple,
            bold = true,
            default = true,
        },
        [G.sub_title] = {
            bg = hl.blend(c.purple, c.bg_dark, 0.2),
            fg = c.purple,
            default = true,
        },
        [G.subject]    = { bg = hl.blend(c.yellow, c.bg_dark, 0.2), fg = c.yellow, default = true },
        [G.navigation] = {
            bg = hl.blend(c.terminal_bg, c.bg_dark, 0.2),
            fg = c.terminal_bg,
            bold = true,
            default = true,
        },
        [G.line_active] = {
            bg = hl.blend(c.blue, c.bg_dark, 0.2),
            fg = c.blue,
            bold = true,
            default = true,
        },
        [G.line_inactive] = {
            bg = hl.blend(c.blue, c.bg_dark, 0.2),
            fg = c.blue,
            default = true,
        },
        [G.input] = { bg = hl.blend(c.blue, c.bg_dark, 0.2), fg = c.blue, default = true },
    })
end

return M
