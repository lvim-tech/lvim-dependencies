-- lvim-dependencies.utils.buffer: buffer inspection/mutation helpers that stay safe in a
-- fast-event context. In `vim.in_fast_event()` most `nvim_buf_*` calls are forbidden, so
-- every accessor degrades gracefully there (returns minimal info / no-ops) rather than
-- erroring, which lets the same helpers be called from autocmd fast callbacks.
--
---@module "lvim-dependencies.utils.buffer"

local api = vim.api

local M = {}

---@class BufferInfo
---@field filename string Full path to buffer file
---@field filetype string Buffer filetype
---@field lines integer Number of lines in buffer
---@field modified boolean Whether buffer has unsaved changes

---@class MinimalBufferInfo
---@field filename string Full path to buffer file (empty string if error)
---@field filetype string Always "unknown" in fast event context
---@field lines integer Always 0 in fast event context
---@field modified boolean Always false in fast event context

---@class BufferState
---@field buf integer Buffer number
---@field filename string Current filename
---@field filetype string Current filetype
---@field created integer Creation timestamp
---@field last_accessed integer Last access timestamp
---@field count_open integer Number of times buffer was opened
---@field count_save integer Number of times buffer was saved
---@field count_modification integer Number of modifications
---@field count_filetype_changes integer Number of filetype changes
---@field count_enter integer Number of times buffer was entered
---@field is_open boolean Whether buffer is currently open
---@field modified boolean Current modified state
---@field last_event string Last event type

--- Check if buffer is valid (safe for fast events)
---@param buf integer|nil Buffer number
---@return boolean
function M.is_valid(buf)
    if not buf then
        return false
    end

    if vim.in_fast_event() then
        return true
    end

    return api.nvim_buf_is_valid(buf)
end

--- Get minimal buffer information for fast event context
---@param buf integer Buffer number
---@return MinimalBufferInfo
local function get_fast_event_info(buf)
    local ok, name = pcall(api.nvim_buf_get_name, buf)
    return {
        filename = ok and name or "",
        filetype = "unknown",
        lines = 0,
        modified = false,
    }
end

--- Get complete buffer information
---@param buf integer Buffer number
---@return BufferInfo|nil
local function get_full_info(buf)
    local ok, result = pcall(function()
        return {
            filename = api.nvim_buf_get_name(buf),
            filetype = api.nvim_buf_get_option(buf, "filetype"),
            lines = api.nvim_buf_line_count(buf),
            modified = api.nvim_buf_get_option(buf, "modified"),
        }
    end)

    return ok and result or nil
end

--- Get buffer information (safe for fast events)
---@param buf integer Buffer number
---@return BufferInfo|MinimalBufferInfo|nil
function M.get_info(buf)
    if not M.is_valid(buf) then
        return nil
    end

    if vim.in_fast_event() then
        return get_fast_event_info(buf)
    end

    return get_full_info(buf)
end

--- Create default buffer state entry
---@param buf integer Buffer number
---@return BufferState
local function create_default_state(buf)
    local now = os.time()
    return {
        buf = buf,
        filename = "",
        filetype = "",
        created = now,
        last_accessed = now,
        count_open = 0,
        count_save = 0,
        count_modification = 0,
        count_filetype_changes = 0,
        count_enter = 0,
        is_open = false,
        modified = false,
        last_event = "",
    }
end

--- Ensure buffer exists in state table (safe)
---@param buf integer Buffer number
---@param state_table table<integer, BufferState> State table to check/initialize
---@return BufferState
function M.ensure_in_state(buf, state_table)
    if not state_table[buf] then
        state_table[buf] = create_default_state(buf)
    end
    return state_table[buf]
end

--- Get buffer file extension (safe)
---@param buf integer Buffer number
---@return string|nil
function M.get_extension(buf)
    local info = M.get_info(buf)
    if not info or info.filename == "" then
        return nil
    end

    if vim.in_fast_event() then
        return info.filename:match("%.([^%.]+)$")
    end

    return vim.fn.fnamemodify(info.filename, ":e")
end

--- Check if buffer is empty/unnamed (safe)
---@param buf integer Buffer number
---@return boolean
function M.is_empty(buf)
    local info = M.get_info(buf)
    return not info or info.filename == ""
end

--- Get all valid buffer numbers (safe for fast events)
---@return integer[]
function M.get_all()
    if vim.in_fast_event() then
        return { M.get_current() }
    end

    ---@type integer[]
    local buffers = {}
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if M.is_valid(buf) then
            buffers[#buffers + 1] = buf
        end
    end
    return buffers
end

--- Find buffer by name pattern (safe)
---@param pattern string Lua pattern to match buffer name
---@return integer|nil
function M.find_by_name(pattern)
    for _, buf in ipairs(M.get_all()) do
        local info = M.get_info(buf)
        if info and info.filename:match(pattern) then
            return buf
        end
    end
    return nil
end

--- Get buffers by filetype (safe)
---@param filetype string Filetype to filter by
---@return integer[]
function M.get_by_filetype(filetype)
    ---@type integer[]
    local result = {}

    for _, buf in ipairs(M.get_all()) do
        local info = M.get_info(buf)
        if info and info.filetype == filetype then
            result[#result + 1] = buf
        end
    end

    return result
end

--- Get current buffer number (safe)
---@return integer
function M.get_current()
    return api.nvim_get_current_buf()
end

--- Set buffer option safely (safe for fast events)
---@param buf integer Buffer number
---@param option string Option name
---@param value any Option value
---@return boolean
function M.set_option(buf, option, value)
    if not M.is_valid(buf) then
        return false
    end

    if vim.in_fast_event() then
        return false
    end

    local ok = pcall(api.nvim_buf_set_option, buf, option, value)
    return ok
end

---@class KeymapOptions
---@field noremap? boolean Default: true
---@field silent? boolean Default: true
---@field nowait? boolean
---@field expr? boolean
---@field desc? string

--- Set buffer keymap safely (safe for fast events)
---@param buf integer Buffer number
---@param mode string|string[] Mapping mode (e.g., 'n', 'i', 'v')
---@param lhs string Left-hand side (key sequence)
---@param rhs string|function Right-hand side (action)
---@param opts? KeymapOptions Additional options
---@return boolean
function M.set_keymap(buf, mode, lhs, rhs, opts)
    if not M.is_valid(buf) then
        return false
    end

    if vim.in_fast_event() then
        return false
    end

    ---@type table
    local options = vim.tbl_extend("force", { noremap = true, silent = true }, opts or {})
    local ok = pcall(api.nvim_buf_set_keymap, buf, mode, lhs, rhs, options)
    return ok
end

return M
