-- lvim-dependencies/utils/hl.lua
-- Highlight utilities for color manipulation and highlight group management

local config_highlight = require("lvim-dependencies.config.highlight")
local colors = config_highlight.colors

local M = {}

--- Convert hex color to RGB components
---@param hex string Color in hex format (e.g., "#RRGGBB")
---@return number r, number g, number b RGB values (0-255)
local function hex_to_rgb(hex)
    if not hex or hex == "" then
        return 0, 0, 0
    end

    hex = hex:gsub("^#", "")

    local r = tonumber(hex:sub(1, 2), 16) or 0
    local g = tonumber(hex:sub(3, 4), 16) or 0
    local b = tonumber(hex:sub(5, 6), 16) or 0

    return r, g, b
end

--- Convert RGB components to hex color
---@param r number Red component (0-255)
---@param g number Green component (0-255)
---@param b number Blue component (0-255)
---@return string Color in hex format
local function rgb_to_hex(r, g, b)
    r = math.max(0, math.min(255, r))
    g = math.max(0, math.min(255, g))
    b = math.max(0, math.min(255, b))

    return string.format("#%02x%02x%02x", r, g, b)
end

--- Blend two colors with alpha
---@param fg string Foreground color in hex format
---@param bg string Background color in hex format
---@param alpha number Blend factor (0-1, where 1 = fully fg, 0 = fully bg)
---@return string Blended color in hex format
local function blend_colors(fg, bg, alpha)
    if not fg or not bg then
        return fg or bg or "#000000"
    end

    local fg_r, fg_g, fg_b = hex_to_rgb(fg)
    local bg_r, bg_g, bg_b = hex_to_rgb(bg)

    local r = math.floor(fg_r * alpha + bg_r * (1 - alpha) + 0.5)
    local g = math.floor(fg_g * alpha + bg_g * (1 - alpha) + 0.5)
    local b = math.floor(fg_b * alpha + bg_b * (1 - alpha) + 0.5)

    return rgb_to_hex(r, g, b)
end

--- Blend color with background
---@param color string Color to blend
---@param bg string|nil Background color (defaults to config background)
---@param alpha number|nil Blend factor (defaults to config alpha)
---@return string Blended color
function M.blend_with_background(color, bg, alpha)
    bg = bg or colors.bg
    alpha = alpha or colors.alpha
    return blend_colors(color, bg, alpha)
end

--- Lighten a color by blending with a light color
---@param color string Color to lighten
---@param light_color string|nil Light color to blend with (defaults to config light)
---@param amount number|nil Blend amount (0-1, defaults to config light_amount)
---@return string Lightened color
function M.lighten(color, light_color, amount)
    light_color = light_color or colors.light
    amount = amount or colors.light_amount
    return blend_colors(light_color, color, amount)
end

--- Darken a color by blending with a dark color
---@param color string Color to darken
---@param dark_color string|nil Dark color to blend with (defaults to config dark)
---@param amount number|nil Blend amount (0-1, defaults to config dark_amount)
---@return string Darkened color
function M.darken(color, dark_color, amount)
    dark_color = dark_color or colors.dark
    amount = amount or colors.dark_amount
    return blend_colors(dark_color, color, amount)
end

--- Check if highlight group exists
---@param name string Highlight group name
---@return boolean True if group exists
function M.group_exists(name)
    local ok, hl_group = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl_group and not vim.tbl_isempty(hl_group)
end

--- Define highlight group if it doesn't exist
---@param name string Highlight group name
---@param opts table Highlight options (fg, bg, bold, etc.)
---@return boolean True if group was defined, false if already existed
function M.define_if_missing(name, opts)
    if not M.group_exists(name) then
        vim.api.nvim_set_hl(0, name, opts)
        return true
    end
    return false
end

--- Define or override highlight group
---@param name string Highlight group name
---@param opts table Highlight options (fg, bg, bold, etc.)
function M.define(name, opts)
    vim.api.nvim_set_hl(0, name, opts)
end

--- Clear highlight group
---@param name string Highlight group name
function M.clear(name)
    vim.api.nvim_set_hl(0, name, {})
end

--- Get highlight group attributes
---@param name string Highlight group name
---@return table|nil Highlight attributes or nil if not found
function M.get(name)
    local ok, hl_group = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl_group then
        return hl_group
    end
    return nil
end

--- Link highlight group to another
---@param name string Highlight group name
---@param link_to string Target group to link to
function M.link(name, link_to)
    vim.api.nvim_set_hl(0, name, { link = link_to })
end

return M
