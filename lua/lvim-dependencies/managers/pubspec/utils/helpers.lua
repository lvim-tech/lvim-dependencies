-- lvim-dependencies.managers.pubspec.utils.helpers: shared lookups used across the pubspec action
-- modules. Thin accessors over the manifest (lock files, dependency sections, SDK check), URL
-- encoding for registry requests, and lock-file scanning that does NOT parse YAML — it reads the
-- current installed version for a package (and the Flutter SDK version) by walking the lock lines,
-- plus finding which dependency section a package is declared in.
--
---@module "lvim-dependencies.managers.pubspec.utils.helpers"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")
local file_ops = require("lvim-dependencies.managers.pubspec.core.file_ops")
local yaml_ops = require("lvim-dependencies.managers.pubspec.core.yaml_ops")

local debug = utils.debug

---@class PubspecHelpers
local M = {}

---@type string
M.DEFAULT_INDENT = "  "

--- Max lines scanned after a package entry when reading its version from a lock file.
---@type integer
local MAX_LOCK_LINES_SEARCH = 100

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get manifest (init.lua owns the cache)
---@return PubspecManifest|nil
function M.get_manifest()
    local m = init.get_manifest("pubspec")
    ---@cast m PubspecManifest|nil
    return m
end

--- Get lock files from manifest
---@return string[]
function M.get_lock_files()
    local manifest = M.get_manifest()
    return (manifest and manifest.lock_files) or { "pubspec.lock" }
end

--- Get dependency sections from manifest
---@return string[]
function M.get_dependency_sections()
    local manifest = M.get_manifest()
    return (manifest and manifest.dependency_sections) or { "dependencies", "dev_dependencies" }
end

--- Check if package is an SDK package — one that ships with the SDK and has no pub.dev entry.
--- The manifest's built-in set plus the user's `config.pubspec.sdk_packages` (documented as the
--- place to add more; it was never read before, so custom entries still went to the registry).
---@param pkg_name string
---@return boolean
function M.is_sdk_package(pkg_name)
    local manifest = M.get_manifest()
    if manifest and manifest.sdk_packages and manifest.sdk_packages[pkg_name] == true then
        return true
    end
    local cfg = config.pubspec and config.pubspec.sdk_packages
    if cfg ~= nil and cfg[pkg_name] == true then
        return true
    end
    -- Anything declared with `sdk: <name>` (flutter_driver, integration_test, a custom SDK
    -- package…) is an SDK package whatever its name: the declared record already carries that
    -- type, so no fixed name list has to know it — and pub.dev is never asked about it.
    local ok, cache = pcall(require, "lvim-dependencies.core.cache")
    if ok then
        local declared = cache.get().declared
        local entry = declared and declared.pubspec
        local rec = entry and entry.data and entry.data[pkg_name]
        if type(rec) == "table" and (rec.type == "sdk" or (type(rec.raw) == "table" and rec.raw.sdk ~= nil)) then
            return true
        end
    end
    return false
end

--- Is this `key: value` line a FIELD of a dependency's block rather than a package line?
--- `special_keys` names the fields a block can carry (git/url/ref/path/sdk/hosted/…), but
--- `path`, `web`, `version`… are also legitimate pub.dev package names, so the key alone cannot
--- tell foo's `    path: ../foo` from the `  path: ^1.9.0` package. The VALUE can: a field holds
--- a path / url / ref / sdk name, a package line holds a version constraint (`^1.9.0`, `any`,
--- `"1.0.0"`, `>=1.0.0 <2.0.0`), an inline map, or nothing at all (a block header `foo:`).
---@param line string
---@return boolean
function M.is_nested_field_line(line)
    local key, value = line:match("^%s*([%w_%-]+)%s*:%s*(.-)%s*$")
    if not key then
        return false
    end
    local manifest = M.get_manifest()
    if not (manifest and manifest.special_keys and vim.tbl_contains(manifest.special_keys, key)) then
        return false
    end
    if value == "" or value:match("^#") or value:match("^{") then
        return false -- block header or inline map: a package
    end
    value = value:gsub("^[\"']", "")
    if value:match("^[%^~<>=]*%d") or value:match("^any%f[%W]") or value == "any" then
        return false -- a version constraint: a package
    end
    return true
end

--- URL encode a string
---@param str string|nil
---@return string
function M.urlencode(str)
    str = str or ""
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return (string.gsub(str, " ", "+"))
end

--- Find version in lock file lines after a package entry
---@param lines string[]
---@param start_idx integer
---@return string|nil
local function find_version_in_lock_lines(lines, start_idx)
    for j = start_idx + 1, math.min(#lines, start_idx + MAX_LOCK_LINES_SEARCH) do
        local l = lines[j]
        if not l then
            break
        end
        if l:match("^%S") then
            break
        end
        local ver = l:match('^%s*version:%s*"(.-)"') or l:match("^%s*version:%s*(%S+)")
        if ver and ver ~= "" then
            debug(string.format("Found version in lock at line %d: %s", j, ver), vim.log.levels.DEBUG)
            return ver
        end
    end
    return nil
end

--- Read Flutter SDK version from pubspec.lock
---@return string|nil
function M.read_flutter_sdk_version()
    local path = file_ops.find_pubspec_path()
    if not path then
        return nil
    end

    local lock_files = M.get_lock_files()
    local pubspec_dir = vim.fn.fnamemodify(path, ":h")

    for _, lock_file in ipairs(lock_files) do
        local lock_path = pubspec_dir .. "/" .. lock_file
        local lines = file_ops.read_lines(lock_path)
        if not lines then
            goto continue
        end

        local in_sdks = false
        for _, line in ipairs(lines) do
            if line:match("^%s*sdks:%s*$") then
                in_sdks = true
            elseif in_sdks and line:match("^%s+flutter:%s*(.+)$") then
                local version = line:match("^%s+flutter:%s*(.+)"):gsub('"', "")
                debug(string.format("Found Flutter SDK version: %s", version), vim.log.levels.INFO)
                return version
            elseif in_sdks and line:match("^%S") then
                in_sdks = false
            end
        end

        ::continue::
    end

    debug("No Flutter SDK version found", vim.log.levels.WARN)
    return nil
end

--- Read current version from lock files
---@param pkg_name string
---@return string|nil
function M.read_current_from_lock(pkg_name)
    local path = file_ops.find_pubspec_path()
    if not path then
        debug("No pubspec path found", vim.log.levels.WARN)
        return nil
    end

    if M.is_sdk_package(pkg_name) then
        return M.read_flutter_sdk_version()
    end

    local lock_files = M.get_lock_files()
    local pubspec_dir = vim.fn.fnamemodify(path, ":h")

    for _, lock_file in ipairs(lock_files) do
        local lock_path = pubspec_dir .. "/" .. lock_file
        local lines = file_ops.read_lines(lock_path)
        if not lines then
            goto continue
        end

        for i, ln in ipairs(lines) do
            if ln:match("^%s*" .. vim.pesc(pkg_name) .. "%s*:") then
                local ver = find_version_in_lock_lines(lines, i)
                if ver then
                    debug(string.format("Found version for %s: %s", pkg_name, ver), vim.log.levels.INFO)
                    return ver
                end
            end
        end

        ::continue::
    end

    debug(string.format("No version found for %s", pkg_name), vim.log.levels.WARN)
    return nil
end

--- Find which section a package belongs to
---@param pkg_name string
---@return string|nil
function M.find_package_section(pkg_name)
    local path = file_ops.find_pubspec_path()
    if not path then
        return nil
    end

    local lines = file_ops.read_lines(path)
    if not lines then
        return nil
    end

    -- No special-key short-circuit here: `path`/`web`/… are real packages, and find_package_block
    -- only matches at the section's package indent, so a block's nested fields cannot pose as one.
    local sections = M.get_dependency_sections()

    for _, section in ipairs(sections) do
        local section_idx = yaml_ops.find_section_index(lines, section)
        if section_idx then
            local section_end = yaml_ops.find_section_end(lines, section_idx)
            local i, _ = yaml_ops.find_package_block(lines, section_idx, section_end, pkg_name)
            if i then
                debug(string.format("Package %s found in section %s", pkg_name, section), vim.log.levels.DEBUG)
                return section
            end
        end
    end

    return nil
end

--- Clear helper cache.
--- helpers no longer holds its own manifest cache — this is a no-op kept
--- for backward compatibility with any callers.
function M.clear_cache()
    debug("Pubspec helpers cache cleared (no-op, init.lua owns manifest cache)", vim.log.levels.DEBUG)
end

return M
