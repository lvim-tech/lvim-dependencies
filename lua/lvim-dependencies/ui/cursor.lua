-- lua/lvim-dependencies/ui/cursor.lua
-- Cursor management for popup windows and input buffers

local api = vim.api
local schedule = vim.schedule
local utils = require("lvim-dependencies.utils")
local debug = utils.debug

local M = {}

local POPUP_FILETYPES = { "LvimDeps" }
local INPUT_BUFFERS = {}
local BLEND_AUGROUP = api.nvim_create_augroup("LvimDepsPopupBlendGroup", { clear = true })

--- Get current cursor highlight configuration
--- @return table|nil Cursor highlight table or nil if not available
local function get_cursor_highlight()
    if type(api.nvim_get_hl) == "function" then
        local ok, hl = pcall(api.nvim_get_hl, 0, { name = "Cursor" })
        if ok and type(hl) == "table" then
            return hl
        end
    end
    return nil
end

--- Set cursor blend value
--- @param value integer|string Blend value (0-100)
local function set_cursor_blend(value)
    schedule(function()
        pcall(function()
            local current = get_cursor_highlight()
            if type(api.nvim_set_hl) ~= "function" or type(current) ~= "table" then
                return
            end

            local hl = {}
            local fg = current["foreground"] or current["fg"]
            local bg = current["background"] or current["bg"]
            local sp = current["special"] or current["sp"]

            if fg ~= nil then
                hl.fg = fg
            end
            if bg ~= nil then
                hl.bg = bg
            end
            if sp ~= nil then
                hl.sp = sp
            end

            local bold = current["bold"]
            local underline = current["underline"]
            local undercurl = current["undercurl"]
            local italic = current["italic"]

            if bold ~= nil then
                hl.bold = bold
            end
            if underline ~= nil then
                hl.underline = underline
            end
            if undercurl ~= nil then
                hl.undercurl = undercurl
            end
            if italic ~= nil then
                hl.italic = italic
            end

            hl.blend = tonumber(value) or 0

            debug(string.format("Setting cursor blend to %d", value), vim.log.levels.TRACE)
            pcall(api.nvim_set_hl, 0, "Cursor", hl)
        end)
    end)
end

--- Check if buffer is marked as input buffer
--- @param bufnr integer Buffer number
--- @return boolean True if buffer is input buffer
local function is_input_buffer(bufnr)
    return INPUT_BUFFERS[bufnr] == true
end

--- Check if buffer is a popup buffer (and not an input buffer)
--- @param bufnr integer Buffer number
--- @return boolean True if buffer is a popup
local function is_popup_buffer(bufnr)
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then
        return false
    end

    -- Input buffers are not considered popups for cursor purposes
    if is_input_buffer(bufnr) then
        return false
    end

    local ok, ft = pcall(function()
        return vim.bo[bufnr].filetype
    end)

    if not ok or not ft then
        return false
    end

    return vim.tbl_contains(POPUP_FILETYPES, ft)
end

--- Check if any window has a popup buffer
--- @return boolean True if any popup window exists
local function any_window_has_popup()
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) then
            local ok, buf = pcall(api.nvim_win_get_buf, win)
            if ok and buf and is_popup_buffer(buf) then
                return true
            end
        end
    end
    return false
end

--- Update cursor state based on current window/buffer
local function update_cursor_state()
    local ok_win, current_win = pcall(api.nvim_get_current_win)
    if not ok_win or not current_win or not api.nvim_win_is_valid(current_win) then
        debug("No valid current window", vim.log.levels.TRACE)
        set_cursor_blend(0)
        return
    end

    local ok_buf, current_buf = pcall(api.nvim_win_get_buf, current_win)
    if not ok_buf or not current_buf or not api.nvim_buf_is_valid(current_buf) then
        debug("No valid current buffer", vim.log.levels.TRACE)
        set_cursor_blend(0)
        return
    end

    -- debug(string.format("Current buffer: %d", current_buf), vim.log.levels.DEBUG)
    debug(string.format("Is input buffer: %s", tostring(is_input_buffer(current_buf))), vim.log.levels.TRACE)
    debug(string.format("Is popup buffer: %s", tostring(is_popup_buffer(current_buf))), vim.log.levels.TRACE)

    -- Show cursor in input buffers (this overrides popup detection)
    if is_input_buffer(current_buf) then
        debug(string.format("INPUT OVERRIDE - showing cursor for buffer %d", current_buf), vim.log.levels.TRACE)
        set_cursor_blend(0)
        return
    end

    -- Hide cursor in popup buffers (select menus)
    if is_popup_buffer(current_buf) then
        debug(string.format("Popup buffer %d - hiding cursor", current_buf), vim.log.levels.TRACE)
        set_cursor_blend(100)
        return
    end

    -- If any popup window exists but we're not in it, hide cursor
    if any_window_has_popup() then
        debug("Popup exists elsewhere - hiding cursor", vim.log.levels.TRACE)
        set_cursor_blend(100)
    else
        debug("No popups - showing cursor", vim.log.levels.TRACE)
        set_cursor_blend(0)
    end
end

--- Mark buffer as input buffer or remove mark
--- @param bufnr integer Buffer number
--- @param is_input boolean True to mark as input, false to unmark
function M.mark_input_buffer(bufnr, is_input)
    if is_input then
        INPUT_BUFFERS[bufnr] = true
        debug(string.format("Marked buffer %d as INPUT", bufnr), vim.log.levels.TRACE)
        -- Force immediate update
        vim.schedule(update_cursor_state)
    else
        INPUT_BUFFERS[bufnr] = nil
        debug(string.format("Unmarked buffer %d as INPUT", bufnr), vim.log.levels.TRACE)
        vim.schedule(update_cursor_state)
    end
end

--- Initialize cursor management autocommands
function M.setup()
    api.nvim_create_autocmd({ "WinEnter", "WinLeave", "WinClosed" }, {
        group = BLEND_AUGROUP,
        callback = update_cursor_state,
    })

    api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
        group = BLEND_AUGROUP,
        callback = function(event)
            if event.buf then
                INPUT_BUFFERS[event.buf] = nil
            end
            update_cursor_state()
        end,
    })

    api.nvim_create_autocmd("CmdlineEnter", {
        group = BLEND_AUGROUP,
        callback = function()
            set_cursor_blend(0)
        end,
    })

    api.nvim_create_autocmd("CmdlineLeave", {
        group = BLEND_AUGROUP,
        callback = update_cursor_state,
    })

    api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
        group = BLEND_AUGROUP,
        callback = update_cursor_state,
    })
end

return M
