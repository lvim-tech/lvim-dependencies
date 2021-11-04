local config = require("modules.config")
local utils = require("modules.utils")

local M = {}

M.setup = function(user_config)
    if user_config ~= nil then
        local config_merge = utils.merge(config, user_config)
        config = config_merge
    end
end

return M