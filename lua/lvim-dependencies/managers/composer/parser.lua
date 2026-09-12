-- lvim-dependencies.managers.composer.parser: decodes composer.json into a name → {version,
-- section, type} map of declared dependencies. Result is memoised against the file's raw
-- content (content-hash cache), so repeated reads are free until the file actually changes.
-- Each dep is classified as platform / vcs / registry — "php" and "php-*" are platform but
-- "phpunit"/"phpspec" are NOT, which is why the prefix test is exact.
--
---@module "lvim-dependencies.managers.composer.parser"

local json = require("lvim-dependencies.libs.json")
local utils = require("lvim-dependencies.utils")
local init = require("lvim-dependencies.core.init")
local project = require("lvim-dependencies.core.project")

local debug = utils.debug

---@class ComposerParser
local M = {}

--- Content-hash cache
---@type string|nil
local cached_content = nil
---@type table|nil
local cached_result = nil

local DEPENDENCY_SECTIONS = { "require", "require-dev" }

--- Platform package prefixes — skip registry lookup
--- "php" matches exactly or "php-*", NOT "phpunit" or "phpspec" etc.
local PLATFORM_PREFIXES = { "ext-", "lib-", "composer-" }

local function is_platform(name)
    -- "php" exact or "php-64bit" style — but NOT "phpunit", "phpspec", etc.
    if name == "php" or name:match("^php%-") then
        return true
    end
    for _, prefix in ipairs(PLATFORM_PREFIXES) do
        if name:match("^" .. vim.pesc(prefix)) then
            return true
        end
    end
    return false
end

local function get_manifest()
    local m = init.get_manifest("composer")
    ---@cast m ComposerManifest|nil
    return m
end

--- Find composer.json path, searching upward from the project root (the manifest buffer's
--- own directory — a monorepo package must read ITS composer.json, not the root's).
---@param opts? { root?: string, bufnr?: integer }
---@return string|nil
local function find_composer_json(opts)
    local manifest = get_manifest()
    local patterns = (manifest and manifest.file_patterns) or { "composer.json" }
    local found = vim.fs.find(patterns, {
        upward = true,
        path = project.search_root("composer", opts),
        type = "file",
    })
    return found and found[1] or nil
end

--- Parse all dependencies from composer.json
---@param opts? { root?: string }  project root (defaults per core.project.search_root)
---@return table<string, {version: string, section: string, type: string}>
function M.get_dependencies(opts)
    local path = find_composer_json(opts)
    if not path then
        return {}
    end

    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        return {}
    end

    -- Content-hash cache
    if content == cached_content and cached_result then
        return cached_result
    end

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        debug("composer: failed to parse composer.json", vim.log.levels.WARN)
        return {}
    end

    local result = {}
    for _, section in ipairs(DEPENDENCY_SECTIONS) do
        local deps = data[section]
        if type(deps) == "table" then
            for name, constraint in pairs(deps) do
                if type(name) == "string" and type(constraint) == "string" then
                    local dep_type = is_platform(name) and "platform"
                        or constraint:match("^dev%-") and "vcs"
                        or "registry"
                    result[name] = {
                        version = constraint,
                        section = section,
                        type = dep_type,
                    }
                end
            end
        end
    end

    cached_content = content
    cached_result = result
    debug(string.format("composer: parsed %d packages", vim.tbl_count(result)), vim.log.levels.INFO)
    return result
end

function M.clear_cache()
    cached_content = nil
    cached_result = nil
end

return M
