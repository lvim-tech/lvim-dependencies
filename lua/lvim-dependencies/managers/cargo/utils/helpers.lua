-- lvim-dependencies/managers/cargo/utils/helpers.lua
-- Core utilities for cargo actions

---@include "core/types.lua"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local file_ops = require("lvim-dependencies.managers.cargo.core.file_ops")
local toml_ops = require("lvim-dependencies.managers.cargo.core.toml_ops")

local debug = utils.debug

---@class CargoHelpers
local M = {}

M.DEFAULT_INDENT = "    " -- Cargo uses 4 spaces

local MAX_LOCK_LINES_SEARCH = 100

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get manifest (init.lua owns the cache)
---@return CargoManifest|nil
function M.get_manifest()
    local m = init.get_manifest("cargo")
    ---@cast m CargoManifest|nil
    return m
end

function M.get_file_patterns()
    local manifest = M.get_manifest()
    return (manifest and manifest.file_patterns) or { "Cargo.toml" }
end

function M.get_lock_files()
    local manifest = M.get_manifest()
    return (manifest and manifest.lock_files) or { "Cargo.lock" }
end

function M.get_dependency_sections()
    local manifest = M.get_manifest()
    return (manifest and manifest.dependency_sections) or { "dependencies", "dev-dependencies", "build-dependencies" }
end

--- Find last dependency section index in lines
---@param lines string[]
---@param sections string[]
---@return integer|nil
function M.find_last_section_index(lines, sections)
    local last_idx = 0
    for i, line in ipairs(lines) do
        for _, sec in ipairs(sections) do
            if line:match("^%s*%[" .. sec .. "%]") then
                last_idx = i
                break
            end
        end
    end
    return last_idx > 0 and last_idx or nil
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
        local ver = l:match('^%s*version%s*=%s*"([^"]+)"')
        if ver and ver ~= "" then
            debug(string.format("Found version in lock at line %d: %s", j, ver), vim.log.levels.DEBUG)
            return ver
        end
    end
    return nil
end

--- Read current version from lock files
---@param pkg_name string
---@return string|nil
function M.read_current_from_lock(pkg_name)
    local path = file_ops.find_cargo_toml_path()
    if not path then
        return nil
    end

    local lock_files = M.get_lock_files()
    local cargo_dir = vim.fn.fnamemodify(path, ":h")

    for _, lock_file in ipairs(lock_files) do
        local lock_path = cargo_dir .. "/" .. lock_file
        local lines = file_ops.read_lines(lock_path)
        if not lines then
            goto continue
        end

        local in_package = false
        for i, line in ipairs(lines) do
            if line:match("^%[%[package%]%]") then
                in_package = true
            elseif in_package and line:match('^name%s*=%s*"') then
                local name = line:match('^name%s*=%s*"([^"]+)"')
                if name == pkg_name then
                    local ver = find_version_in_lock_lines(lines, i)
                    if ver then
                        debug(string.format("Found version for %s: %s", pkg_name, ver), vim.log.levels.INFO)
                        return ver
                    end
                end
                in_package = false
            elseif in_package and line:match("^%[%[") then
                in_package = false
            end
        end

        ::continue::
    end

    debug(string.format("No version found for %s", pkg_name), vim.log.levels.WARN)
    return nil
end

--- Find which section a package belongs to in Cargo.toml
---@param pkg_name string
---@return string|nil
function M.find_package_section(pkg_name)
    local path = file_ops.find_cargo_toml_path()
    if not path then
        return nil
    end

    local lines = file_ops.read_lines(path)
    if not lines then
        return nil
    end

    local manifest = M.get_manifest()
    local sections = M.get_dependency_sections()

    if manifest and manifest.special_keys then
        for _, key in ipairs(manifest.special_keys) do
            for _, line in ipairs(lines) do
                if line:match("^%s*" .. key .. "%s*=") then
                    return nil
                end
            end
        end
    end

    for _, section in ipairs(sections) do
        local section_idx = toml_ops.find_section_index(lines, section)
        if section_idx then
            local section_end = toml_ops.find_section_end(lines, section_idx)
            local line_num = toml_ops.find_package_line(lines, section_idx, section_end, pkg_name)
            if line_num then
                debug(string.format("Package %s found in section %s", pkg_name, section), vim.log.levels.DEBUG)
                return section
            end
        end
    end

    return nil
end

--- Clear cache — no-op, init.lua owns manifest cache.
function M.clear_cache()
    debug("Cargo helpers cache cleared (no-op, init.lua owns manifest cache)", vim.log.levels.DEBUG)
end

return M
