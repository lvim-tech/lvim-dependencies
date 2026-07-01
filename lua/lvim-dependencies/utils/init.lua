-- lvim-dependencies.utils: single entry point that aggregates every utility submodule
-- under one table, so callers can `require("lvim-dependencies.utils")` and reach each
-- helper as a field instead of requiring each file by path.
--
---@module "lvim-dependencies.utils"

local M = {}

M.buffer = require("lvim-dependencies.utils.buffer")
M.debug = require("lvim-dependencies.utils.debug")
M.file_system = require("lvim-dependencies.utils.file_system")
M.highlight = require("lvim-dependencies.utils.highlight")
M.http = require("lvim-dependencies.utils.http")
M.levels = require("lvim-dependencies.utils.levels")
M.lsp = require("lvim-dependencies.utils.lsp")
M.module = require("lvim-dependencies.utils.module")
M.notify = require("lvim-dependencies.utils.notify")
M.table = require("lvim-dependencies.utils.table")
M.version = require("lvim-dependencies.utils.version")

return M
