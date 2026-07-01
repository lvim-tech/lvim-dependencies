-- lvim-dependencies.utils.version: semantic-version parsing, comparison, constraint
-- satisfaction and collection ops (latest/sort). Because each package manager spells
-- versions differently, the core parser is pattern-driven and exposed through factories
-- (create_parser/comparator/utils) so a manager can supply its own clean/component patterns
-- while the semver helpers cover the common case.
--
---@module "lvim-dependencies.utils.version"

local M = {}

---@class ParsedVersion
---@field major integer Major version number
---@field minor integer Minor version number
---@field patch integer Patch version number
---@field prerelease string Prerelease identifier (e.g., "beta", "rc1")
---@field build string Build metadata
---@field original string Original version string

---@alias ComparatorResult -1|0|1
---@alias VersionComparator fun(v1: string, v2: string): ComparatorResult|nil
---@alias VersionParser fun(version: string): ParsedVersion|nil
---@alias VersionUtils {parse: VersionParser, compare: VersionComparator, satisfies: fun(version: string, constraint: string): boolean}

--- Default patterns for semantic version parsing
local DEFAULT_CLEAN_PATTERN = "^[%^~><=]*"
local DEFAULT_COMPONENT_PATTERN = "^(%d+)%.?(%d*)%.?(%d*)"

--- Validate that a value is a non-empty string
---@param val any
---@return boolean
local function is_nonempty_string(val)
    return type(val) == "string" and val ~= ""
end

--- Parse a version string into components
---@param version_str string Version string to parse
---@param clean_pattern? string Pattern to clean version string
---@param component_pattern? string Pattern to extract version components
---@return ParsedVersion|nil
local function parse_version(version_str, clean_pattern, component_pattern)
    if not is_nonempty_string(version_str) then
        return nil
    end

    local clean = version_str:gsub(clean_pattern or DEFAULT_CLEAN_PATTERN, "")
    local major, minor, patch = clean:match(component_pattern or DEFAULT_COMPONENT_PATTERN)

    if not major then
        return nil
    end

    return {
        major = tonumber(major) or 0,
        minor = tonumber(minor) or 0,
        patch = tonumber(patch) or 0,
        prerelease = clean:match("%-(.+)") or "",
        build = clean:match("%+(.+)") or "",
        original = version_str,
    }
end

--- Compare two parsed version tables field by field
---@param v1 ParsedVersion
---@param v2 ParsedVersion
---@return ComparatorResult
local function compare_parsed(v1, v2)
    -- Compare major.minor.patch
    for _, field in ipairs({ "major", "minor", "patch" }) do
        if v1[field] > v2[field] then
            return 1
        end
        if v1[field] < v2[field] then
            return -1
        end
    end

    -- Release (no prerelease) > prerelease
    local v1_has_pre = v1.prerelease ~= ""
    local v2_has_pre = v2.prerelease ~= ""
    if not v1_has_pre and v2_has_pre then
        return 1
    end
    if v1_has_pre and not v2_has_pre then
        return -1
    end

    -- Lexicographic prerelease comparison
    if v1_has_pre and v2_has_pre then
        if v1.prerelease > v2.prerelease then
            return 1
        end
        if v1.prerelease < v2.prerelease then
            return -1
        end
    end

    return 0
end

--- Sort a version list in place using a comparator and a fallback direction
---@param versions string[]
---@param comparator VersionComparator
---@param ascending boolean True for ascending, false for descending
---@return string[]
local function sort_versions(versions, comparator, ascending)
    if type(versions) ~= "table" then
        return {}
    end

    local target = ascending and -1 or 1
    local fallback_less = ascending

    table.sort(versions, function(a, b)
        local result = comparator(a, b)
        if result == nil then
            if fallback_less then
                return a < b
            end
            return a > b
        end
        return result == target
    end)

    return versions
end

-- ============================================================================
-- Public API — Factories
-- ============================================================================

--- Create a version parser function with custom patterns
---@param clean_pattern? string Pattern to clean version string
---@param component_pattern? string Pattern to extract version components
---@return VersionParser
function M.create_parser(clean_pattern, component_pattern)
    return function(version_str)
        return parse_version(version_str, clean_pattern, component_pattern)
    end
end

--- Create a version comparator function from a parser
---@param parse_fn VersionParser
---@return VersionComparator
function M.create_comparator(parse_fn)
    return function(v1_str, v2_str)
        if not is_nonempty_string(v1_str) or not is_nonempty_string(v2_str) then
            return nil
        end

        if v1_str == v2_str then
            return 0
        end

        local v1 = parse_fn(v1_str)
        local v2 = parse_fn(v2_str)

        if not v1 or not v2 then
            return nil
        end

        return compare_parsed(v1, v2)
    end
end

--- Create a complete version utilities set for a manager
---@param clean_pattern? string Custom pattern to clean version strings
---@param component_pattern? string Custom pattern to extract components
---@return VersionUtils
function M.create_utils(clean_pattern, component_pattern)
    local parse = M.create_parser(clean_pattern, component_pattern)
    local compare = M.create_comparator(parse)

    return {
        parse = parse,
        compare = compare,
        satisfies = function(version, constraint)
            if constraint:match("^%d") then
                return compare(version, constraint) == 0
            end
            return version == constraint
        end,
    }
end

-- ============================================================================
-- Public API — SemVer
-- ============================================================================

--- Parse semantic version (semver.org standard)
---@param version_str string Version string (e.g., "1.2.3", "1.2.3-beta")
---@return ParsedVersion|nil
function M.parse_semver(version_str)
    return parse_version(version_str, "^[%^~><=]*", "^(%d+)%.(%d+)%.(%d+)")
end

--- Compare two semantic versions
---@param v1_str string
---@param v2_str string
---@return ComparatorResult|nil
function M.compare_semver(v1_str, v2_str)
    if not is_nonempty_string(v1_str) or not is_nonempty_string(v2_str) then
        return nil
    end
    if v1_str == v2_str then
        return 0
    end

    local v1 = M.parse_semver(v1_str)
    local v2 = M.parse_semver(v2_str)

    if not v1 or not v2 then
        return nil
    end

    return compare_parsed(v1, v2)
end

-- ============================================================================
-- Public API — Constraints
-- ============================================================================

--- Operator handlers for constraint satisfaction
---@type table<string, fun(v: ParsedVersion, t: ParsedVersion): boolean>
local CONSTRAINT_OPS = {
    ["^"] = function(v, t)
        return v.major == t.major and v.minor >= t.minor
    end,
    ["~"] = function(v, t)
        return v.major == t.major and v.minor == t.minor and v.patch >= t.patch
    end,
    [">="] = function(v, t)
        return compare_parsed(v, t) >= 0
    end,
    [">"] = function(v, t)
        return compare_parsed(v, t) == 1
    end,
    ["<="] = function(v, t)
        return compare_parsed(v, t) <= 0
    end,
    ["<"] = function(v, t)
        return compare_parsed(v, t) == -1
    end,
}

--- Check if a version satisfies a range constraint
---@param version string Version to check
---@param constraint string Constraint (e.g., "^1.2.3", "~1.2.3", ">=1.2.3")
---@return boolean
function M.satisfies(version, constraint)
    if not is_nonempty_string(version) or not is_nonempty_string(constraint) then
        return false
    end

    -- Exact match when no operator present
    if not constraint:match("[%^~><=]") then
        return M.compare_semver(version, constraint) == 0
    end

    local operator, target = constraint:match("^([%^~><=]+)%s*(.+)$")
    if not operator or not target then
        return false
    end

    local v_parsed = M.parse_semver(version)
    local t_parsed = M.parse_semver(target)
    if not v_parsed or not t_parsed then
        return false
    end

    local handler = CONSTRAINT_OPS[operator]
    return handler ~= nil and handler(v_parsed, t_parsed)
end

-- ============================================================================
-- Public API — Collection operations
-- ============================================================================

--- Get latest version from a list
---@param versions string[]
---@param comparator? VersionComparator
---@return string|nil
function M.latest(versions, comparator)
    if type(versions) ~= "table" or #versions == 0 then
        return nil
    end

    comparator = comparator or M.compare_semver
    local best = versions[1]
    for i = 2, #versions do
        if comparator(versions[i], best) == 1 then
            best = versions[i]
        end
    end
    return best
end

--- Sort versions in ascending order (in place)
---@param versions string[]
---@param comparator? VersionComparator
---@return string[]
function M.sort(versions, comparator)
    return sort_versions(versions, comparator or M.compare_semver, true)
end

--- Sort versions in descending order (in place)
---@param versions string[]
---@param comparator? VersionComparator
---@return string[]
function M.sort_desc(versions, comparator)
    return sort_versions(versions, comparator or M.compare_semver, false)
end

return M
