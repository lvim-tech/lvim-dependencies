-- lvim-dependencies.managers.composer.core.json_ops: line-based edits of composer.json. It
-- works on the raw line array (not a decoded/re-encoded tree) so the user's formatting,
-- ordering and comments survive an update — only the touched package line changes. Each
-- section is scanned by brace depth, and trailing commas are fixed up on insert/remove.
-- Composer packages are always single-line ("vendor/pkg": "^1.0"), which simplifies blocks.
--
---@module "lvim-dependencies.managers.composer.core.json_ops"

local json = require("lvim-dependencies.libs.json")
local utils = require("lvim-dependencies.utils")

local debug = utils.debug

---@class ComposerJsonOps
local M = {}

local function validate_lines(lines)
    return lines ~= nil and type(lines) == "table" and #lines > 0
end

local function detect_indent(lines)
    for _, line in ipairs(lines) do
        local indent = line:match("^( +)%S")
        if indent then
            return indent
        end
    end
    return "    " -- composer default is 4 spaces
end

--- Find the line index (1-based) of a dependency section header
---@param lines string[]
---@param section string  "require" or "require-dev"
---@return integer|nil
function M.find_section_index(lines, section)
    if not validate_lines(lines) then
        return nil
    end
    local pattern = string.format('^%%s*"%s"%%s*:%%s*{', vim.pesc(section))
    for i, line in ipairs(lines) do
        if line:match(pattern) then
            return i
        end
    end
    return nil
end

--- Find the closing brace of a section
---@param lines string[]
---@param section_idx integer
---@return integer
function M.find_section_end(lines, section_idx)
    local depth = 0
    for i = section_idx, #lines do
        for ch in lines[i]:gmatch("[{}]") do
            if ch == "{" then
                depth = depth + 1
            else
                depth = depth - 1
                if depth == 0 then
                    return i
                end
            end
        end
    end
    return #lines
end

--- Find the line of a package inside a section
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param pkg_name string  vendor/package format
---@return integer|nil
function M.find_package_line(lines, section_idx, section_end, pkg_name)
    local escaped = vim.pesc(pkg_name)
    local pattern = string.format('^%%s*"%s"%%s*:', escaped)
    for i = section_idx + 1, section_end do
        if lines[i] and lines[i]:match(pattern) then
            return i
        end
    end
    return nil
end

--- Find start/end of a package block
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
    -- composer.json packages are always single-line: "vendor/pkg": "^1.0"
    return start_idx, start_idx, lines[start_idx]
end

--- Replace a package entry in a section
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@param new_line string
---@return string[]|nil new_lines
---@return boolean replaced
---@return FileChange|nil change
function M.replace_package_in_section(lines, section_idx, section_end, pkg_name, new_line)
    local start_idx, end_idx = M.find_package_block(lines, section_idx, section_end, pkg_name)
    if not start_idx or not end_idx then
        return nil, false, nil
    end
    ---@cast start_idx integer
    ---@cast end_idx integer

    local indent = lines[start_idx]:match("^(%s*)") or "    "
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
    local change = { start0 = start_idx - 1, end0 = end_idx, lines = { formatted } }
    return out, true, change
end

--- Insert a new package at the end of a section
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param new_line string
---@return string[] new_lines
---@return FileChange change
function M.insert_package_in_section(lines, section_idx, section_end, new_line)
    local indent = detect_indent(lines)
    local pkg_indent = indent .. indent -- double for nested

    local insert_after = section_idx
    for i = section_idx + 1, section_end - 1 do
        if lines[i] and not lines[i]:match("^%s*$") then
            insert_after = i
        end
    end

    local new_lines = vim.deepcopy(lines)
    local prev = new_lines[insert_after]
    if prev and not prev:match(",$") and not prev:match("{%s*$") and insert_after > section_idx then
        new_lines[insert_after] = prev .. ","
    end

    local formatted = pkg_indent .. new_line:match("^%s*(.-)%s*$")
    table.insert(new_lines, insert_after + 1, formatted)

    ---@type FileChange
    local change = {
        start0 = insert_after,
        end0 = insert_after,
        lines = { new_lines[insert_after], formatted },
    }
    return new_lines, change
end

--- Remove a package from a section
---@param lines string[]
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@return string[]|nil new_lines
---@return FileChange|nil change
function M.remove_package_from_section(lines, section_idx, section_end, pkg_name)
    local start_idx, end_idx = M.find_package_block(lines, section_idx, section_end, pkg_name)
    if not start_idx or not end_idx then
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

    -- Fix trailing comma on last entry
    if start_idx > section_idx + 1 then
        local prev_idx = #out
        while prev_idx > 0 and (out[prev_idx]:match("^%s*$") or out[prev_idx]:match("^%s*}")) do
            prev_idx = prev_idx - 1
        end
        if prev_idx > 0 then
            local next_real = nil
            for i = prev_idx + 1, #out do
                if not out[i]:match("^%s*$") then
                    next_real = out[i]
                    break
                end
            end
            if out[prev_idx]:match(",$") and next_real and next_real:match("^%s*}") then
                out[prev_idx] = out[prev_idx]:sub(1, -2)
            end
        end
    end

    ---@type FileChange
    local change = { start0 = start_idx - 1, end0 = end_idx, lines = {} }
    return out, change
end

--- Build a formatted single-line package entry
---@param pkg_name string
---@param version string
---@return string
function M.format_package_line(pkg_name, version)
    return string.format('"%s": "%s"', pkg_name, version)
end

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
