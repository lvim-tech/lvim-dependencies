-- lvim-dependencies.managers.pubspec.register: the registry entry point for the pubspec manager.
-- Registry calls M.register() at startup; it only pulls in the command handler (which self-registers
-- with the operator) — no LSP or user commands are wired here, that is the shared core's job.
--
---@module "lvim-dependencies.managers.pubspec.register"

---@class PubspecRegister
local M = {}

--- Register pubspec core components.
--- Called automatically by registry at plugin startup.
---@return nil
function M.register()
    -- Load handler so executor knows about pubspec
    require("lvim-dependencies.managers.pubspec.handler")
end

return M
