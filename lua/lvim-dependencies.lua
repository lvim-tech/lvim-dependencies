local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local M = {}

M.setup = function(user_config)
    if user_config ~= nil then
        utils.merge(config, user_config)
    end
    -- print(vim.inspect(config.jsts.az))
    -- print(config.jsts.az.nie)
end

return M
