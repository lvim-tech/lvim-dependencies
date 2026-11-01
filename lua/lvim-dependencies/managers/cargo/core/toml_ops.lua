-- lvim-dependencies.managers.cargo.core.toml_ops: line-based (not AST) editing of Cargo.toml.
-- Finds a section's span, locates a package block within it (including any indented
-- continuation lines of an inline/expanded table), and replaces / inserts / removes that
-- block — returning both the new line array and a FileChange (start0/end0/lines) so the buffer
-- can be updated minimally. Line-based on purpose: it preserves surrounding formatting and
-- comments that a parse-and-serialize round-trip would lose.
---@module "lvim-dependencies.managers.cargo.core.toml_ops"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")

local debug = utils.debug

---@class CargoTomlOps
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
    return line:match("^%s*[\"']?([%w%-_]+)[\"']?%s*=")
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

--- Find section index in TOML
---@param lines table|nil
---@param section_name string
---@return integer|nil
function M.find_section_index(lines, section_name)
    if not validate_lines(lines) or not section_name then
        debug("Invalid input for find_section_index", vim.log.levels.WARN)
        return nil
    end
    ---@cast lines table validate_lines guaranteed a non-empty table

    local pattern = "^%s*%[" .. escape_pattern(section_name) .. "%]"

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
        if line and line:match("^%s*%[") then
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

--- The package a `[....dependencies.<name>]` header declares.
---@param line string|nil
---@return string|nil
function M.package_from_header(line)
    local header = (line or ""):match("^%s*%[%s*([^%[%]]+)%s*%]")
    local prefix, name = (header or ""):match("^(.-)%.[\"']?([%w%-_]+)[\"']?$")
    if not prefix then
        return nil
    end
    local outer, kind = prefix:match("^(.-%.?)([%w%-_]+)$")
    if not kind or not kind:match("dependencies$") then
        return nil
    end
    if outer == "" or outer == "workspace." or outer:match("^target%.") then
        return name
    end
    return nil
end

--- Where `section` declares `pkg`, in either form: a line or block inside `[section]`, or a
--- `[section.pkg]` table of its own.
---@param lines string[]
---@param section string
---@param pkg string
---@return integer|nil first  1-indexed
---@return integer|nil last
---@return "inline"|"table"|nil form
function M.locate_package(lines, section, pkg)
    local idx = M.find_section_index(lines, section)
    if idx then
        local first, last = M.find_package_block(lines, idx, M.find_section_end(lines, idx), pkg)
        if first then
            return first, last, "inline"
        end
    end
    local header = M.find_section_index(lines, section .. "." .. pkg)
        or M.find_section_index(lines, section .. '."' .. pkg .. '"')
        or M.find_section_index(lines, section .. ".'" .. pkg .. "'")
    if not header then
        return nil, nil, nil
    end
    local last = M.find_section_end(lines, header)
    while last > header and lines[last]:match("^%s*$") do
        last = last - 1
    end
    return header, last, "table"
end

--- The keys of a `[section.pkg]` block, each with the lines it spans. Nil on an unclosed value.
---@param block string[]  header first
---@return { key: string, value: string, comment: string|nil, first: integer, last: integer }[]|nil
function M.table_entries(block)
    local entries = {}
    local i = 2
    while i <= #block do
        local key, rest = block[i]:match("^%s*([^=%s#%[]+)%s*=%s*(.*)$")
        if not key then
            i = i + 1
        else
            local first, depth, quote, parts, comment = i, 0, nil, {}, nil
            while true do
                local cut
                local j = 1
                while j <= #rest do
                    local c = rest:sub(j, j)
                    if quote then
                        if c == "\\" and quote == '"' then
                            j = j + 1
                        elseif c == quote then
                            quote = nil
                        end
                    elseif c == '"' or c == "'" then
                        quote = c
                    elseif c == "#" then
                        cut = j
                        break
                    elseif c == "[" or c == "{" then
                        depth = depth + 1
                    elseif c == "]" or c == "}" then
                        depth = depth - 1
                    end
                    j = j + 1
                end
                parts[#parts + 1] = vim.trim(cut and rest:sub(1, cut - 1) or rest)
                if depth <= 0 then
                    comment = cut and rest:sub(cut) or nil
                    break
                end
                i = i + 1
                if i > #block then
                    return nil
                end
                rest = block[i]
            end
            entries[#entries + 1] =
                { key = key, value = table.concat(parts, " "), comment = comment, first = first, last = i }
            i = i + 1
        end
    end
    return entries
end

--- A `[section.pkg]` block with keys set or removed and every other line left as written.
---@param block string[]
---@param changes { keys: string[], value: string|nil }[]  a nil value removes the key
---@return string[]|nil
function M.edit_table_block(block, changes)
    local entries = M.table_entries(block)
    if not entries then
        return nil
    end
    local by_first, append, last_key = {}, {}, 1
    local indent = ""
    for _, entry in ipairs(entries) do
        last_key = entry.last
    end
    if entries[1] then
        indent = block[entries[1].first]:match("^(%s*)")
    end
    for _, change in ipairs(changes) do
        local found
        for _, entry in ipairs(entries) do
            if vim.tbl_contains(change.keys, entry.key) then
                found = entry
                break
            end
        end
        if found then
            by_first[found.first] = { entry = found, value = change.value }
        elseif change.value then
            append[#append + 1] = indent .. change.keys[1] .. " = " .. change.value
        end
    end
    local out = {}
    local i = 1
    while i <= #block do
        local edit = by_first[i]
        local stop = edit and edit.entry.last or i
        if edit then
            if edit.value then
                local comment = edit.entry.comment
                out[#out + 1] = indent
                    .. edit.entry.key
                    .. " = "
                    .. edit.value
                    .. (comment and " " .. comment or "")
            end
        else
            out[#out + 1] = block[i]
        end
        if stop == last_key then
            vim.list_extend(out, append)
        end
        i = stop + 1
    end
    return out
end

--- Replace lines first..last.
---@param lines string[]
---@param first integer
---@param last integer
---@param replacement string[]
---@return string[] new_lines
---@return FileChange change
function M.replace_block(lines, first, last, replacement)
    local out = vim.list_slice(lines, 1, first - 1)
    vim.list_extend(out, replacement)
    vim.list_extend(out, lines, last + 1)
    return out, { start0 = first - 1, end0 = last, lines = replacement }
end

--- Remove a `[section.pkg]` block, and the blank line it would otherwise leave doubled.
---@param lines string[]
---@param first integer
---@param last integer
---@return string[] new_lines
---@return FileChange change
function M.remove_table_block(lines, first, last)
    local blank_before = first == 1 or lines[first - 1]:match("^%s*$")
    if blank_before and lines[last + 1] and lines[last + 1]:match("^%s*$") then
        last = last + 1
    end
    return M.replace_block(lines, first, last, {})
end

--- Find package line number (returns 1-indexed first line of package)
---@param lines table
---@param section_idx integer
---@param section_end integer
---@param pkg_name string
---@return integer|nil
function M.find_package_line(lines, section_idx, section_end, pkg_name)
    local start_idx = M.find_package_block(lines, section_idx, section_end, pkg_name)
    return start_idx
end

--- Find package line number by scope (RETURNS 1-INDEXED)
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
    local pattern = "^%s*[\"']?(" .. escape_pattern(pkg_name) .. ")[\"']?%s*="

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
    local manifest = init.get_manifest("cargo")
    if manifest and manifest.formatting and manifest.formatting.indent then
        return manifest.formatting.indent
    end
    return "    "
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
