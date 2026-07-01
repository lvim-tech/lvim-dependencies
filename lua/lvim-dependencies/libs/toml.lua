-- lvim-dependencies.libs.toml: wrapper over vendored tinytoml (TOML from file or string)
---@module "lvim-dependencies.libs.toml"

-- Wrapper for tinytoml that supports both file and string input

local tinytoml = require("lvim-dependencies.libs.tinytoml")

local M = {}

--- Parse TOML from either a file or a string
---@param input string Either file path or TOML content
---@param options? table Parser options
---@return table|nil
function M.parse(input, options)
    options = options or {}

    -- Check if input is a file path (exists and is readable)
    local is_file = false
    local file = io.open(input, "r")
    if file then
        file:close()
        is_file = true
    end

    if is_file then
        -- Parse from file
        options.load_from_string = false
        return tinytoml.parse(input, options)
    else
        -- Parse from string
        options.load_from_string = true
        return tinytoml.parse(input, options)
    end
end

--- Encode table to TOML string
---@param input_table table Table to encode
---@param options? table Encoding options
---@return string
function M.encode(input_table, options)
    return tinytoml.encode(input_table, options)
end

return M
