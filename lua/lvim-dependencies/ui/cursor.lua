-- lvim-dependencies.ui.cursor: thin wrapper over the shared lvim-utils.cursor module.
-- lvim-utils is required lazily inside each function (cross-plugin dependency) so this
-- module can load before lvim-utils is on the runtimepath.
--
---@module "lvim-dependencies.ui.cursor"

local M = {}

--- Register the plugin's popup filetype so the hardware cursor is hidden in it.
function M.setup()
    local cursor = require("lvim-utils").cursor
    cursor.setup({ filetypes = { "LvimDeps" } })
end

--- Keep (or stop keeping) the cursor visible in an input buffer with a hidden filetype.
---@param bufnr integer
---@param is_input boolean
function M.mark_input_buffer(bufnr, is_input)
    local cursor = require("lvim-utils").cursor
    cursor.mark_input_buffer(bufnr, is_input)
end

return M
