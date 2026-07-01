-- lvim-dependencies.managers.composer.compare_versions: semver comparison built for Composer
-- version strings. Composer constraints carry range operators and a "v" prefix (e.g. "^1.2",
-- "~2.3", "v1.2.3"), so the parser strips those before comparing; a numeric-only variant
-- ignores the prerelease suffix. Thin wrapper over the shared lvim-utils.version engine.
--
---@module "lvim-dependencies.managers.composer.compare_versions"

local utils = require("lvim-dependencies.utils")
local version = utils.version

-- Composer versions: strip leading "^", "~", ">=", ">", "<", "=", "v", spaces
-- Also handle "~1.2" (tilde-range) and "^1.2" (caret-range)
local CLEAN_PATTERN = "^[%^~><=v%s]*"
local COMPONENT_PATTERN = "^(%d+)%.?(%d*)%.?(%d*)"

local parse_version = version.create_parser(CLEAN_PATTERN, COMPONENT_PATTERN)
local compare_versions = version.create_comparator(parse_version)

---@class ComposerVersionCompare
local M = {}

--- Standard semver comparison (prerelease < release)
---@param v1_str string
---@param v2_str string
---@return integer|nil  -1, 0, 1, or nil if invalid
function M.compare(v1_str, v2_str)
    return compare_versions(v1_str, v2_str)
end

--- Numeric-only comparison — ignores prerelease suffix
---@param v1_str string
---@param v2_str string
---@return integer|nil
function M.compare_numeric(v1_str, v2_str)
    local v1_base = (v1_str or ""):match("^([%d%.]+)") or v1_str
    local v2_base = (v2_str or ""):match("^([%d%.]+)") or v2_str
    return compare_versions(v1_base, v2_base)
end

---@param version_str string
---@return VersionParseResult|nil
function M.parse(version_str)
    return parse_version(version_str)
end

---@param version_str string
---@param constraint string
---@return boolean
function M.satisfies(version_str, constraint)
    return version.satisfies(version_str, constraint)
end

---@param versions string[]
---@return string|nil
function M.latest(versions)
    return version.latest(versions, M.compare)
end

---@param versions string[]
---@return string[]
function M.sort(versions)
    return version.sort(versions, M.compare)
end

---@param versions string[]
---@return string[]
function M.sort_desc(versions)
    return version.sort_desc(versions, M.compare)
end

---@param versions string[]
---@return string[]
function M.sort_desc_numeric(versions)
    return version.sort_desc(versions, M.compare_numeric)
end

return M
