-- lvim-dependencies/managers/pubspec/register.lua
-- Composer manager registration — core only, no LSP/commands

local M = {}

--- Register pubspec core components.
--- Called automatically by registry at plugin startup.
function M.register()
    -- Load handler so executor knows about pubspec
    require("lvim-dependencies.managers.pubspec.handler")
end

return M
