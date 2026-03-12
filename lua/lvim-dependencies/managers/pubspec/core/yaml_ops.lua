-- lvim-dependencies/managers/pubspec/core/yaml_ops.lua
-- YAML manipulation for pubspec.yaml

---@include "core/types.lua"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local debug = utils.debug

---@class PubspecYamlOps
local M = {}

--- Escape pattern for use in string matching
---@param text string
---@return string
local function escape_pattern(text)
    return vim.pesc(text or "")
end

--- Get package name from line
---@param line string|nil
---@return string|nil
local function get_package_name_from_line(line)
    if not line then
        return nil
    end
    return line:match("^%s*([%w%-%_%.]+)%s*:")
end

--- Get line indent
---@param line string|nil
---@return string
local function get_line_indent(line)
    return (line or ""):match("^(%s*)") or ""
end

--- Validate input parameters
---@param lines table|nil
---@return boolean
local function validate_lines(lines)
    return lines ~= nil and type(lines) == "table" and #lines > 0
end

--- Find section index in YAML
---@param lines table|nil
---@param section_name string
---@return integer|nil
function M.find_section_index(lines, section_name)
    if not validate_lines(lines) or not section_name then
        debug("Invalid input for find_section_index", vim.log.levels.WARN)
        return nil
    end

    local pattern = "^%s*" .. escape_pattern(section_name) .. "%s*:"

    for i, line in ipairs(lines) do
        if line:match(pattern) then
            debug(string.format("Found section '%s' at line %d", section_name, i), vim.log.levels.DEBUG)
            return i
        end
    end

    debug(string.format("Section '%s' not found", section_name), vim.log.levels.DEBUG)
    return nil
end

--- Find section end index
---@param lines table
---@param section_idx integer
---@return integer
function M.find_section_end(lines, section_idx)
    if not validate_lines(lines) or not section_idx then
        debug("Invalid input for find_section_end", vim.log.levels.WARN)
        return #lines
    end

    for i = section_idx + 1, #lines do
        local line = lines[i]
        if line and line:match("^%S") then
            debug(string.format("Section end at line %d", i - 1), vim.log.levels.DEBUG)
            return i - 1
        end
    end

    debug(string.format("Section end at file end (%d)", #lines), vim.log.levels.DEBUG)
    return #lines
end

--- Find package block in section
---@param lines table
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@return integer|nil start_idx
---@return integer|nil end_idx
---@return string|nil line
function M.find_package_block(lines, section_idx, section_end, pkg_name)
    if not validate_lines(lines) or not pkg_name then
        debug("Invalid input for find_package_block", vim.log.levels.WARN)
        return nil, nil, nil
    end

    for i = section_idx + 1, section_end do
        local line = lines[i]
        if not line then
            break
        end

        local name = get_package_name_from_line(line)
        if name and name == pkg_name then
            local pkg_indent = get_line_indent(line)
            local pkg_indent_len = #pkg_indent
            local block_end = i

            for j = i + 1, section_end do
                local next_line = lines[j]
                if not next_line then
                    break
                end

                if next_line:match("^%S") then
                    break
                end

                local next_indent = get_line_indent(next_line)
                if #next_indent > pkg_indent_len then
                    block_end = j
                else
                    break
                end
            end

            debug(string.format("Found package '%s' at lines %d-%d", pkg_name, i, block_end), vim.log.levels.DEBUG)
            return i, block_end, line
        end
    end

    debug(string.format("Package '%s' not found in section", pkg_name), vim.log.levels.DEBUG)
    return nil, nil, nil
end

--- Find package line number (RETURNS 1-INDEXED)
---@param buf_lines table
---@param scope string
---@param pkg_name string
---@return integer|nil
function M.find_package_lnum(buf_lines, scope, pkg_name)
    if type(buf_lines) ~= "table" or not scope or not pkg_name then
        debug("Invalid input for find_package_lnum", vim.log.levels.WARN)
        return nil
    end

    local section_idx = M.find_section_index(buf_lines, scope)
    if not section_idx then
        debug(string.format("Section '%s' not found for package '%s'", scope, pkg_name), vim.log.levels.DEBUG)
        return nil
    end

    local section_end = M.find_section_end(buf_lines, section_idx)
    local pattern = "^%s*(" .. escape_pattern(pkg_name) .. ")%s*:"

    for i = section_idx + 1, section_end do
        local line = buf_lines[i]
        if line and line:match(pattern) then
            debug(
                string.format("Found package '%s' at line %d in section '%s'", pkg_name, i, scope),
                vim.log.levels.DEBUG
            )
            return i
        end
    end

    debug(string.format("Package '%s' not found in section '%s'", pkg_name, scope), vim.log.levels.DEBUG)
    return nil
end

--- Replace package in section
---@param lines table
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@param new_line string
---@return table|nil new_lines
---@return boolean replaced
---@return FileChange|nil change
function M.replace_package_in_section(lines, section_idx, section_end, pkg_name, new_line)
    local start_idx, end_idx = M.find_package_block(lines, section_idx, section_end, pkg_name)
    if not start_idx or not end_idx then
        debug(string.format("Package '%s' not found for replacement", pkg_name), vim.log.levels.DEBUG)
        return nil, false, nil
    end

    debug(string.format("Replacing package '%s' at lines %d-%d", pkg_name, start_idx, end_idx), vim.log.levels.DEBUG)

    local out = {}

    for i = 1, start_idx - 1 do
        out[#out + 1] = lines[i]
    end

    out[#out + 1] = new_line

    for i = end_idx + 1, #lines do
        out[#out + 1] = lines[i]
    end

    ---@type FileChange
    local change = {
        start0 = start_idx - 1,
        end0 = end_idx,
        lines = { new_line },
    }

    return out, true, change
end

--- Get default indent from manifest
---@return string
local function get_default_indent()
    -- Use init directly instead of helpers
    local manifest = init.get_manifest("pubspec")
    if manifest and manifest.formatting and manifest.formatting.indent then
        return manifest.formatting.indent
    end
    return "  "
end

--- Insert a new package at the end of a section
---@param lines table
---@param section_idx integer
---@param new_line string
---@return table new_lines
---@return FileChange change
function M.insert_package_in_section(lines, section_idx, new_line)
    debug(string.format("Inserting package in section at index %d", section_idx), vim.log.levels.DEBUG)

    local section_end = M.find_section_end(lines, section_idx)

    local last_package_idx = section_idx
    for i = section_idx + 1, section_end do
        if lines[i] and not lines[i]:match("^%s*$") then
            last_package_idx = i
        end
    end

    local new_lines = vim.deepcopy(lines)

    local indent = get_default_indent()
    if section_idx + 1 <= #lines then
        local next_line = lines[section_idx + 1]
        if next_line and next_line:match("^%s+") then
            indent = next_line:match("^(%s+)") or indent
        end
    end

    local formatted_line = indent .. new_line:match("^%s*(.-)%s*$")

    ---@type FileChange
    local change

    if last_package_idx > section_idx then
        table.insert(new_lines, last_package_idx + 1, formatted_line)
        change = {
            start0 = last_package_idx,
            end0 = last_package_idx,
            lines = { formatted_line },
        }
        debug(string.format("Inserted after existing package at line %d", last_package_idx + 1), vim.log.levels.DEBUG)
    else
        table.insert(new_lines, section_idx + 1, formatted_line)
        change = {
            start0 = section_idx,
            end0 = section_idx,
            lines = { formatted_line },
        }
        debug(string.format("Inserted new package at line %d", section_idx + 1), vim.log.levels.DEBUG)
    end

    return new_lines, change
end

--- Remove package from section
---@param lines table
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@return table|nil new_lines
---@return FileChange|nil change
function M.remove_package_from_section(lines, section_idx, section_end, pkg_name)
    local start_idx, end_idx = M.find_package_block(lines, section_idx, section_end, pkg_name)
    if not start_idx or not end_idx then
        debug(string.format("Package '%s' not found for removal", pkg_name), vim.log.levels.DEBUG)
        return nil, nil
    end

    debug(string.format("Removing package '%s' at lines %d-%d", pkg_name, start_idx, end_idx), vim.log.levels.DEBUG)

    local out = {}

    for i = 1, start_idx - 1 do
        out[#out + 1] = lines[i]
    end

    for i = end_idx + 1, #lines do
        out[#out + 1] = lines[i]
    end

    ---@type FileChange
    local change = {
        start0 = start_idx - 1,
        end0 = end_idx,
        lines = {},
    }

    return out, change
end

return M
