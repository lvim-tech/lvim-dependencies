-- lvim-dependencies.managers.pubspec.parser: reads pubspec.yaml and returns the declared
-- dependencies as a name→raw-value map. Uses the manifest's file patterns, dependency sections
-- and special-key set (so section headers and keys like "sdk"/"git" never surface as packages).
-- Keeps a single-entry content cache keyed on the raw file text so an unchanged file is not
-- re-parsed on every virtual-text refresh.
--
---@module "lvim-dependencies.managers.pubspec.parser"

local tinyyaml = require("lvim-dependencies.libs.tinyyaml")
local utils = require("lvim-dependencies.utils")
local init = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class PubspecParser
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
---@return PubspecManifest|nil
local function get_manifest()
    local m = init.get_manifest("pubspec")
    ---@cast m PubspecManifest|nil
    return m
end

--- Read file content
---@param filename string
---@return string|nil
local function read_file(filename)
    local file = io.open(filename, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

--- Find first existing pubspec file
---@param patterns string[]
---@return string|nil content, string|nil path
local function find_first_existing_file(patterns)
    local root_dir = config.pubspec and config.pubspec.file_ops and config.pubspec.file_ops.root_dir
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

--- Parse YAML content safely
---@param content string
---@return table|nil
local function parse_yaml(content)
    local ok, data = pcall(tinyyaml.parse, content)
    if not ok or not data then
        debug(string.format("Failed to parse YAML: %s", tostring(data)), vim.log.levels.ERROR)
        return nil
    end
    return data
end

--- Build a lookup set from a list of strings
---@param list string[]
---@return table<string, boolean>
local function list_to_set(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

--- Extract dependencies from parsed YAML data
---@param data table
---@param sections string[]
---@param special_keys table<string, boolean>
---@return table<string, any>
local function extract_dependencies(data, sections, special_keys)
    local result = {}
    for _, section in ipairs(sections) do
        local deps = data[section]
        if deps and type(deps) == "table" then
            for name, version in pairs(deps) do
                if not special_keys[name] and not name:match("^_") then
                    result[name] = version
                end
            end
        end
    end
    return result
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Clear parser cache (content hash + result)
function M.clear_cache()
    cached_content = nil
    cached_result = nil
    debug("Parser cache cleared", vim.log.levels.INFO)
end

--- Get all dependencies from pubspec.yaml
---@return table<string, any>
function M.get_dependencies()
    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No manifest data, returning empty dependencies", vim.log.levels.ERROR)
        return {}
    end

    local patterns = manifest_data.file_patterns or { "pubspec.yaml", "pubspec.yml" }
    local content, found_path = find_first_existing_file(patterns)

    if not content then
        debug("No pubspec.yaml file found", vim.log.levels.WARN)
        return {}
    end

    -- Return cached parse if content hasn't changed
    if content == cached_content then
        return cached_result or {}
    end

    local data = parse_yaml(content)
    if not data then
        return {}
    end

    local sections = manifest_data.dependency_sections or { "dependencies", "dev_dependencies" }
    local special_keys = list_to_set(manifest_data.special_keys or {})
    local result = extract_dependencies(data, sections, special_keys)

    cached_content = content
    cached_result = result

    debug(
        string.format("Parsed %d packages from %s", vim.tbl_count(result), found_path or "pubspec.yaml"),
        vim.log.levels.INFO
    )

    return result
end

return M
