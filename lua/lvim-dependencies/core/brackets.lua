-- lvim-dependencies.core.brackets: where a value in a manifest ends. Formatters split a long value
-- over several lines and put its closing bracket wherever their style says, so neither the indent
-- nor the end of the line can answer this. Only the brackets can.
--
---@module "lvim-dependencies.core.brackets"

local M = {}

--- Bracket depth after a line, ignoring strings and, when the format has them, comments.
---@param line string
---@param depth integer
---@param comment? string  the character that starts a comment
---@return integer
function M.depth_after(line, depth, comment)
    local quote
    local i = 1
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == "\\" and quote == '"' then
                i = i + 1
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == comment then
            break
        elseif c == "[" or c == "{" then
            depth = depth + 1
        elseif c == "]" or c == "}" then
            depth = depth - 1
        end
        i = i + 1
    end
    return depth
end

--- The last line of the JSON value whose key is on line `first`.
---@param lines string[]
---@param first integer
---@param limit integer
---@return integer
function M.json_value_end(lines, first, limit)
    local depth, seen = 0, false
    for i = first, limit do
        local text = i == first and (lines[i]:match('^%s*".-"%s*:%s*(.*)$') or "") or lines[i]
        if not text:match("^%s*$") then
            seen = true
            -- A JSON string may hold an apostrophe, so only double quotes delimit here.
            depth = M.depth_after((text:gsub("'", "")), depth)
        end
        if seen and depth <= 0 then
            return i
        end
    end
    return first
end

return M
