local config = require("lvim-dependencies.config")

local M = {}

local function blend(fg, bg, alpha)
    if not fg or not bg then
        return fg or bg or "#000000"
    end

    fg = fg:gsub("^#", "")
    bg = bg:gsub("^#", "")

    local fg_r = tonumber(fg:sub(1, 2), 16) or 0
    local fg_g = tonumber(fg:sub(3, 4), 16) or 0
    local fg_b = tonumber(fg:sub(5, 6), 16) or 0

    local bg_r = tonumber(bg:sub(1, 2), 16) or 0
    local bg_g = tonumber(bg:sub(3, 4), 16) or 0
    local bg_b = tonumber(bg:sub(5, 6), 16) or 0

    local r = math.floor(fg_r * alpha + bg_r * (1 - alpha) + 0.5)
    local g = math.floor(fg_g * alpha + bg_g * (1 - alpha) + 0.5)
    local b = math.floor(fg_b * alpha + bg_b * (1 - alpha) + 0.5)

    r = math.max(0, math.min(255, r))
    g = math.max(0, math.min(255, g))
    b = math.max(0, math.min(255, b))

    return string.format("#%02x%02x%02x", r, g, b)
end

function M.blend_with_bg(color, alpha)
    local bg = config.ui.highlight.colors.bg or "#000000"
    return blend(color, bg, alpha)
end

function M.lighten(color, amount)
    return blend("#ffffff", color, amount)
end

function M.darken(color, amount)
    return blend("#000000", color, amount)
end

local function define_hl_if_missing(name, opts)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if not ok or not hl or vim.tbl_isempty(hl) then
        vim.api.nvim_set_hl(0, name, opts)
    end
end

local bg_blend = M.blend_with_bg(config.ui.highlight.colors.up_to_date, 0.3)
local up_to_date_blend = M.blend_with_bg(config.ui.highlight.colors.up_to_date, 0.2)
local outdated_blend = M.blend_with_bg(config.ui.highlight.colors.outdated, 0.2)
local loading_blend = M.blend_with_bg(config.ui.highlight.colors.loading, 0.2)
local line_active_blend = M.blend_with_bg(config.ui.highlight.colors.up_to_date, 0.3)

function M.init()
    define_hl_if_missing(config.ui.highlight.groups.normal, {
        bg = config.ui.highlight.colors.bg,
        fg = config.ui.highlight.colors.fg,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.title, {
        bg = bg_blend,
        fg = config.ui.highlight.colors.real,
        default = true,
        bold = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.sub_title, {
        bg = bg_blend,
        fg = config.ui.highlight.colors.real,
        default = true,
        underline = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.subject, {
        bg = bg_blend,
        fg = config.ui.highlight.colors.real,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.border, {
        bg = config.ui.highlight.colors.bg,
        fg = config.ui.highlight.colors.fg,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.line_active, {
        bg = line_active_blend,
        fg = config.ui.highlight.colors.up_to_date,
        default = true,
        bold = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.line_inactive, {
        fg = config.ui.highlight.colors.up_to_date,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.navigation, {
        bg = bg_blend,
        fg = config.ui.highlight.colors.real,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.input, {
        bg = bg_blend,
        fg = config.ui.highlight.colors.up_to_date,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.outdated, {
        bg = outdated_blend,
        fg = config.ui.highlight.colors.outdated,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.up_to_date, {
        bg = up_to_date_blend,
        fg = config.ui.highlight.colors.up_to_date,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.invalid, {
        fg = config.ui.highlight.colors.invalid,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.not_installed, {
        fg = config.ui.highlight.colors.not_installed,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.real, {
        fg = config.ui.highlight.colors.real,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.constraint, {
        fg = config.ui.highlight.colors.constraint,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.separator, {
        fg = config.ui.highlight.colors.separator,
        default = true,
    })
    define_hl_if_missing(config.ui.highlight.groups.loading, {
        bg = loading_blend,
        fg = config.ui.highlight.colors.loading,
        default = true,
    })
end

return M
