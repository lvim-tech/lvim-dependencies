-- lvim-dependencies/managers/cargo/parser.lua
-- Parser for Cargo.toml files using manifest configuration

---@include "core/types.lua"

local toml = require("lvim-dependencies.libs.toml")
local utils = require("lvim-dependencies.utils")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class CargoParser
local M = {}

-- Content cache (avoids re-parsing identical file content)
---@type string|nil
local cached_content = nil
---@type table<string, any>|nil
local cached_result = nil

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get manifest (init.lua owns the cache)
---@return CargoManifest|nil
local function get_manifest()
    local m = init.get_manifest("cargo")
    ---@cast m CargoManifest|nil
    return m
end

local function read_file(filename)
    local file = io.open(filename, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function find_first_existing_file(patterns)
    local root_dir = config.cargo and config.cargo.file_ops and config.cargo.file_ops.root_dir
    local search_path = root_dir and vim.fn.expand(root_dir) or "."
    for _, pattern in ipairs(patterns) do
        local full_path = search_path .. "/" .. pattern
        local content = read_file(full_path)
        if content then
            return content, full_path
        end
    end
    return nil, nil
end

local function parse_toml(content)
    local ok, data = pcall(toml.parse, content)
    if not ok or not data then
        debug(string.format("Failed to parse TOML: %s", tostring(data)), vim.log.levels.ERROR)
        return nil
    end
    return data
end

local function list_to_set(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

local function extract_dependencies(data, sections, special_keys)
    local result = {}
    for _, section in ipairs(sections) do
        local deps = data[section]
        if deps and type(deps) == "table" then
            for name, value in pairs(deps) do
                if not special_keys[name] then
                    result[name] = value
                end
            end
        end
    end
    return result
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.clear_cache()
    cached_content = nil
    cached_result = nil
    debug("Parser cache cleared", vim.log.levels.INFO)
end

--- Get all dependencies from Cargo.toml
---@return table<string, any>
function M.get_dependencies()
    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No manifest data, returning empty dependencies", vim.log.levels.ERROR)
        return {}
    end

    local patterns = manifest_data.file_patterns or { "Cargo.toml" }
    local content, found_path = find_first_existing_file(patterns)

    if not content then
        debug("No Cargo.toml file found", vim.log.levels.WARN)
        return {}
    end

    if content == cached_content then
        return cached_result or {}
    end

    local data = parse_toml(content)
    if not data then
        return {}
    end

    local sections = manifest_data.dependency_sections or { "dependencies", "dev-dependencies", "build-dependencies" }
    local special_keys = list_to_set(manifest_data.special_keys or {})
    local result = extract_dependencies(data, sections, special_keys)

    cached_content = content
    cached_result = result

    debug(
        string.format("Parsed %d packages from %s", vim.tbl_count(result), found_path or "Cargo.toml"),
        vim.log.levels.INFO
    )

    return result
end

return M
