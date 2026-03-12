-- lvim-dependencies/ui/popup.lua
-- Floating popup window management (single window, sticky footer)
-- Supports select, multiselect, and input modes
-- Subject is always passed (no backward-compatibility hacks)
-- Versions are left-aligned with fixed marker column

---@include "core/types.lua"

local api = vim.api
local config = require("lvim-dependencies.config")

local M = {}
local NS = api.nvim_create_namespace("lvim_deps_popup_ns")

local G = config.highlight.groups
local popup_config = config.ui.popup

---@alias PopupMode "select"|"multiselect"|"input"

---@class PopupOptions
---@field mode? PopupMode
---@field default_index? integer
---@field initial_selected? table<string, boolean>
---@field current_item? string
---@field placeholder? string

--- Get display width of a string
---@param s string|nil
---@return integer
local function display_width(s)
    return vim.fn.strdisplaywidth(tostring(s or ""))
end

--- Center text in a given width
---@param s string|nil
---@param width integer
---@return string
local function center_text(s, width)
    s = tostring(s or "")
    local len = display_width(s)
    if len >= width then
        return s
    end
    local left = math.floor((width - len) / 2)
    local right = width - len - left
    return string.rep(" ", left) .. s .. string.rep(" ", right)
end

--- Left align text with indent
---@param s string|nil
---@param width integer
---@param indent? integer
---@return string
local function left_align(s, width, indent)
    indent = indent or 2
    s = tostring(s or "")
    local indent_str = string.rep(" ", indent)
    s = indent_str .. s
    local len = display_width(s)
    if len >= width then
        return s
    end
    return s .. string.rep(" ", width - len)
end

--- Clear namespace for buffer
---@param buf integer
local function clear_ns(buf)
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

--- Apply highlight to a line
---@param buf integer
---@param row integer
---@param group string|nil
local function hl(buf, row, group)
    if not group then
        return
    end
    api.nvim_buf_set_extmark(buf, NS, row, 0, {
        line_hl_group = group,
        priority = 200,
    })
end

--- Normalize items to table
---@param items any
---@return string[]
local function normalize_items(items)
    if not items then
        return {}
    end
    if type(items) == "table" then
        return items
    end
    return { tostring(items) }
end

-- Fixed marker column width (enough for marker + space)
local MARKER_WIDTH = 2

--- Format item for select mode
---@param item string
---@param is_current boolean
---@return string
local function format_select_item(item, is_current)
    local marker = is_current and popup_config.current or " "
    local marker_w = display_width(marker)
    local pad = math.max(0, MARKER_WIDTH - marker_w)
    return marker .. string.rep(" ", pad) .. item
end

--- Get border configuration
---@return table[]
local function get_border()
    if popup_config.border and type(popup_config.border) == "table" and #popup_config.border == 8 then
        local b = popup_config.border
        return {
            { b[1], G.border },
            { b[2], G.border },
            { b[3], G.border },
            { b[4], G.border },
            { b[5], G.border },
            { b[6], G.border },
            { b[7], G.border },
            { b[8], G.border },
        }
    end

    local style = popup_config.border_style or "rounded"
    local borders = {
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
    }
    local b = borders[style] or borders.rounded
    return {
        { b[1], G.border },
        { b[2], G.border },
        { b[3], G.border },
        { b[4], G.border },
        { b[5], G.border },
        { b[6], G.border },
        { b[7], G.border },
        { b[8], G.border },
    }
end

--- Main popup (single window, sticky footer)
---@param title string|nil
---@param subtitle string|nil
---@param subject string|nil
---@param items string[]
---@param callback fun(confirmed: boolean, result: any)
---@param opts PopupOptions
local function open_popup(title, subtitle, subject, items, callback, opts)
    opts = opts or {}
    local mode = opts.mode or "select"
    local default_index = opts.default_index
    local initial_selected = opts.initial_selected or {}
    local current_item = opts.current_item
    local placeholder = opts.placeholder or ""

    items = normalize_items(items)

    -- Save view state BEFORE opening popup
    local saved_win = api.nvim_get_current_win()
    local saved_view = vim.fn.winsaveview()

    -- Build header lines
    local header = {}
    if title then
        table.insert(header, title)
    end
    if subtitle then
        table.insert(header, subtitle)
    end
    if subject then
        table.insert(header, "")
        table.insert(header, subject)
    end
    if #header > 0 then
        table.insert(header, "")
    end
    local header_height = #header

    -- Footer text
    local footer_text
    if mode == "input" then
        footer_text = "Press <CR> to submit, <Esc> to cancel"
    elseif mode == "multiselect" then
        footer_text = "<Space> toggle | <CR> confirm | <Esc> cancel"
    else
        footer_text = "<CR> confirm | <Esc> cancel"
    end
    local footer_lines = { "", footer_text }
    local footer_height = 2

    -- Determine window width
    local max_width = display_width(footer_text)
    for _, l in ipairs(header) do
        max_width = math.max(max_width, display_width(l))
    end
    if mode == "input" then
        max_width = math.max(max_width, display_width(placeholder))
    else
        for _, item in ipairs(items) do
            if mode == "multiselect" then
                max_width = math.max(max_width, display_width("[ ] " .. item))
            else
                -- For select mode, we use fixed marker width, so add marker area width
                local line = string.rep(" ", MARKER_WIDTH) .. item
                max_width = math.max(max_width, display_width(line))
            end
        end
    end
    local width = math.min(max_width + 4, vim.o.columns - 6)

    -- Determine content height (number of items to show)
    local max_items = popup_config.max_items or 20
    local content_height = math.min(#items, max_items)
    if mode == "input" then
        content_height = 1
    end

    -- Apply max_height limit (overall window height)
    local total_height = header_height + content_height + footer_height
    local max_height = popup_config.max_height
    if max_height then
        if max_height <= 1 then
            max_height = math.floor(max_height * vim.o.lines)
        end
        total_height = math.min(total_height, max_height)
        -- Recalculate content height if we had to shrink
        content_height = math.max(1, total_height - header_height - footer_height)
    end

    local row = math.floor((vim.o.lines - total_height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create buffer and window
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "LvimDeps"

    local win = api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = total_height,
        row = row,
        col = col,
        border = get_border(),
        style = "minimal",
    })

    api.nvim_set_option_value("winhighlight", "NormalFloat:" .. G.normal .. ",FloatBorder:" .. G.border, { win = win })
    api.nvim_set_option_value("wrap", false, { win = win })
    api.nvim_set_option_value("scrolloff", 0, { win = win })
    api.nvim_set_option_value("cursorline", true, { win = win })

    -- State
    local current_idx = 0
    if mode == "select" and default_index and default_index >= 1 and default_index <= #items then
        current_idx = default_index - 1
    elseif mode == "select" and current_item then
        for idx, item in ipairs(items) do
            if item == current_item then
                current_idx = idx - 1
                break
            end
        end
    end

    -- Ensure current_idx is within items range
    current_idx = math.min(current_idx, #items - 1)
    current_idx = math.max(current_idx, 0)

    local scroll = 0
    -- Adjust scroll if current_idx is out of visible range
    if current_idx < scroll then
        scroll = current_idx
    elseif current_idx >= scroll + content_height then
        scroll = current_idx - content_height + 1
    end
    scroll = math.max(0, math.min(scroll, #items - content_height))

    local selected = vim.deepcopy(initial_selected)

    -- Render function
    local function render()
        clear_ns(buf)

        local lines = {}

        -- Header (centered)
        for _, l in ipairs(header) do
            table.insert(lines, center_text(l, width))
        end

        -- Content slice (left-aligned)
        if mode == "input" then
            table.insert(lines, left_align(placeholder, width, 2))
        elseif mode == "multiselect" then
            for i = 1, content_height do
                local idx = scroll + i
                local item = items[idx]
                if item then
                    local mark = selected[item] and "[x]" or "[ ]"
                    local raw = mark .. " " .. item
                    table.insert(lines, left_align(raw, width, 2))
                else
                    table.insert(lines, left_align("", width, 2))
                end
            end
        else -- select mode
            for i = 1, content_height do
                local idx = scroll + i
                local item = items[idx]
                if item then
                    local is_current = current_item and (item == current_item)
                    local raw = format_select_item(item, is_current)
                    table.insert(lines, left_align(raw, width, 2))
                else
                    table.insert(lines, left_align("", width, 2))
                end
            end
        end

        -- Footer (centered)
        for _, l in ipairs(footer_lines) do
            table.insert(lines, center_text(l, width))
        end

        -- Write lines
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = (mode == "input")

        -- Header highlights
        for i = 1, header_height do
            if header[i] == title then
                hl(buf, i - 1, G.title)
            elseif header[i] == subtitle then
                hl(buf, i - 1, G.sub_title)
            elseif header[i] == subject then
                hl(buf, i - 1, G.subject)
            end
        end

        -- Content highlights
        if mode == "input" then
            hl(buf, header_height, G.input)
        else
            for i = 1, content_height do
                local global = scroll + i - 1
                local row_idx = header_height + i - 1
                if global == current_idx then
                    hl(buf, row_idx, G.line_active)
                elseif mode == "multiselect" and items[global + 1] and selected[items[global + 1]] then
                    hl(buf, row_idx, G.up_to_date)
                else
                    hl(buf, row_idx, G.line_inactive)
                end
            end
        end

        -- Footer highlight (last line)
        hl(buf, #lines - 1, G.navigation)

        -- Place cursor
        if mode == "input" then
            api.nvim_win_set_cursor(win, { header_height + 1, #placeholder + 2 }) -- +2 for indent
        else
            if current_idx >= scroll and current_idx < scroll + content_height then
                local cursor_row = header_height + (current_idx - scroll) + 1
                api.nvim_win_set_cursor(win, { cursor_row, 0 })
            else
                api.nvim_win_set_cursor(win, { header_height + 1, 0 })
            end
        end
    end

    render()

    -- Movement
    local function move(delta)
        if mode == "input" then
            return
        end
        local new = current_idx + delta
        if new < 0 or new >= #items then
            return
        end
        current_idx = new
        if current_idx < scroll then
            scroll = current_idx
        elseif current_idx >= scroll + content_height then
            scroll = current_idx - content_height + 1
        end
        render()
    end

    -- Close function with view restoration
    local function close(confirmed, result)
        -- Close popup first
        pcall(api.nvim_win_close, win, true)
        pcall(api.nvim_buf_delete, buf, { force = true })

        -- Restore view state
        vim.schedule(function()
            if saved_win and api.nvim_win_is_valid(saved_win) then
                pcall(vim.fn.winrestview, saved_view)
            end
        end)

        if callback then
            callback(confirmed, result)
        end
    end

    -- Keymaps
    local key_opts = { buffer = buf, silent = true, nowait = true }

    -- Disable horizontal movement
    local horizontal = { "h", "l", "<Left>", "<Right>", "0", "^", "$" }
    for _, key in ipairs(horizontal) do
        vim.keymap.set({ "n", "v" }, key, "<Nop>", key_opts)
    end

    if mode == "input" then
        vim.schedule(function()
            vim.cmd("startinsert")
        end)
        vim.keymap.set("i", "<CR>", function()
            local lines = api.nvim_buf_get_lines(buf, header_height, header_height + 1, false)
            local input = lines[1]:gsub("^%s+", "") -- strip left indent
            vim.cmd("stopinsert")
            close(true, input)
        end, key_opts)
        vim.keymap.set({ "i", "n" }, "<Esc>", function()
            vim.cmd("stopinsert")
            close(false, nil)
        end, key_opts)
    else
        vim.keymap.set("n", "j", function()
            move(1)
        end, key_opts)
        vim.keymap.set("n", "k", function()
            move(-1)
        end, key_opts)

        if mode == "multiselect" then
            vim.keymap.set("n", "<Space>", function()
                local item = items[current_idx + 1]
                if item then
                    selected[item] = not selected[item]
                    render()
                end
            end, key_opts)
            vim.keymap.set("n", "x", function()
                local item = items[current_idx + 1]
                if item then
                    selected[item] = not selected[item]
                    render()
                end
            end, key_opts)
            vim.keymap.set("n", "<CR>", function()
                close(true, selected)
            end, key_opts)
        else -- select mode
            vim.keymap.set("n", "<CR>", function()
                close(true, current_idx + 1)
            end, key_opts)
        end

        vim.keymap.set("n", "<Esc>", function()
            close(false, nil)
        end, key_opts)
        vim.keymap.set("n", "q", function()
            close(false, nil)
        end, key_opts)
    end
end

--- Public API
---@param title string|nil
---@param subtitle string|nil
---@param subject string|nil
---@param items any[]
---@param callback fun(confirmed: boolean, result: any)
---@param opts? PopupOptions
function M.select(title, subtitle, subject, items, callback, opts)
    opts = opts or {}
    opts.mode = "select"
    open_popup(title, subtitle, subject, items, callback, opts)
end

---@param title string|nil
---@param subtitle string|nil
---@param subject string|nil
---@param items any[]
---@param callback fun(confirmed: boolean, result: any)
---@param opts? PopupOptions
function M.multiselect(title, subtitle, subject, items, callback, opts)
    opts = opts or {}
    opts.mode = "multiselect"
    open_popup(title, subtitle, subject, items, callback, opts)
end

---@param title string|nil
---@param subtitle string|nil
---@param placeholder string|nil
---@param callback fun(confirmed: boolean, result: any)
function M.input(title, subtitle, placeholder, callback)
    open_popup(title, subtitle, nil, {}, callback, { mode = "input", placeholder = placeholder or "" })
end

-- Aliases for backward compatibility
M.confirm_async = M.select
M.multiselect_async = M.multiselect
M.input_async = M.input

return M
