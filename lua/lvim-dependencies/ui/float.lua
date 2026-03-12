-- Floating window utility module (optimized)
-- Single-window informational display with horizontal lock

---@include "core/types.lua"

local api = vim.api
local config = require("lvim-dependencies.config")

local M = {}

-- Highlight groups from config
local G = config.highlight.groups

---@class FloatOptions
---@field width? number|string
---@field height? number|string
---@field max_height? number
---@field border? string|string[]
---@field title? string
---@field filetype? string
---@field wrap? boolean
---@field cursorline? boolean
---@field cursorcolumn? boolean
---@field concealcursor? string
---@field conceallevel? integer
---@field close_keymaps? string[]
---@field lock_horizontal? boolean

-- Default options
local defaults = {
    width = config.ui.float.width or "auto",
    height = config.ui.float.height or "auto",
    max_height = config.ui.float.max_height or 0.8,
    border = config.ui.float.border or "rounded",
    title = nil,
    filetype = "LvimDepsInfo",
    wrap = false,
    cursorline = false,
    cursorcolumn = false,
    concealcursor = "nvic",
    conceallevel = 2,
    close_keymaps = { "q", "<ESC>" },
    lock_horizontal = true, -- Always active
}

--- Get display width of a string
---@param s string|nil
---@return integer
local function display_width(s)
    return vim.fn.strdisplaywidth(tostring(s or ""))
end

--- Calculate optimal dimensions based on content
---@param lines string[]
---@param opts FloatOptions
---@return integer width, integer height
local function calculate_dimensions(lines, opts)
    local max_line_length = 0
    for _, line in ipairs(lines) do
        max_line_length = math.max(max_line_length, display_width(line))
    end

    -- width is always resolved to number here
    local width = opts.width
    if type(width) == "number" then
        if width > 0 and width <= 1 then
            local ui = api.nvim_list_uis()[1]
            local editor_width = ui and ui.width or vim.o.columns
            width = math.floor(width * editor_width)
        else
            width = math.floor(width)
        end
    elseif width == "auto" then
        width = math.min(max_line_length + 4, vim.o.columns - 6)
    else
        width = math.min(max_line_length + 4, vim.o.columns - 6) -- fallback
    end

    -- height is always resolved to number here
    local height = opts.height
    if type(height) == "number" then
        if height > 0 and height <= 1 then
            local ui = api.nvim_list_uis()[1]
            local editor_height = ui and ui.height or vim.o.lines
            height = math.floor(height * editor_height)
        else
            height = math.floor(height)
        end
    elseif height == "auto" then
        local max_h = opts.max_height
        if max_h <= 1 then
            max_h = math.floor(max_h * vim.o.lines)
        end
        height = math.min(#lines, max_h)
    else
        local max_h = opts.max_height
        if max_h <= 1 then
            max_h = math.floor(max_h * vim.o.lines)
        end
        height = math.min(#lines, max_h) -- fallback
    end

    return width, height
end

--- Calculate centered position
---@param width integer
---@param height integer
---@return integer row, integer col
local function calculate_position(width, height)
    local ui = api.nvim_list_uis()[1]
    local editor_width = ui and ui.width or vim.o.columns
    local editor_height = ui and ui.height or vim.o.lines

    local row = math.floor((editor_height - height) / 2)
    local col = math.floor((editor_width - width) / 2)

    return row, col
end

--- Get border characters
---@param border string|string[]
---@return string[]
local function get_border_chars(border)
    if type(border) == "table" then
        return border
    end

    local borders = {
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
        none = { "", "", "", "", "", "", "", "" },
    }

    return borders[border] or borders.rounded
end

--- Setup window options
---@param win integer
local function setup_window(win)
    api.nvim_set_option_value("scrolloff", 0, { win = win })
    api.nvim_set_option_value("wrap", false, { win = win })
    api.nvim_set_option_value("winbar", "", { win = win })
    api.nvim_set_option_value("cursorline", true, { win = win })
    api.nvim_set_option_value("cursorcolumn", false, { win = win })
    api.nvim_set_option_value("concealcursor", "nvic", { win = win })
    api.nvim_set_option_value("conceallevel", 2, { win = win })

    api.nvim_set_option_value("winhighlight", "NormalFloat:" .. G.normal .. ",FloatBorder:" .. G.border, { win = win })
end

--- Make buffer non-modifiable and protect it
---@param buf integer
local function make_buffer_readonly(buf)
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end

    api.nvim_buf_set_option(buf, "modifiable", false)
    api.nvim_buf_set_option(buf, "readonly", true)
    api.nvim_buf_set_option(buf, "modified", false)
    api.nvim_buf_set_option(buf, "buftype", "nofile")

    -- Disable modification keys (only in this buffer)
    local keymap_opts = { buffer = buf, silent = true, nowait = true }
    local disable_keys = {
        "a",
        "i",
        "o",
        "A",
        "I",
        "O",
        "c",
        "C",
        "cc",
        "d",
        "D",
        "dd",
        "p",
        "P",
        "r",
        "R",
        "s",
        "S",
        "x",
        "X",
        "<Del>",
        "<BS>",
    }
    for _, key in ipairs(disable_keys) do
        vim.keymap.set("n", key, "<Nop>", keymap_opts)
    end
    vim.keymap.set("v", "d", "<Nop>", keymap_opts)
    vim.keymap.set("v", "c", "<Nop>", keymap_opts)
    vim.keymap.set("v", "x", "<Nop>", keymap_opts)
    vim.keymap.set("v", "p", "<Nop>", keymap_opts)
end

--- Lock cursor to the beginning of the line (autocmd-based)
---@param buf integer
---@param win integer
local function setup_horizontal_lock(buf, win)
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end

    local augroup = "float_horizontal_lock_" .. buf
    pcall(api.nvim_del_augroup_by_name, augroup)

    local group = api.nvim_create_augroup(augroup, { clear = true })

    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        buffer = buf,
        callback = function()
            if not win or not api.nvim_win_is_valid(win) then
                return
            end
            local cur_pos = api.nvim_win_get_cursor(win)
            if cur_pos[2] > 0 then
                api.nvim_win_set_cursor(win, { cur_pos[1], 0 })
            end
        end,
    })
end

--- Create a floating window
---@param content string|string[] The content to display
---@param title string|nil Optional title
---@return integer buf, integer win
function M.open(content, title)
    local opts = vim.tbl_deep_extend("force", defaults, { title = title })

    local lines = type(content) == "string" and vim.split(content, "\n") or content
    if opts.title then
        table.insert(lines, 1, "") -- blank line for title spacing
    end

    local width, height = calculate_dimensions(lines, opts)
    local row, col = calculate_position(width, height)

    -- Create buffer
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(buf, "buftype", "nofile")
    api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    api.nvim_buf_set_option(buf, "filetype", opts.filetype)
    api.nvim_buf_set_option(buf, "swapfile", false)

    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_buf_set_option(buf, "wrap", opts.wrap)
    api.nvim_buf_set_option(buf, "statuscolumn", "")
    api.nvim_buf_set_option(buf, "signcolumn", "yes")

    -- Border configuration
    local border_chars = get_border_chars(opts.border)
    local border = {
        { border_chars[1], G.border },
        { border_chars[2], G.border },
        { border_chars[3], G.border },
        { border_chars[4], G.border },
        { border_chars[5], G.border },
        { border_chars[6], G.border },
        { border_chars[7], G.border },
        { border_chars[8], G.border },
    }

    local win_config = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = border,
    }

    if opts.title then
        win_config.title = { { " " .. opts.title .. " ", G.title } }
        win_config.title_pos = "center"
    end

    local win = api.nvim_open_win(buf, true, win_config)

    setup_window(win)
    make_buffer_readonly(buf)
    setup_horizontal_lock(buf, win)

    -- Close keymaps
    local keymap_opts = { buffer = buf, silent = true, nowait = true }
    for _, key in ipairs(opts.close_keymaps) do
        vim.keymap.set("n", key, function()
            M.close(win)
        end, keymap_opts)
    end

    -- Disable horizontal movement keys in normal mode
    local horizontal_remaps = {
        ["l"] = "<Nop>",
        ["<Right>"] = "<Nop>",
        ["$"] = "<Nop>",
        ["^"] = "0", -- still go to column 0
    }
    for key, repl in pairs(horizontal_remaps) do
        vim.keymap.set("n", key, repl, { buffer = buf, silent = true, remap = false })
    end
    vim.keymap.set("i", "<Right>", "<Nop>", { buffer = buf, silent = true })

    -- Place cursor at start of first line
    pcall(api.nvim_win_set_cursor, win, { 1, 0 })

    -- Optional markview support (unchanged)
    local ok, markview = pcall(require, "markview")
    if ok and markview and markview.render then
        local original_ft = vim.bo[buf].filetype
        vim.bo[buf].filetype = "markdown"
        pcall(markview.render, buf)
        vim.bo[buf].filetype = original_ft
    end

    return buf, win
end

--- Close float window
---@param win integer
function M.close(win)
    if win and api.nvim_win_is_valid(win) then
        local buf = api.nvim_win_get_buf(win)
        if buf and api.nvim_buf_is_valid(buf) then
            pcall(api.nvim_del_augroup_by_name, "float_horizontal_lock_" .. buf)
        end
        api.nvim_win_close(win, true)
        if buf and api.nvim_buf_is_valid(buf) then
            pcall(api.nvim_buf_delete, buf, { force = true })
        end
    end
end

return M
