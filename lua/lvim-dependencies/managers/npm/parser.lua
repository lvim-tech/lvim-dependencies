-- lvim-dependencies.managers.npm.parser: reads package.json and returns the declared
-- dependencies across every dependency section. It resolves the manifest upward from the
-- configured root (or cwd) and keeps a content-hash cache so re-parsing identical file
-- content is skipped (the hot path runs on every buffer refresh).
--
---@module "lvim-dependencies.managers.npm.parser"

local utils = require("lvim-dependencies.utils")
local init = require("lvim-dependencies.core.init")
local project = require("lvim-dependencies.core.project")

local debug = utils.debug

---@class NpmParser
local M = {}

-- Content-hash cache (avoids re-parsing identical file content)
---@type string|nil
local cached_content = nil
---@type table<string, any>|nil
local cached_result = nil

-- ============================================================================
-- Helpers
-- ============================================================================

---@return NpmManifest|nil
local function get_manifest()
    local m = init.get_manifest("npm")
    ---@cast m NpmManifest|nil
    return m
end

--- Locate the nearest package.json searching upward from the project root (the manifest
--- buffer's own directory — a workspace package must read ITS package.json, not the root's).
---@param opts? { root?: string, bufnr?: integer }
---@return string|nil
local function find_package_json(opts)
    local search = project.search_root("npm", opts)

    local found = vim.fs.find("package.json", { upward = true, path = search, type = "file" })
    return found and found[1] or nil
end

---@param path string
---@return string|nil
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- Turn a list of strings into a set for O(1) membership tests.
---@param list string[]
---@return table<string, boolean>
local function list_to_set(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v] = true
    end
    return set
end

--- Extract dependencies from parsed JSON across all sections
---@param data table
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
                    -- Store raw value with section info
                    result[name] = { version = value, section = section }
                end
            end
        end
    end
    return result
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Drop the content-hash cache so the next read re-parses package.json.
function M.clear_cache()
    cached_content = nil
    cached_result = nil
    debug("npm parser cache cleared", vim.log.levels.INFO)
end

--- package.json of the CURRENT manifest's project (the buffer being edited, else cwd).
---@return string|nil
function M.find_package_json_path()
    return find_package_json({ root = project.current_root("npm") })
end

--- Get all dependencies from package.json
---@param opts? { root?: string }  project root (defaults per core.project.search_root)
---@return table<string, any>
function M.get_dependencies(opts)
    local manifest_data = get_manifest()
    if not manifest_data then
        debug("No npm manifest data", vim.log.levels.ERROR)
        return {}
    end

    local path = find_package_json(opts)
    if not path then
        debug("No package.json found", vim.log.levels.WARN)
        return {}
    end

    local content = read_file(path)
    if not content then
        return {}
    end

    if content == cached_content then
        return cached_result or {}
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        debug("Failed to parse package.json", vim.log.levels.ERROR)
        return {}
    end

    local sections = manifest_data.dependency_sections
        or { "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" }
    local special_keys = list_to_set(manifest_data.special_keys or {})
    local result = extract_dependencies(data, sections, special_keys)

    cached_content = content
    cached_result = result

    debug(string.format("Parsed %d packages from %s", vim.tbl_count(result), path), vim.log.levels.INFO)
    return result
end

return M
