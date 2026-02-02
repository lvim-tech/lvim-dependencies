local api = vim.api
local fn = vim.fn
local defer_fn = vim.defer_fn

local config = require("lvim-dependencies.config")
local const = require("lvim-dependencies.const")
local state = require("lvim-dependencies.state")
local virtual_text = require("lvim-dependencies.ui.virtual_text")

local package_parser = require("lvim-dependencies.parsers.package")
local cargo_parser = require("lvim-dependencies.parsers.cargo")
local pubspec_parser = require("lvim-dependencies.parsers.pubspec")
local composer_parser = require("lvim-dependencies.parsers.composer")
local go_parser = require("lvim-dependencies.parsers.go")

local checker = require("lvim-dependencies.actions.check_manifests")
local commands = require("lvim-dependencies.commands")

local M = {}

-- Build parsers map from const
local parsers = {}
for filename, key in pairs(const.MANIFEST_KEYS) do
	local parser_map = {
		package = package_parser,
		crates = cargo_parser,
		pubspec = pubspec_parser,
		composer = composer_parser,
		go = go_parser,
	}
	parsers[filename] = { parser = parser_map[key], key = key }
end

local function call_manifest_checker(entry, bufnr)
	pcall(function()
		checker.check_manifest_outdated(bufnr, entry.key)
	end)
end

local function parse_and_render(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
		return
	end

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	if not entry then
		return
	end

	local manifest_key = entry.key
	if config[manifest_key] and config[manifest_key].enabled == false then
		return
	end

	entry.parser.parse_buffer(bufnr)
	virtual_text.display(bufnr, manifest_key)
	state.update_last_run(bufnr)
end

local function handle_buffer_parse_and_check(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
		return
	end

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	if not entry then
		return
	end

	local manifest_key = entry.key
	if config[manifest_key] and config[manifest_key].enabled == false then
		return
	end

	entry.parser.parse_buffer(bufnr)
	call_manifest_checker(entry, bufnr)
	virtual_text.display(bufnr, manifest_key)
	state.update_last_run(bufnr)
end

local function schedule_handle(bufnr, delay, full_check)
	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}
	if state.buffers[bufnr].check_scheduled then
		return
	end
	state.buffers[bufnr].check_scheduled = true
	defer_fn(function()
		state.buffers[bufnr].check_scheduled = false
		if full_check then
			handle_buffer_parse_and_check(bufnr)
		else
			parse_and_render(bufnr)
		end
	end, delay)
end

-- Light UI refresh: ONLY re-render virtual text for visible range.
-- No parsing, no network.
local function schedule_light_render(bufnr, delay)
	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}

	if state.buffers[bufnr].light_render_scheduled then
		return
	end

	state.buffers[bufnr].light_render_scheduled = true
	defer_fn(function()
		state.buffers[bufnr].light_render_scheduled = false

		if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
			return
		end

		local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
		local entry = parsers[filename]
		if not entry then
			return
		end

		local manifest_key = entry.key
		if config[manifest_key] and config[manifest_key].enabled == false then
			return
		end

		virtual_text.display(bufnr, manifest_key)
	end, delay or 25)
end

local function on_buf_enter(args)
	local bufnr = (args and args.buf) or api.nvim_get_current_buf()

	-- Full parse+check on enter (debounced)
	schedule_handle(bufnr, 50, true)

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	local manifest_key = entry and entry.key or nil

	commands.create_buf_commands_for(bufnr, manifest_key)
end

local function on_buf_write(args)
	local bufnr = (args and args.buf) or api.nvim_get_current_buf()
	-- Parse+render (no check) after write (debounced)
	schedule_handle(bufnr, 200, false)
end

-- When scrolling, just re-render visible range (fast path).
local function on_win_scrolled(args)
	local bufnr = (args and args.buf) or api.nvim_get_current_buf()
	schedule_light_render(bufnr, 20)
end

-- When cursor holds (idle), re-render visible range (covers cases where w0/w$ changes without WinScrolled)
local function on_cursor_hold(args)
	local bufnr = (args and args.buf) or api.nvim_get_current_buf()
	schedule_light_render(bufnr, 40)
end

M.init = function()
	local group = api.nvim_create_augroup("LvimDependencies", { clear = true })

	api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
		group = group,
		pattern = const.MANIFEST_PATTERNS,
		callback = on_buf_enter,
	})

	api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = const.MANIFEST_PATTERNS,
		callback = on_buf_write,
	})

	-- Light-weight UI refresh hooks (NO parse/check)
	api.nvim_create_autocmd({ "WinScrolled" }, {
		group = group,
		pattern = const.MANIFEST_PATTERNS,
		callback = on_win_scrolled,
	})

	api.nvim_create_autocmd({ "CursorHold" }, {
		group = group,
		pattern = const.MANIFEST_PATTERNS,
		callback = on_cursor_hold,
	})
end

return M
