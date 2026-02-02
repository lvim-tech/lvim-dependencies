local api = vim.api
local config = require("lvim-dependencies.config")

local M = {}
local NS = api.nvim_create_namespace("lvim_deps_confirm_ns")

-- highlights ------------------------------------------------------

local G = config.ui.highlight.groups

-- helpers ---------------------------------------------------------

local function dw(s)
	return vim.fn.strdisplaywidth(tostring(s or ""))
end

local function center(s, w)
	s = tostring(s or "")
	local l = dw(s)
	if l >= w then
		return s
	end
	local left = math.floor((w - l) / 2)
	local right = w - l - left
	return string.rep(" ", left) .. s .. string.rep(" ", right)
end

local function pad(s, w)
	s = tostring(s or "")
	local l = dw(s)
	if l >= w then
		return s
	end
	return s .. string.rep(" ", w - l)
end

-- extmarks --------------------------------------------------------

local function mark(buf, row, hl, end_col)
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

-- blocks ----------------------------------------------------------

local function build(title, subtitle, subject, lines, is_input)
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
		table.insert(header, "") -- Extra empty line after subject
	end

	-- Add spacing before input/content
	if #header > 0 then
		table.insert(header, "")
	end

	-- INPUT MODE: Add extra empty line before input field
	if is_input and #header > 0 then
		table.insert(header, "")
	end

	local footer
	if is_input then
		footer = { "", "Press <CR> to submit, <Esc> to cancel" }
	else
		footer = { "", "Press y / <CR> to confirm, n / <Esc> to cancel" }
	end

	return header, lines or {}, footer
end

-- stacked popup ---------------------------------------------------

local function open(header, content, footer, cfg, title, subtitle, subject, cb, opts)
	opts = opts or {}
	local default_index = opts.default_index -- 1-based index to preselect
	local is_input = opts.is_input or false
	local placeholder = opts.placeholder or ""

	local all = {}
	vim.list_extend(all, header)

	if is_input then
		-- Add placeholder for input
		table.insert(all, placeholder)
	else
		vim.list_extend(all, content)
	end

	vim.list_extend(all, footer)

	local max_w = 0
	for _, l in ipairs(all) do
		max_w = math.max(max_w, dw(l))
	end

	local width = cfg.width == "auto" and math.min(max_w + 4, vim.o.columns - 6) or math.floor(cfg.width)

	-- HEIGHT CALCULATION ------------------------------------------------

	local header_h = #header
	local footer_h = #footer
	local content_len = is_input and 1 or #content

	local content_h

	if cfg.height == "auto" then
		local max_total_h = cfg.max_height <= 1 and math.floor(cfg.max_height * vim.o.lines) or cfg.max_height

		local fixed_h = header_h + footer_h
		local max_content_h = max_total_h - fixed_h
		if max_content_h < 1 then
			max_content_h = 1
		end

		if content_len <= max_content_h then
			content_h = content_len
		else
			content_h = max_content_h
		end
	else
		local total_fixed_h = cfg.height <= 1 and math.floor(cfg.height * vim.o.lines) or cfg.height

		local fixed_h = header_h + footer_h
		content_h = total_fixed_h - fixed_h
		if content_h < 1 then
			content_h = 1
		end
	end

	local row = math.floor((vim.o.lines - (header_h + content_h + footer_h)) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- DYNAMIC BORDER RESOLUTION -----------------------------------------

	local border_top_chars
	local border_mid_chars
	local border_bot_chars

	local raw_border = cfg.border or "single"

	local function split_border(b)
		local top = { b[1], b[2], b[3], b[4], "", "", "", b[8] }
		local mid = { "", "", "", b[4], "", "", "", b[8] }
		local bot = { "", "", "", b[4], b[5], b[6], b[7], b[8] }
		return top, mid, bot
	end

	if type(raw_border) == "table" and #raw_border == 8 then
		border_top_chars, border_mid_chars, border_bot_chars = split_border(raw_border)
	elseif type(raw_border) == "string" then
		local styles = {
			rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
			single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
			double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
			none = { "", "", "", "", "", "", "", "" },
		}

		local chars = styles[raw_border]
		if chars then
			border_top_chars, border_mid_chars, border_bot_chars = split_border(chars)
		else
			border_top_chars, border_mid_chars, border_bot_chars = split_border(styles.rounded)
		end
	else
		local default_chars = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
		border_top_chars, border_mid_chars, border_bot_chars = split_border(default_chars)
	end

	local function setup_win(win)
		api.nvim_set_option_value(
			"winhighlight",
			"NormalFloat:" .. G.normal .. ",FloatBorder:" .. G.border,
			{ win = win }
		)
		api.nvim_set_option_value("scrolloff", 0, { win = win })
		api.nvim_set_option_value("wrap", false, { win = win })
	end

	-- HEADER -------------------------------------------------------

	local hbuf = api.nvim_create_buf(false, true)

	local hwin = api.nvim_open_win(hbuf, false, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = header_h,
		border = border_top_chars,
		style = "minimal",
		focusable = false,
		zindex = 10,
	})
	setup_win(hwin)

	local h_inner_w = api.nvim_win_get_width(hwin)

	for i, l in ipairs(header) do
		local padded = center(l, h_inner_w)
		api.nvim_buf_set_lines(hbuf, i - 1, i, false, { padded })

		local hl = nil
		if l == subject then
			hl = G.subject
		elseif title and l == title then
			hl = G.title
		elseif subtitle and l == subtitle then
			hl = G.sub_title
		end

		if hl then
			mark(hbuf, i - 1, hl, #padded)
		end
	end
	api.nvim_set_option_value("modifiable", false, { buf = hbuf })

	-- CONTENT ------------------------------------------------------

	local cbuf = api.nvim_create_buf(false, true)
	vim.bo[cbuf].filetype = "LvimDeps"

	local h_outer_h = api.nvim_win_get_height(hwin)

	local cwin = api.nvim_open_win(cbuf, true, {
		relative = "editor",
		row = row + h_outer_h,
		col = col,
		width = width,
		height = content_h,
		border = border_mid_chars,
		style = "minimal",
		focusable = true,
		zindex = 20,
	})
	setup_win(cwin)

	local c_inner_w = api.nvim_win_get_width(cwin)

	local cur = 0
	local active_id = nil

	-- Helper function to set active highlight (defined BEFORE if-else)
	local function set_active(r)
		if is_input then
			return -- No highlighting in input mode
		end
		local line = api.nvim_buf_get_lines(cbuf, r, r + 1, false)[1]
		if not line then
			return
		end
		active_id = api.nvim_buf_set_extmark(cbuf, NS, r, 0, {
			end_row = r,
			end_col = #line,
			hl_group = G.line_active,
			priority = 300,
		})
	end

	-- INPUT MODE
	if is_input then
		api.nvim_set_option_value("modifiable", true, { buf = cbuf })
		api.nvim_buf_set_lines(cbuf, 0, 1, false, { "" })

		-- Apply input highlight to the entire line (background)
		api.nvim_buf_set_extmark(cbuf, NS, 0, 0, {
			end_line = 0,
			line_hl_group = G.input,
			priority = 100,
		})

		-- MARK this buffer as input mode to show cursor
		local ok_cursor, cursor = pcall(require, "lvim-dependencies.ui.cursor")
		if ok_cursor and type(cursor.mark_input_buffer) == "function" then
			cursor.mark_input_buffer(cbuf, true)
		end

		-- Start in insert mode
		vim.schedule(function()
			vim.cmd("startinsert")
		end)
	else
		-- SELECTION MODE
		local has_line_inactive = G.line_inactive and vim.fn.hlexists(G.line_inactive) == 1

		for i, l in ipairs(content) do
			local padded = pad(l, c_inner_w)
			api.nvim_buf_set_lines(cbuf, i - 1, i, false, { padded })
			if has_line_inactive then
				mark(cbuf, i - 1, G.line_inactive, #padded)
			end
		end
		api.nvim_set_option_value("modifiable", false, { buf = cbuf })

		if default_index and type(default_index) == "number" then
			local idx = math.max(1, math.floor(default_index))
			if idx > #content then
				idx = #content
			end
			cur = math.max(0, idx - 1)
		end

		set_active(cur)
		api.nvim_win_set_cursor(cwin, { cur + 1, 0 })

		api.nvim_create_autocmd("CursorMoved", {
			buffer = cbuf,
			callback = function()
				local r = api.nvim_win_get_cursor(cwin)[1] - 1
				if r ~= cur then
					if active_id then
						pcall(api.nvim_buf_del_extmark, cbuf, NS, active_id)
					end
					cur = r
					set_active(cur)
				end
			end,
		})
	end

	-- FOOTER -------------------------------------------------------

	local fbuf = api.nvim_create_buf(false, true)

	local c_outer_h = api.nvim_win_get_height(cwin)

	local fwin = api.nvim_open_win(fbuf, false, {
		relative = "editor",
		row = row + h_outer_h + c_outer_h,
		col = col,
		width = width,
		height = footer_h,
		border = border_bot_chars,
		style = "minimal",
		focusable = false,
		zindex = 10,
	})
	setup_win(fwin)

	local f_inner_w = api.nvim_win_get_width(fwin)

	for i, l in ipairs(footer) do
		local padded = center(l, f_inner_w)
		api.nvim_buf_set_lines(fbuf, i - 1, i, false, { padded })
		if i == #footer and G.navigation then
			mark(fbuf, i - 1, G.navigation, #padded)
		end
	end
	api.nvim_set_option_value("modifiable", false, { buf = fbuf })

	-- KEYS ---------------------------------------------------------

	local function close(res, selected)
		if cb then
			vim.schedule(function()
				cb(res, selected)
			end)
		end
		pcall(api.nvim_win_close, hwin, true)
		pcall(api.nvim_win_close, cwin, true)
		pcall(api.nvim_win_close, fwin, true)
		pcall(api.nvim_buf_delete, hbuf, { force = true })
		pcall(api.nvim_buf_delete, cbuf, { force = true })
		pcall(api.nvim_buf_delete, fbuf, { force = true })
	end

	local opts_map = { buffer = cbuf, silent = true }

	if is_input then
		-- INPUT MODE KEYS
		vim.keymap.set("i", "<CR>", function()
			local lines = api.nvim_buf_get_lines(cbuf, 0, 1, false)
			local text = lines[1] or ""
			vim.cmd("stopinsert")
			close(true, text)
		end, opts_map)

		vim.keymap.set("i", "<Esc>", function()
			vim.cmd("stopinsert")
			close(false, nil)
		end, opts_map)

		vim.keymap.set("n", "<Esc>", function()
			close(false, nil)
		end, opts_map)
	else
		-- SELECTION MODE KEYS
		vim.keymap.set({ "n", "v" }, "h", "<nop>", opts_map)
		vim.keymap.set({ "n", "v" }, "l", "<nop>", opts_map)
		vim.keymap.set({ "n", "v" }, "<Left>", "<nop>", opts_map)
		vim.keymap.set({ "n", "v" }, "<Right>", "<nop>", opts_map)
		vim.keymap.set({ "n", "v" }, "0", "<nop>", opts_map)
		vim.keymap.set({ "n", "v" }, "^", "<nop>", opts_map)
		vim.keymap.set({ "n", "v" }, "$", "<nop>", opts_map)

		vim.keymap.set("n", "j", function()
			if cur < #content - 1 then
				if active_id then
					pcall(api.nvim_buf_del_extmark, cbuf, NS, active_id)
				end
				cur = cur + 1
				set_active(cur)
				api.nvim_win_set_cursor(cwin, { cur + 1, 0 })
			end
		end, opts_map)

		vim.keymap.set("n", "k", function()
			if cur > 0 then
				if active_id then
					pcall(api.nvim_buf_del_extmark, cbuf, NS, active_id)
				end
				cur = cur - 1
				set_active(cur)
				api.nvim_win_set_cursor(cwin, { cur + 1, 0 })
			end
		end, opts_map)

		vim.keymap.set("n", "y", function()
			close(true, cur + 1)
		end, opts_map)

		vim.keymap.set("n", "<CR>", function()
			close(true, cur + 1)
		end, opts_map)

		vim.keymap.set("n", "n", function()
			close(false, nil)
		end, opts_map)

		vim.keymap.set("n", "<Esc>", function()
			close(false, nil)
		end, opts_map)
	end
end

-- public ----------------------------------------------------------

-- Selection mode (existing)
function M.confirm_async(title, subtitle, subject, lines, cb, opts)
	local cfg = config.ui.floating
	opts = opts or {}
	opts.is_input = false
	local header, content, footer = build(title, subtitle, subject, lines, false)
	open(header, content, footer, cfg, title, subtitle, subject, cb, opts)
end

-- Input mode (new)
function M.input_async(title, subtitle, placeholder, cb)
	local cfg = config.ui.floating
	local opts = { is_input = true, placeholder = placeholder or "" }
	local header, content, footer = build(title, subtitle, nil, {}, true)
	open(header, content, footer, cfg, title, subtitle, nil, cb, opts)
end

return M
