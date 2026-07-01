-- lvim-dependencies.managers.go.register: the entry point the core registry calls at
-- startup to wire the Go manager in. It only requires the handler (which self-registers with
-- the operator on load); that require stays inline so the handler — and the operator
-- registration it performs — is not pulled in until the registry actually activates Go.
--
---@module "lvim-dependencies.managers.go.register"

local M = {}

--- Register Go core components.
--- Called automatically by registry at plugin startup.
---@return nil
function M.register()
    require("lvim-dependencies.managers.go.handler")
end

return M
