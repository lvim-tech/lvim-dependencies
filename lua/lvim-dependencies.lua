local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")

local M = {}

M.setup = function(user_config)
    if user_config ~= nil then
        local config_merge = utils.merge(config, user_config)
        config = config_merge
    end
    print(vim.inspect(config.jsts.az))
end

return M