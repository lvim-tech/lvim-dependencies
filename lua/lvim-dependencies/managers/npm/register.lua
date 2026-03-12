-- lvim-dependencies/managers/npm/register.lua
-- Composer manager registration — core only, no LSP/commands

local M = {}

--- Register npm core components.
--- Called automatically by registry at plugin startup.
function M.register()
    -- Load handler so executor knows about npm
    require("lvim-dependencies.managers.npm.handler")
end

return M
