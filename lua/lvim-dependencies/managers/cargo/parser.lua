-- lvim-dependencies.managers.cargo.parser: reads the project's Cargo.toml and parses it into a
-- name→value dependency map (across all dependency sections, minus the special keys). Keeps a
-- content-hash cache (last parsed content + result) so an unchanged file is never re-parsed;
-- clear_cache() drops it after a write.
---@module "lvim-dependencies.managers.cargo.parser"

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

---@param filename string
---@return string|nil content
local function read_file(filename)
    local file = io.open(filename, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

--- Return the content + path of the first existing file among the given patterns,
--- searched relative to the configured root_dir (or cwd).
---@param patterns string[]
---@return string|nil content
---@return string|nil path
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

---@param content string
---@return table|nil
local function parse_toml(content)
    local ok, data = pcall(toml.parse, content)
    if not ok or not data then
        debug(string.format("Failed to parse TOML: %s", tostring(data)), vim.log.levels.ERROR)
        return nil
    end
    return data
end

---@param list string[]
---@return table<string, boolean>
local function list_to_set(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

--- Collect dependency entries from every dependency section, skipping special keys.
---@param data table parsed Cargo.toml
---@param sections string[]
---@param special_keys table<string, boolean>
---@return table<string, any>
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

--- Drop the content-hash cache so the next get_dependencies() re-parses from disk.
---@return nil
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
