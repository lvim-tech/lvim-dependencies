-- lvim-dependencies.managers.go.parser: reads go.mod and extracts every require entry
-- (both the single-line `require x v1` form and the `require ( … )` block form, tracking
-- // indirect markers). Results are memoised on the raw file content — the same content
-- string short-circuits re-parsing — so repeated lookups during redraw are cheap; the cache
-- is invalidated via clear_cache() whenever an update mutates go.mod.
--
---@module "lvim-dependencies.managers.go.parser"

local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")

local debug = utils.debug

---@class GoParser
local M = {}

-- Content-hash cache
---@type string|nil
local cached_content = nil
---@type table<string, any>|nil
local cached_result = nil

-- ============================================================================
-- Helpers
-- ============================================================================

--- Locate the nearest go.mod by walking upward from the configured root (or cwd).
---@return string|nil
local function find_go_mod()
    local root_dir = config.go and config.go.file_ops and config.go.file_ops.root_dir
    local search = root_dir and vim.fn.expand(root_dir) or vim.fn.getcwd()

    local found = vim.fs.find("go.mod", { upward = true, path = search, type = "file" })
    return found and found[1] or nil
end

--- Slurp a file's full contents.
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

--- Parse a single require line: "github.com/pkg/errors v0.9.1" or "github.com/pkg/errors v0.9.1 // indirect"
---@param line string
---@return string|nil name, string|nil version, boolean indirect
local function parse_require_line(line)
    -- Strip trailing comment
    local clean = line:match("^(.-)%s*//.*$") or line
    clean = clean:match("^%s*(.-)%s*$") -- trim

    local name, ver = clean:match("^([%w%.%-%_/]+)%s+(v[%w%.%-%+]+)$")
    if not name or not ver then
        return nil, nil, false
    end

    local indirect = line:match("//.*indirect") ~= nil
    return name, ver, indirect
end

--- Parse go.mod content and extract all require entries
---@param content string
---@return table<string, any>
local function parse_content(content)
    local result = {}
    local in_block = false

    for line in content:gmatch("[^\n]+") do
        -- Single-line require: require github.com/pkg v1.0.0
        local single_name, single_ver = line:match("^%s*require%s+([%w%.%-%_/]+)%s+(v[%w%.%-%+]+)")
        if single_name and single_ver then
            local indirect = line:match("//.*indirect") ~= nil
            result[single_name] = {
                version = single_ver,
                indirect = indirect,
                section = "require",
            }
        -- Block start: require (
        elseif line:match("^%s*require%s*%(") then
            in_block = true
        -- Block end
        elseif in_block and line:match("^%s*%)") then
            in_block = false
        -- Inside block
        elseif in_block then
            local name, ver, indirect = parse_require_line(line)
            if name and ver then
                result[name] = {
                    version = ver,
                    indirect = indirect,
                    section = "require",
                }
            end
        end
    end

    return result
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Drop the content-hash cache so the next read re-parses go.mod.
function M.clear_cache()
    cached_content = nil
    cached_result = nil
    debug("go parser cache cleared", vim.log.levels.INFO)
end

---@return string|nil
function M.find_go_mod_path()
    return find_go_mod()
end

--- Get all dependencies from go.mod
---@return table<string, any>
function M.get_dependencies()
    local path = find_go_mod()
    if not path then
        debug("No go.mod found", vim.log.levels.WARN)
        return {}
    end

    local content = read_file(path)
    if not content then
        return {}
    end

    if content == cached_content then
        return cached_result or {}
    end

    local result = parse_content(content)

    cached_content = content
    cached_result = result

    debug(string.format("Parsed %d packages from %s", vim.tbl_count(result), path), vim.log.levels.INFO)
    return result
end

return M
