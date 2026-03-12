-- lvim-dependencies/managers/go/register.lua
-- Go manager registration

local M = {}

--- Register Go core components.
--- Called automatically by registry at plugin startup.
function M.register()
    require("lvim-dependencies.managers.go.handler")
end

return M
