local config = require("lvim-dependencies.config")

local M = {}

local function define_hl_if_missing(name, opts)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if not ok or not hl or vim.tbl_isempty(hl) then
		vim.api.nvim_set_hl(0, name, opts)
	end
end

function M.setup()
	define_hl_if_missing("LvimDepsOutdatedVersion", {
		fg = config.ui.highlight.outdated,
		default = true,
	})
	define_hl_if_missing("LvimDepsUpToDateVersion", {
		fg = config.ui.highlight.up_to_date,
		default = true,
	})
	define_hl_if_missing("LvimDepsInvalidVersion", {
		fg = config.ui.highlight.invalid,
		default = true,
	})
	define_hl_if_missing("LvimDepsConstraintNewer", {
		fg = config.ui.highlight.constraint_newer,
		default = true,
	})
	define_hl_if_missing("LvimDepsSeparator", {
		fg = config.ui.highlight.separator,
		default = true,
	})
end

return M
