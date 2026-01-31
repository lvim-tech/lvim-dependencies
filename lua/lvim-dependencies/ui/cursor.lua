local api = vim.api

local M = {}

local POPUP_FILETYPES = { "LvimDeps" }
local _open_popups = {}
local _blend_augroup_id = api.nvim_create_augroup("LvimDepsPopupBlendGroup", { clear = true })

local function set_cursor_blend(value)
	pcall(function()
		vim.cmd("hi Cursor blend=" .. value)
	end)
end

local function is_popup_buffer(bufnr)
	if not bufnr or not api.nvim_buf_is_valid(bufnr) then
		return false
	end
	return vim.tbl_contains(POPUP_FILETYPES, vim.bo[bufnr].filetype)
end

local function update_cursor_state()
	local current_win = api.nvim_get_current_win()
	local current_buf = api.nvim_win_get_buf(current_win)

	if current_win == 0 then
		set_cursor_blend(0)
		return
	end

	if is_popup_buffer(current_buf) then
		set_cursor_blend(100)
	else
		if vim.tbl_count(_open_popups) > 0 then
			set_cursor_blend(100)
		else
			set_cursor_blend(0)
		end
	end
end

M.init = function()
	api.nvim_create_autocmd("WinEnter", {
		group = _blend_augroup_id,
		callback = function(
			---@param args { win: integer, buf: integer }
			args
		)
			local win = (args and args.win) or api.nvim_get_current_win()
			if not api.nvim_win_is_valid(win) then
				return
			end

			local bufnr = (args and args.buf) or api.nvim_win_get_buf(win)
			if not api.nvim_buf_is_valid(bufnr) then
				return
			end

			if is_popup_buffer(bufnr) then
				_open_popups[bufnr] = true
			end

			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd("WinLeave", {
		group = _blend_augroup_id,
		callback = function(
			---@param args { win: integer, buf: integer }
			args
		)
			local win = (args and args.win)
			if not win or not api.nvim_win_is_valid(win) then
				return
			end

			local bufnr = (args and args.buf) or api.nvim_win_get_buf(win)
			if not bufnr or not api.nvim_buf_is_valid(bufnr) then
				return
			end

			if is_popup_buffer(bufnr) then
				_open_popups[bufnr] = nil
			end

			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd("WinClosed", {
		group = _blend_augroup_id,
		callback = function()
			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
		group = _blend_augroup_id,
		callback = function(args)
			local bufnr = args.buf

			_open_popups[bufnr] = nil

			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd("CmdlineEnter", {
		group = _blend_augroup_id,
		callback = function()
			set_cursor_blend(0)
		end,
	})

	api.nvim_create_autocmd("CmdlineLeave", {
		group = _blend_augroup_id,
		callback = function()
			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
		pattern = table.concat(POPUP_FILETYPES, ","),
		callback = function()
			update_cursor_state()
		end,
	})
end

return M
