-- lvim-dependencies: highlight group definitions.
-- All colors come from lvim-utils.colors so the palette is shared across plugins.
-- Registered via lvim-utils.highlight — survive colorscheme changes.
--
-- build() must be a function so each call reads the current palette values.

local groups = require("lvim-dependencies.config.groups")

local function build()
    local c = require("lvim-utils.colors")
    local hl = require("lvim-utils.highlight")
    -- Drop the panel background (NONE) when the theme is transparent so the dependencies
    -- panel follows a translucent terminal; the tinted chrome cells keep their accents and
    -- the cursor line keeps a faint hex so the active row stays visible.
    local panel_bg = c.transparent and c.none or c.bg_dark
    return {
        [groups.loading] = { fg = c.terminal_bg, bold = true },
        [groups.separator] = { fg = c.cyan_dark, bold = true },
        [groups.info] = { bg = hl.blend(c.blue, c.bg_dark, 0.2), fg = c.blue, bold = true },
        [groups.declared] = { bg = hl.blend(c.magenta, c.bg_dark, 0.2), fg = c.magenta, bold = true },
        [groups.installed] = { bg = hl.blend(c.yellow, c.bg_dark, 0.2), fg = c.yellow, bold = true },
        [groups.up_to_date] = { bg = hl.blend(c.blue_dark, c.bg_dark, 0.2), fg = c.blue_dark, bold = true },
        [groups.outdated] = { bg = hl.blend(c.git.delete, c.bg_dark, 0.2), fg = c.git.delete, bold = true },
        [groups.normal] = { bg = panel_bg, fg = c.fg_light },
        [groups.cursor_line] = { bg = hl.lighten(c.bg_dark, 0.05) },
        [groups.border] = { bg = panel_bg, fg = c.fg_light },
        [groups.title] = { bg = hl.blend(c.purple, c.bg_dark, 0.2), fg = c.purple, bold = true },
        [groups.sub_title] = { bg = hl.blend(c.purple, c.bg_dark, 0.2), fg = c.purple },
        [groups.subject] = { bg = hl.blend(c.yellow, c.bg_dark, 0.2), fg = c.yellow },
        [groups.navigation] = { bg = hl.blend(c.terminal_bg, c.bg_dark, 0.2), fg = c.terminal_bg, bold = true },
        [groups.line_active] = { bg = hl.blend(c.blue, c.bg_dark, 0.2), fg = c.blue, bold = true },
        [groups.line_inactive] = { bg = hl.blend(c.blue, c.bg_dark, 0.2), fg = c.blue },
        [groups.input] = { bg = hl.blend(c.blue, c.bg_dark, 0.2), fg = c.blue },
    }
end

return {
    build = build,
    force = false,
}
