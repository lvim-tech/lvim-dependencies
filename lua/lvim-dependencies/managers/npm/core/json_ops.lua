-- lvim-dependencies/managers/npm/core/json_ops.lua
-- JSON manipulation for package.json
-- Uses libs/json.lua for encoding to preserve formatting control

---@include "core/types.lua"

local json = require("lvim-dependencies.libs.json")
local utils = require("lvim-dependencies.utils")

local debug = utils.debug

---@class NpmJsonOps
local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

local function validate_lines(lines)
    return lines ~= nil and type(lines) == "table" and #lines > 0
end

--- Detect indent used in the file (default: 2 spaces)
---@param lines string[]
---@return string
local function detect_indent(lines)
    for _, line in ipairs(lines) do
        local indent = line:match("^( +)%S")
        if indent then
            return indent
        end
    end
    return "  "
end

--- Find the line index (1-based) of a dependency section header
--- Looks for:  "dependencies": {
---@param lines string[]
---@param section string
---@return integer|nil
function M.find_section_index(lines, section)
    if not validate_lines(lines) then
        return nil
    end

    local pattern = string.format('^%%s*"%s"%%s*:%%s*{', vim.pesc(section))
    for i, line in ipairs(lines) do
        if line:match(pattern) then
            debug(string.format("Found section '%s' at line %d", section, i), vim.log.levels.DEBUG)
            return i
        end
    end
    return nil
end

--- Find the closing brace of a section (1-based)
---@param lines string[]
---@param section_idx integer Opening line of section
---@return integer
function M.find_section_end(lines, section_idx)
    local depth = 0
    for i = section_idx, #lines do
        local line = lines[i]
        -- Count braces
        for ch in line:gmatch("[{}]") do
            if ch == "{" then
                depth = depth + 1
            else
                depth = depth - 1
                if depth == 0 then
                    debug(string.format("Section end at line %d", i), vim.log.levels.DEBUG)
                    return i
                end
            end
        end
    end
    return #lines
end

--- Find the line of a package inside a section (1-based)
--- Matches:  "pkg": "version"  or  "pkg": {
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@return integer|nil
function M.find_package_line(lines, section_idx, section_end, pkg_name)
    local escaped = vim.pesc(pkg_name)
    local pattern = string.format('^%%s*"%s"%%s*:', escaped)
    for i = section_idx + 1, section_end do
        if lines[i] and lines[i]:match(pattern) then
            debug(string.format("Found package '%s' at line %d", pkg_name, i), vim.log.levels.DEBUG)
            return i
        end
    end
    return nil
end

--- Find start/end of a package block inside a section.
--- Simple packages are single-line; object packages span multiple lines.
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@return integer|nil start_idx
---@return integer|nil end_idx
---@return string|nil line
function M.find_package_block(lines, section_idx, section_end, pkg_name)
    local start_idx = M.find_package_line(lines, section_idx, section_end, pkg_name)
    if not start_idx then
        return nil, nil, nil
    end

    local first_line = lines[start_idx]

    -- Single-line value: "pkg": "version",
    if not first_line:match("{%s*$") then
        return start_idx, start_idx, first_line
    end

    -- Multi-line object value: find closing }
    local depth = 0
    for i = start_idx, section_end do
        for ch in lines[i]:gmatch("[{}]") do
            if ch == "{" then
                depth = depth + 1
            else
                depth = depth - 1
                if depth == 0 then
                    return start_idx, i, first_line
                end
            end
        end
    end

    return start_idx, section_end, first_line
end

--- Replace a package entry in a section
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@param new_line string  The new single-line entry (already formatted)
---@return table|nil new_lines
---@return boolean replaced
---@return FileChange|nil change
function M.replace_package_in_section(lines, section_idx, section_end, pkg_name, new_line)
    local start_idx, end_idx = M.find_package_block(lines, section_idx, section_end, pkg_name)
    if not start_idx or not end_idx then
        debug(string.format("Package '%s' not found for replacement", pkg_name), vim.log.levels.DEBUG)
        return nil, false, nil
    end
    ---@cast start_idx integer
    ---@cast end_idx integer

    -- Preserve original indent and trailing comma
    local indent = lines[start_idx]:match("^(%s*)") or "  "
    local has_comma = lines[end_idx]:match(",$") ~= nil
    local formatted = indent .. new_line:match("^%s*(.-)%s*$")
    if has_comma then
        formatted = formatted .. ","
    end

    local out = {}
    for i = 1, start_idx - 1 do
        out[#out + 1] = lines[i]
    end
    out[#out + 1] = formatted
    for i = end_idx + 1, #lines do
        out[#out + 1] = lines[i]
    end

    ---@type FileChange
    local change = {
        start0 = start_idx - 1,
        end0 = end_idx,
        lines = { formatted },
    }

    debug(string.format("Replaced '%s' at lines %d-%d", pkg_name, start_idx, end_idx), vim.log.levels.DEBUG)
    return out, true, change
end

--- Insert a new package at the end of a section
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param new_line string  Already formatted entry (without indent)
---@return table new_lines
---@return FileChange change
function M.insert_package_in_section(lines, section_idx, section_end, new_line)
    local indent = detect_indent(lines) .. detect_indent(lines) -- double for nested

    -- Find last non-empty line in section (to place after it)
    local insert_after = section_idx
    for i = section_idx + 1, section_end - 1 do
        if lines[i] and not lines[i]:match("^%s*$") then
            insert_after = i
        end
    end

    -- Add comma to previous last entry if missing
    local new_lines = vim.deepcopy(lines)
    local prev = new_lines[insert_after]
    if prev and not prev:match(",$") and not prev:match("{%s*$") and insert_after > section_idx then
        new_lines[insert_after] = prev .. ","
    end

    local formatted = indent .. new_line:match("^%s*(.-)%s*$")
    table.insert(new_lines, insert_after + 1, formatted)

    ---@type FileChange
    local change = {
        start0 = insert_after,
        end0 = insert_after,
        lines = { new_lines[insert_after], formatted },
    }

    debug(string.format("Inserted package after line %d", insert_after), vim.log.levels.DEBUG)
    return new_lines, change
end

--- Remove a package from a section
---@param lines string[]
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
    ---@cast start_idx integer
    ---@cast end_idx integer

    local out = {}
    for i = 1, start_idx - 1 do
        out[#out + 1] = lines[i]
    end
    for i = end_idx + 1, #lines do
        out[#out + 1] = lines[i]
    end

    -- Fix trailing comma on the line before if we removed the last entry
    if start_idx > section_idx + 1 then
        local prev_idx = #out
        -- Walk back to find last non-empty non-closing-brace line
        while prev_idx > 0 and (out[prev_idx]:match("^%s*$") or out[prev_idx]:match("^%s*}")) do
            prev_idx = prev_idx - 1
        end
        if prev_idx > 0 then
            -- Remove trailing comma from what is now the last entry
            local trailing = out[prev_idx]:match(",$")
            -- Only remove if the next real line is the section closing brace
            local next_real = nil
            for i = prev_idx + 1, #out do
                if not out[i]:match("^%s*$") then
                    next_real = out[i]
                    break
                end
            end
            if trailing and next_real and next_real:match("^%s*}") then
                out[prev_idx] = out[prev_idx]:sub(1, -2)
            end
        end
    end

    ---@type FileChange
    local change = {
        start0 = start_idx - 1,
        end0 = end_idx,
        lines = {},
    }

    debug(string.format("Removed '%s' at lines %d-%d", pkg_name, start_idx, end_idx), vim.log.levels.DEBUG)
    return out, change
end

--- Build a formatted single-line package entry
--- "pkg": "version",
---@param pkg_name string
---@param version string
---@return string
function M.format_package_line(pkg_name, version)
    return string.format('"%s": "%s"', pkg_name, version)
end

--- Parse package.json content via libs/json.lua
---@param content string
---@return table|nil
function M.parse(content)
    if not content or content == "" then
        return nil
    end
    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        debug(string.format("JSON parse error: %s", tostring(data)), vim.log.levels.ERROR)
        return nil
    end
    return data
end

--- Encode a table to JSON string via libs/json.lua
---@param data table
---@return string|nil
function M.encode(data)
    local ok, result = pcall(json.encode, data)
    if not ok then
        debug(string.format("JSON encode error: %s", tostring(result)), vim.log.levels.ERROR)
        return nil
    end
    return result
end

return M
