-- lvim-dependencies.managers.go.utils.helpers: small Go-specific query helpers used across
-- the manager — manifest access, go.mod section/indirect lookups (via the parser), stdlib
-- detection (a first path element with no dot), and proxy path encoding (uppercase → !lower,
-- per golang.org/x/mod/module.EscapePath).
--
---@module "lvim-dependencies.managers.go.utils.helpers"

local utils = require("lvim-dependencies.utils")
local init = require("lvim-dependencies.core.init")
local parser = require("lvim-dependencies.managers.go.parser")

local debug = utils.debug

---@class GoHelpers
local M = {}

--- Get the Go manifest
---@return GoManifest|nil
function M.get_manifest()
    local m = init.get_manifest("go")
    ---@cast m GoManifest|nil
    return m
end

--- Find the section of a package in go.mod
---@param name string
---@return string|nil
function M.find_package_section(name)
    local deps = parser.get_dependencies()
    local pkg = deps[name]
    return pkg and pkg.section or "require"
end

--- Encode a Go module path for use in proxy URLs.
--- Go proxy uses module path encoding where uppercase letters are replaced
--- with "!" + lowercase: "GitHub.com" → "!github.com"
--- Reference: https://pkg.go.dev/golang.org/x/mod/module#EscapePath
---@param module_path string
---@return string
function M.encode_module_path(module_path)
    -- Replace uppercase letters with !+lowercase
    return (module_path:gsub("[A-Z]", function(c)
        return "!" .. c:lower()
    end))
end

--- Check if a module is in the standard library (no dot in first path element)
---@param name string
---@return boolean
function M.is_stdlib(name)
    local first = name:match("^([^/]+)")
    return first ~= nil and not first:match("%.")
end

--- Check if a module is indirect
---@param name string
---@return boolean
function M.is_indirect(name)
    local deps = parser.get_dependencies()
    local pkg = deps[name]
    return pkg ~= nil and pkg.indirect == true
end

debug("go helpers loaded", vim.log.levels.DEBUG)

return M
