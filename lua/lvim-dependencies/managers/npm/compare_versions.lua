-- lvim-dependencies.managers.npm.compare_versions: SemVer comparison for npm/yarn/pnpm.
-- Two comparators are exposed because npm mixes prerelease and stable dist-tags: `compare`
-- follows strict SemVer (prerelease < release) for constraint/declared-vs-installed checks,
-- while `compare_numeric` ignores the prerelease suffix so "which published tag is newest by
-- number" answers correctly (e.g. 7.21.4-esm.4 counts as newer than 7.18.6). Both are built
-- once from a shared parser wired to the npm-flavoured clean/component patterns.
--
---@module "lvim-dependencies.managers.npm.compare_versions"

local utils = require("lvim-dependencies.utils")
local version = utils.version

-- npm versions: strip leading "^", "~", ">", "<", "=", spaces
local CLEAN_PATTERN = "^[%^~><=v%s]*"
local COMPONENT_PATTERN = "^(%d+)%.?(%d*)%.?(%d*)"

local parse_version = version.create_parser(CLEAN_PATTERN, COMPONENT_PATTERN)
local compare_versions = version.create_comparator(parse_version)

---@class NpmVersionCompare
local M = {}

--- Standard semver comparison (prerelease < release).
--- Use for: declared vs installed, constraint satisfaction.
---   7.21.4-esm.4 < 7.21.4  (strict semver)
---@param v1_str string
---@param v2_str string
---@return integer|nil  -1, 0, 1, or nil if invalid
function M.compare(v1_str, v2_str)
    return compare_versions(v1_str, v2_str)
end

--- Numeric-only comparison — ignores prerelease suffix.
--- Use for: "which tag is the newest published version?"
---   7.21.4-esm.4 vs 7.18.6 → compares 7.21.4 vs 7.18.6 → 1 (newer)
---   7.21.4-esm.4 vs 7.21.4 → compares 7.21.4 vs 7.21.4 → 0 (same base)
--- Nil-tolerant: an absent side is treated as "" (never a valid version).
---@param v1_str string|nil
---@param v2_str string|nil
---@return integer|nil  -1, 0, 1, or nil if invalid
function M.compare_numeric(v1_str, v2_str)
    -- Strip prerelease suffix: "7.21.4-esm.4" → "7.21.4"
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

--- Sort ascending by strict semver (prerelease < release)
---@param versions string[]
---@return string[]
function M.sort(versions)
    return version.sort(versions, M.compare)
end

--- Sort descending by strict semver
---@param versions string[]
---@return string[]
function M.sort_desc(versions)
    return version.sort_desc(versions, M.compare)
end

--- Sort descending by numeric version only (ignores prerelease suffix).
--- Use when mixing prerelease and stable versions and want newest by number.
---@param versions string[]
---@return string[]
function M.sort_desc_numeric(versions)
    return version.sort_desc(versions, M.compare_numeric)
end

return M
