local api = vim.api
local config = require("lvim-dependencies.config")

local M = {}
local NS = api.nvim_create_namespace("lvim_deps_popup_ns")

local G = config.ui.highlight.groups

local function display_width(s)
    return vim.fn.strdisplaywidth(tostring(s or ""))
end

local function center_text(s, w)
    s = tostring(s or "")
    local len = display_width(s)
    if len >= w then
        return s
    end
    local left = math.floor((w - len) / 2)
    local right = w - len - left
    return string.rep(" ", left) .. s .. string.rep(" ", right)
end

local function pad_right(s, w)
    s = tostring(s or "")
    local len = display_width(s)
    if len >= w then
        return s
    end
    return s .. string.rep(" ", w - len)
end

local function set_line_highlight(buf, row, hl, end_col)
    if not hl then
        return
    end
    api.nvim_buf_set_extmark(buf, NS, row, 0, {
        end_row = row,
        end_col = end_col,
        hl_group = hl,
        priority = 200,
    })
end

local function build_sections(title, subtitle, subject, lines, mode)
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
        table.insert(header, "")
    end

    if #header > 0 then
        table.insert(header, "")
    end

    if (mode == "input" or mode == "multiselect") and #header > 0 then
        table.insert(header, "")
    end

    local footer
    if mode == "input" then
        footer = { "", "Press <CR> to submit, <Esc> to cancel" }
    elseif mode == "multiselect" then
        footer = { "", "<Space> toggle, <CR> confirm, <Esc> cancel" }
    else
        footer = { "", "Press y / <CR> to confirm, n / <Esc> to cancel" }
    end

    return header, lines or {}, footer
end

local function render_multiselect_content(buf, items, selected, current_idx, inner_width)
    api.nvim_set_option_value("modifiable", true, { buf = buf })

    local lines = {}
    for _, item in ipairs(items) do
        local checkbox = selected[item.id] and "[x]" or "[ ]"
        local suffix = ""
        if item.deps and #item.deps > 0 then
            suffix = " -> " .. table.concat(item.deps, ", ")
        end
        local line = string.format(" %s %s%s", checkbox, item.label, suffix)
        table.insert(lines, pad_right(line, inner_width))
    end

    if #lines == 0 then
        lines = { pad_right(" No items available", inner_width) }
    end

    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_set_option_value("modifiable", false, { buf = buf })

    api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    for i, item in ipairs(items) do
        local hl
        if i - 1 == current_idx then
            hl = G.line_active
        elseif selected[item.id] then
            hl = G.up_to_date
        else
            hl = G.line_inactive
        end
        set_line_highlight(buf, i - 1, hl, #lines[i])
    end
end

local function resolve_border_chars(raw_border)
    local function split_border(b)
        local top = { b[1], b[2], b[3], b[4], "", "", "", b[8] }
        local mid = { "", "", "", b[4], "", "", "", b[8] }
        local bot = { "", "", "", b[4], b[5], b[6], b[7], b[8] }
        return top, mid, bot
    end

    local styles = {
        rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
        single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
        double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
        none = { "", "", "", "", "", "", "", "" },
    }

    if type(raw_border) == "table" and #raw_border == 8 then
        return split_border(raw_border)
    elseif type(raw_border) == "string" and styles[raw_border] then
        return split_border(styles[raw_border])
    else
        return split_border(styles.rounded)
    end
end

local function calculate_dimensions(cfg, header_h, footer_h, content_len, max_content_width)
    local width = cfg.width == "auto" and math.min(max_content_width + 4, vim.o.columns - 6) or math.floor(cfg.width)

    local content_h
    if cfg.height == "auto" then
        local max_total_h = cfg.max_height <= 1 and math.floor(cfg.max_height * vim.o.lines) or cfg.max_height
        local max_content_h = math.max(1, max_total_h - header_h - footer_h)
        content_h = math.min(content_len, max_content_h)
    else
        local total_h = cfg.height <= 1 and math.floor(cfg.height * vim.o.lines) or cfg.height
        content_h = math.max(1, total_h - header_h - footer_h)
    end

    local row = math.floor((vim.o.lines - (header_h + content_h + footer_h)) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    return width, content_h, row, col
end

local function setup_window(win)
    api.nvim_set_option_value("winhighlight", "NormalFloat:" .. G.normal .. ",FloatBorder:" .. G.border, { win = win })
    api.nvim_set_option_value("scrolloff", 0, { win = win })
    api.nvim_set_option_value("wrap", false, { win = win })
end

local function create_header_window(header, title, subtitle, subject, row, col, width, border_chars)
    local buf = api.nvim_create_buf(false, true)
    local win = api.nvim_open_win(buf, false, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = #header,
        border = border_chars,
        style = "minimal",
        focusable = false,
        zindex = 10,
    })
    setup_window(win)

    local inner_w = api.nvim_win_get_width(win)

    for i, line in ipairs(header) do
        local padded = center_text(line, inner_w)
        api.nvim_buf_set_lines(buf, i - 1, i, false, { padded })

        local hl = nil
        if line == subject then
            hl = G.subject
        elseif title and line == title then
            hl = G.title
        elseif subtitle and line == subtitle then
            hl = G.sub_title
        end

        if hl then
            set_line_highlight(buf, i - 1, hl, #padded)
        end
    end

    api.nvim_set_option_value("modifiable", false, { buf = buf })
    return buf, win
end

local function create_footer_window(footer, row, col, width, border_chars)
    local buf = api.nvim_create_buf(false, true)
    local win = api.nvim_open_win(buf, false, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = #footer,
        border = border_chars,
        style = "minimal",
        focusable = false,
        zindex = 10,
    })
    setup_window(win)

    local inner_w = api.nvim_win_get_width(win)

    for i, line in ipairs(footer) do
        local padded = center_text(line, inner_w)
        api.nvim_buf_set_lines(buf, i - 1, i, false, { padded })
        if i == #footer and G.navigation then
            set_line_highlight(buf, i - 1, G.navigation, #padded)
        end
    end

    api.nvim_set_option_value("modifiable", false, { buf = buf })
    return buf, win
end

local function open_popup(header, content, footer, cfg, title, subtitle, subject, callback, opts)
    opts = opts or {}
    local mode = opts.mode or "select"
    local default_index = opts.default_index
    local items = opts.items or {}
    local initial_selected = opts.initial_selected or {}

    local all_lines = {}
    vim.list_extend(all_lines, header)
    vim.list_extend(all_lines, footer)

    if mode == "multiselect" then
        for _, item in ipairs(items) do
            local suffix = (item.deps and #item.deps > 0) and (" -> " .. table.concat(item.deps, ", ")) or ""
            table.insert(all_lines, string.format(" [x] %s%s", item.label, suffix))
        end
    else
        vim.list_extend(all_lines, content)
    end

    local max_w = 0
    for _, l in ipairs(all_lines) do
        max_w = math.max(max_w, display_width(l))
    end

    local content_len
    if mode == "input" then
        content_len = 1
    elseif mode == "multiselect" then
        content_len = math.max(1, #items)
    else
        content_len = #content
    end

    local width, content_h, row, col = calculate_dimensions(cfg, #header, #footer, content_len, max_w)
    local border_top, border_mid, border_bot = resolve_border_chars(cfg.border or "single")

    local hbuf, hwin = create_header_window(header, title, subtitle, subject, row, col, width, border_top)
    local h_outer_h = api.nvim_win_get_height(hwin)

    local cbuf = api.nvim_create_buf(false, true)
    vim.bo[cbuf].filetype = "LvimDeps"

    local cwin = api.nvim_open_win(cbuf, true, {
        relative = "editor",
        row = row + h_outer_h,
        col = col,
        width = width,
        height = content_h,
        border = border_mid,
        style = "minimal",
        focusable = true,
        zindex = 20,
    })
    setup_window(cwin)

    local c_inner_w = api.nvim_win_get_width(cwin)
    local c_outer_h = api.nvim_win_get_height(cwin)

    local fbuf, fwin = create_footer_window(footer, row + h_outer_h + c_outer_h, col, width, border_bot)

    local current_idx = 0
    local active_extmark_id = nil
    local selected = vim.deepcopy(initial_selected)

    local function close(confirmed, result_data)
        if callback then
            vim.schedule(function()
                callback(confirmed, result_data)
            end)
        end
        pcall(api.nvim_win_close, hwin, true)
        pcall(api.nvim_win_close, cwin, true)
        pcall(api.nvim_win_close, fwin, true)
        pcall(api.nvim_buf_delete, hbuf, { force = true })
        pcall(api.nvim_buf_delete, cbuf, { force = true })
        pcall(api.nvim_buf_delete, fbuf, { force = true })
    end

    local function set_active_line(row_idx)
        if mode == "input" or mode == "multiselect" then
            return
        end
        local line = api.nvim_buf_get_lines(cbuf, row_idx, row_idx + 1, false)[1]
        if not line then
            return
        end
        active_extmark_id = api.nvim_buf_set_extmark(cbuf, NS, row_idx, 0, {
            end_row = row_idx,
            end_col = #line,
            hl_group = G.line_active,
            priority = 300,
        })
    end

    local keymap_opts = { buffer = cbuf, silent = true }

    if mode == "input" then
        api.nvim_set_option_value("modifiable", true, { buf = cbuf })
        api.nvim_buf_set_lines(cbuf, 0, 1, false, { "" })
        api.nvim_buf_set_extmark(cbuf, NS, 0, 0, {
            end_line = 0,
            line_hl_group = G.input,
            priority = 100,
        })

        local ok_cursor, cursor_mod = pcall(require, "lvim-dependencies.ui.cursor")
        if ok_cursor and type(cursor_mod.mark_input_buffer) == "function" then
            cursor_mod.mark_input_buffer(cbuf, true)
        end

        vim.schedule(function()
            vim.cmd("startinsert")
        end)

        vim.keymap.set("i", "<CR>", function()
            local lines = api.nvim_buf_get_lines(cbuf, 0, 1, false)
            vim.cmd("stopinsert")
            close(true, lines[1] or "")
        end, keymap_opts)

        vim.keymap.set("i", "<Esc>", function()
            vim.cmd("stopinsert")
            close(false, nil)
        end, keymap_opts)

        vim.keymap.set("n", "<Esc>", function()
            close(false, nil)
        end, keymap_opts)
    elseif mode == "multiselect" then
        render_multiselect_content(cbuf, items, selected, current_idx, c_inner_w)
        api.nvim_win_set_cursor(cwin, { current_idx + 1, 0 })

        local function toggle_current()
            if #items == 0 then
                return
            end
            local item = items[current_idx + 1]
            if item then
                selected[item.id] = not selected[item.id] or nil
                render_multiselect_content(cbuf, items, selected, current_idx, c_inner_w)
            end
        end

        vim.keymap.set({ "n", "v" }, "h", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "l", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "<Left>", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "<Right>", "<nop>", keymap_opts)

        vim.keymap.set("n", "j", function()
            if current_idx < #items - 1 then
                current_idx = current_idx + 1
                render_multiselect_content(cbuf, items, selected, current_idx, c_inner_w)
                api.nvim_win_set_cursor(cwin, { current_idx + 1, 0 })
            end
        end, keymap_opts)

        vim.keymap.set("n", "k", function()
            if current_idx > 0 then
                current_idx = current_idx - 1
                render_multiselect_content(cbuf, items, selected, current_idx, c_inner_w)
                api.nvim_win_set_cursor(cwin, { current_idx + 1, 0 })
            end
        end, keymap_opts)

        vim.keymap.set("n", "<Space>", toggle_current, keymap_opts)
        vim.keymap.set("n", "x", toggle_current, keymap_opts)
        vim.keymap.set("n", "<CR>", function()
            close(true, selected)
        end, keymap_opts)
        vim.keymap.set("n", "<Esc>", function()
            close(false, nil)
        end, keymap_opts)
        vim.keymap.set("n", "q", function()
            close(false, nil)
        end, keymap_opts)
    else
        for i, l in ipairs(content) do
            local padded = pad_right(l, c_inner_w)
            api.nvim_buf_set_lines(cbuf, i - 1, i, false, { padded })
            if G.line_inactive and vim.fn.hlexists(G.line_inactive) == 1 then
                set_line_highlight(cbuf, i - 1, G.line_inactive, #padded)
            end
        end
        api.nvim_set_option_value("modifiable", false, { buf = cbuf })

        if default_index and type(default_index) == "number" then
            current_idx = math.max(0, math.min(default_index - 1, #content - 1))
        end

        set_active_line(current_idx)
        api.nvim_win_set_cursor(cwin, { current_idx + 1, 0 })

        api.nvim_create_autocmd("CursorMoved", {
            buffer = cbuf,
            callback = function()
                local r = api.nvim_win_get_cursor(cwin)[1] - 1
                if r ~= current_idx then
                    if active_extmark_id then
                        pcall(api.nvim_buf_del_extmark, cbuf, NS, active_extmark_id)
                    end
                    current_idx = r
                    set_active_line(current_idx)
                end
            end,
        })

        vim.keymap.set({ "n", "v" }, "h", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "l", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "<Left>", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "<Right>", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "0", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "^", "<nop>", keymap_opts)
        vim.keymap.set({ "n", "v" }, "$", "<nop>", keymap_opts)

        vim.keymap.set("n", "j", function()
            if current_idx < #content - 1 then
                if active_extmark_id then
                    pcall(api.nvim_buf_del_extmark, cbuf, NS, active_extmark_id)
                end
                current_idx = current_idx + 1
                set_active_line(current_idx)
                api.nvim_win_set_cursor(cwin, { current_idx + 1, 0 })
            end
        end, keymap_opts)

        vim.keymap.set("n", "k", function()
            if current_idx > 0 then
                if active_extmark_id then
                    pcall(api.nvim_buf_del_extmark, cbuf, NS, active_extmark_id)
                end
                current_idx = current_idx - 1
                set_active_line(current_idx)
                api.nvim_win_set_cursor(cwin, { current_idx + 1, 0 })
            end
        end, keymap_opts)

        vim.keymap.set("n", "y", function()
            close(true, current_idx + 1)
        end, keymap_opts)
        vim.keymap.set("n", "<CR>", function()
            close(true, current_idx + 1)
        end, keymap_opts)
        vim.keymap.set("n", "n", function()
            close(false, nil)
        end, keymap_opts)
        vim.keymap.set("n", "<Esc>", function()
            close(false, nil)
        end, keymap_opts)
    end
end

function M.select(title, subtitle, subject, items, callback, opts)
    local cfg = config.ui.floating
    opts = opts or {}
    opts.mode = "select"
    local header, content, footer = build_sections(title, subtitle, subject, items, "select")
    open_popup(header, content, footer, cfg, title, subtitle, subject, callback, opts)
end

function M.input(title, subtitle, placeholder, callback)
    local cfg = config.ui.floating
    local opts = { mode = "input", placeholder = placeholder or "" }
    local header, content, footer = build_sections(title, subtitle, nil, {}, "input")
    open_popup(header, content, footer, cfg, title, subtitle, nil, callback, opts)
end

function M.multiselect(title, subtitle, items, initial_selected, callback)
    local cfg = config.ui.floating
    local opts = {
        mode = "multiselect",
        items = items,
        initial_selected = initial_selected or {},
    }
    local header, content, footer = build_sections(title, subtitle, nil, {}, "multiselect")
    open_popup(header, content, footer, cfg, title, subtitle, nil, callback, opts)
end

M.confirm_async = M.select
M.input_async = M.input
M.multiselect_async = M.multiselect

return M
