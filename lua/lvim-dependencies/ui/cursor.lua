local api = vim.api
local schedule = vim.schedule

local M = {}

local POPUP_FILETYPES = { "LvimDeps" }
local _blend_augroup_id = api.nvim_create_augroup("LvimDepsPopupBlendGroup", { clear = true })

local function get_cursor_hl()
	-- prefer new API nvim_get_hl when available
	if type(api.nvim_get_hl) == "function" then
		local ok, hl = pcall(api.nvim_get_hl, 0, { name = "Cursor" })
		if ok and type(hl) == "table" then
			-- return raw table, we will access keys safely via string indexing
			return hl
		end
	end
	return nil
end

local function set_cursor_blend(value)
	-- schedule on main loop; protect with pcall
	schedule(function()
		pcall(function()
			local cur = get_cursor_hl()
			-- only set blend if nvim_set_hl is available
			if type(api.nvim_set_hl) == "function" and type(cur) == "table" then
				local hl = {}
				-- preserve colors/attrs if present (access via string-keys to avoid LSP warnings)
				local fg = cur["foreground"] or cur["fg"]
				local bg = cur["background"] or cur["bg"]
				local sp = cur["special"] or cur["sp"]

				if fg ~= nil then
					hl.fg = fg
				end
				if bg ~= nil then
					hl.bg = bg
				end
				if sp ~= nil then
					hl.sp = sp
				end

				local bold = cur["bold"]
				local underline = cur["underline"]
				local undercurl = cur["undercurl"]
				local italic = cur["italic"]

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

				pcall(api.nvim_set_hl, 0, "Cursor", hl)
			end
		end)
	end)
end

local function is_popup_buffer(bufnr)
	if not bufnr or not api.nvim_buf_is_valid(bufnr) then
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

local function any_window_has_popup()
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_is_valid(win) then
			local ok, b = pcall(api.nvim_win_get_buf, win)
			if ok and b and is_popup_buffer(b) then
				return true
			end
		end
	end
	return false
end

local function update_cursor_state()
	local ok_win, cur_win = pcall(api.nvim_get_current_win)
	if not ok_win or not cur_win or not api.nvim_win_is_valid(cur_win) then
		set_cursor_blend(0)
		return
	end

	local ok_buf, cur_buf = pcall(api.nvim_win_get_buf, cur_win)
	if not ok_buf or not cur_buf or not api.nvim_buf_is_valid(cur_buf) then
		set_cursor_blend(0)
		return
	end

	if is_popup_buffer(cur_buf) then
		set_cursor_blend(100)
		return
	end

	if any_window_has_popup() then
		set_cursor_blend(100)
	else
		set_cursor_blend(0)
	end
end

function M.init()
	api.nvim_create_autocmd({ "WinEnter", "WinLeave", "WinClosed" }, {
		group = _blend_augroup_id,
		callback = function(_)
			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
		group = _blend_augroup_id,
		callback = function(_)
			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd("CmdlineEnter", {
		group = _blend_augroup_id,
		callback = function(_)
			set_cursor_blend(0)
		end,
	})
	api.nvim_create_autocmd("CmdlineLeave", {
		group = _blend_augroup_id,
		callback = function(_)
			update_cursor_state()
		end,
	})

	api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
		group = _blend_augroup_id,
		callback = function(_)
			update_cursor_state()
		end,
	})
end

return M
