-- lvim-dependencies/managers/composer/data/declared.lua
-- Declared dependency data for composer

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local parser = require("lvim-dependencies.managers.composer.parser")

local debug = utils.debug

---@class ComposerDeclared
local M = {}

---@param package_name string
---@param callback fun(err: string|nil, data: table|nil)
function M.get_package_declared(package_name, callback)
    local all = parser.get_dependencies()
    local raw = all[package_name]
    if not raw then
        debug(string.format("composer: package not found in declared: %s", package_name), vim.log.levels.DEBUG)
        callback(nil, nil)
        return
    end

    local data = {
        name = package_name,
        declared = raw.version,
        raw = raw.version,
        section = raw.section,
        type = raw.type,
    }
    callback(nil, data)
end

---@return table<string, table>
function M.get_data()
    local all = parser.get_dependencies()
    local result = {}
    for name, raw in pairs(all) do
        result[name] = {
            name = name,
            declared = raw.version,
            raw = raw.version,
            section = raw.section,
            type = raw.type,
        }
    end
    return result
end

function M.clear_cache()
    parser.clear_cache()
end

return M
