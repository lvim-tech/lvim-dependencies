-- lvim-dependencies.managers.go.compare_versions: semver comparison for Go module
-- versions. Go tags are always v-prefixed (v1.2.3), can carry a "+incompatible" build
-- suffix, and pseudo-versions encode a timestamp+commit (v0.0.0-20210101000000-abcdef012345);
-- the shared version helpers are seeded with Go-specific clean/component patterns so all the
-- comparators/sorters below treat those forms consistently.
--
---@module "lvim-dependencies.managers.go.compare_versions"

local utils = require("lvim-dependencies.utils")
local version = utils.version

-- Go versions always start with "v": v1.2.3, v1.2.3+incompatible, v0.0.0-20210101000000-abcdef012345
local CLEAN_PATTERN = "^v?"
local COMPONENT_PATTERN = "^(%d+)%.?(%d*)%.?(%d*)"

local parse_version = version.create_parser(CLEAN_PATTERN, COMPONENT_PATTERN)
local compare_versions = version.create_comparator(parse_version)

---@class GoVersionCompare
local M = {}

--- Standard semver comparison.
---@param v1_str string
---@param v2_str string
---@return integer|nil  -1, 0, 1, or nil if invalid
function M.compare(v1_str, v2_str)
    return compare_versions(v1_str, v2_str)
end

--- Check if a version is a pseudo-version (v0.0.0-20210101000000-abcdef012345)
---@param ver string
---@return boolean
function M.is_pseudo(ver)
    return ver ~= nil and ver:match("^v0%.0%.0%-%d+%-%x+$") ~= nil
end

--- Check if a version is a prerelease (contains "-" after patch, excluding pseudo-versions)
---@param ver string
---@return boolean
function M.is_prerelease(ver)
    if M.is_pseudo(ver) then
        return true
    end
    return ver ~= nil and ver:match("%d+%.%d+%.%d+%-") ~= nil
end

---@param version_str string
---@return VersionParseResult|nil
function M.parse(version_str)
    return parse_version(version_str)
end

---@param versions string[]
---@return string|nil
function M.latest(versions)
    return version.latest(versions, M.compare)
end

--- Sort ascending
---@param versions string[]
---@return string[]
function M.sort(versions)
    return version.sort(versions, M.compare)
end

--- Sort descending
---@param versions string[]
---@return string[]
function M.sort_desc(versions)
    return version.sort_desc(versions, M.compare)
end

return M
