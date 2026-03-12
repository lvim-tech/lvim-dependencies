-- lvim-dependencies/managers/composer/register.lua
-- Composer manager registration — core only, no LSP/commands

local M = {}

--- Register composer core components.
--- Called automatically by registry at plugin startup.
function M.register()
    -- Load handler so executor knows about composer
    require("lvim-dependencies.managers.composer.handler")
end

return M
