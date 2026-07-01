-- lvim-dependencies.managers.composer.register: registry entry point for the composer manager.
-- The registry calls M.register() at startup; requiring the handler here (lazily, at call time
-- rather than at file-require time) is what registers it with the executor via the handler's
-- own load-time side effect — hoisting it to the top would change WHEN that registration fires.
--
---@module "lvim-dependencies.managers.composer.register"

local M = {}

--- Register composer core components with the executor.
--- Called automatically by the registry at plugin startup.
---@return nil
function M.register()
    -- Requiring the handler runs its load-time operator.register_handler side effect.
    require("lvim-dependencies.managers.composer.handler")
end

return M
