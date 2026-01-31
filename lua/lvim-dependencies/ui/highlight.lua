local config = require("lvim-dependencies.config")

local M = {}

local function define_hl_if_missing(name, opts)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if not ok or not hl or vim.tbl_isempty(hl) then
		vim.api.nvim_set_hl(0, name, opts)
	end
end

function M.setup()
	define_hl_if_missing(config.ui.highlight.groups.normal, {
		bg = config.ui.highlight.colors.bg,
		fg = config.ui.highlight.colors.fg,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.title, {
		bg = config.ui.highlight.colors.separator,
		fg = config.ui.highlight.colors.outdated,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.sub_title, {
		bg = config.ui.highlight.colors.separator,
		fg = config.ui.highlight.colors.outdated,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.subject, {
		bg = config.ui.highlight.colors.separator,
		fg = config.ui.highlight.colors.outdated,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.border, {
		bg = config.ui.highlight.colors.bg,
		fg = config.ui.highlight.colors.fg,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.line_active, {
		bg = config.ui.highlight.colors.outdated,
		fg = config.ui.highlight.colors.fg,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.line_inactive, {
		bg = config.ui.highlight.colors.separator,
		fg = config.ui.highlight.colors.fg,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.navigation, {
		bg = config.ui.highlight.colors.separator,
		fg = config.ui.highlight.colors.fg,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.outdated, {
		fg = config.ui.highlight.colors.outdated,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.up_to_date, {
		fg = config.ui.highlight.colors.up_to_date,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.invalid, {
		fg = config.ui.highlight.colors.invalid,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.constraint_newer, {
		fg = config.ui.highlight.colors.constraint_newer,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.separator, {
		fg = config.ui.highlight.colors.separator,
		default = true,
	})
	define_hl_if_missing(config.ui.highlight.groups.loading, {
		fg = config.ui.highlight.colors.loading,
		default = true,
	})
end

return M
