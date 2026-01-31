local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")
local autocommands = require("lvim-dependencies.autocommands")
local highlight = require("lvim-dependencies.ui.highlight")
local cursor = require("lvim-dependencies.ui.cursor")

local M = {}

M.setup = function(user_config)
	if user_config ~= nil then
		utils.merge(config, user_config)
	end
	autocommands.init()
	highlight.init()
    cursor.init()
end

return M
