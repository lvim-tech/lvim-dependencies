-- lvim-dependencies/managers/cargo/compare_versions.lua
-- Cargo version comparison utilities following SemVer

---@include "core/types.lua"

local utils = require("lvim-dependencies.utils")
local version = utils.version

-- Cargo uses strict SemVer: major.minor.patch[-prerelease][+build]
local CLEAN_PATTERN = "^[%^~><=]*"
local COMPONENT_PATTERN = "^(%d+)%.?(%d*)%.?(%d*)"

local parse_version = version.create_parser(CLEAN_PATTERN, COMPONENT_PATTERN)
local compare_versions = version.create_comparator(parse_version)

---@class CargoVersionCompare
local M = {}

--- Compare two cargo version strings
---@param v1_str string First version (e.g., "1.2.3", "1.2.3-beta.1")
---@param v2_str string Second version to compare against
---@return integer|nil -1 if v1 < v2, 0 if equal, 1 if v1 > v2, nil if invalid
function M.compare(v1_str, v2_str)
    return compare_versions(v1_str, v2_str)
end

--- Parse a cargo version string into its components
---@param version_str string Version string to parse
---@return VersionParseResult|nil Parsed version or nil if invalid
function M.parse(version_str)
    return parse_version(version_str)
end

--- Sort versions in ascending order (in place)
---@param versions string[]
---@return string[]
function M.sort(versions)
    return version.sort(versions, M.compare)
end

--- Sort versions in descending order (in place)
---@param versions string[]
---@return string[]
function M.sort_desc(versions)
    return version.sort_desc(versions, M.compare)
end

return M
