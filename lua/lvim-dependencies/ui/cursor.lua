-- Cursor management — thin wrapper over lvim-utils.cursor

local M = {}

function M.setup()
    local cursor = require("lvim-utils").cursor
    cursor.setup({ filetypes = { "LvimDeps" } })
end

function M.mark_input_buffer(bufnr, is_input)
    local cursor = require("lvim-utils").cursor
    cursor.mark_input_buffer(bufnr, is_input)
end

return M
