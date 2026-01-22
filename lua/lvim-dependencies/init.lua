local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")
-- local constants = require("lvim-dependencies.utils.constants")
local autocommands = require("lvim-dependencies.autocommands")
local highlight = require("lvim-dependencies.ui.highlight")

local M = {}

M.setup = function(user_config)
	if user_config ~= nil then
		utils.merge(config, user_config)
	end

	autocommands.init()

	highlight.setup()

	-- -- Създаване на user commands
	-- vim.api.nvim_create_user_command("LvimDepsToggle", function()
	-- 	config.virtual_text.enabled = not config.virtual_text.enabled
	-- 	utils.notify("Virtual text " .. (config.virtual_text.enabled and "enabled" or "disabled"))
	-- 	vim.cmd("edit")
	-- end, {})
	--
	-- vim.api.nvim_create_user_command("LvimDepsInfo", function()
	-- 	utils.notify("lvim-dependencies plugin loaded successfully!  ✨")
	-- end, {})
end

return M
