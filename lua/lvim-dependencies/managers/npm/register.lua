-- lvim-dependencies.managers.npm.register: the npm manager's registry entry point. It loads
-- only the core command handler (no LSP/commands) at plugin startup so the executor knows
-- how to dispatch npm operations; heavier modules are required lazily on demand.
--
---@module "lvim-dependencies.managers.npm.register"

---@class NpmRegister
local M = {}

--- Register npm core components.
--- Called automatically by registry at plugin startup.
function M.register()
    -- Load handler so executor knows about npm
    require("lvim-dependencies.managers.npm.handler")
end

return M
