local api = vim.api
local fn = vim.fn
local defer_fn = vim.defer_fn

local config = require("lvim-dependencies.config")
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

local parsers = {
	["package.json"] = { parser = package_parser, key = "package" },
	["Cargo.toml"] = { parser = cargo_parser, key = "crates" },
	["pubspec.yaml"] = { parser = pubspec_parser, key = "pubspec" },
	["pubspec.yml"] = { parser = pubspec_parser, key = "pubspec" },
	["composer.json"] = { parser = composer_parser, key = "composer" },
	["go.mod"] = { parser = go_parser, key = "go" },
}

local function call_manifest_checker(entry, bufnr)
	checker.check_manifest_outdated(bufnr, entry.key)
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

local function schedule_handle(bufnr, delay)
	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}
	if state.buffers[bufnr].check_scheduled then
		return
	end
	state.buffers[bufnr].check_scheduled = true
	defer_fn(function()
		state.buffers[bufnr].check_scheduled = false
		handle_buffer_parse_and_check(bufnr)
	end, delay)
end

local function on_buf_enter(args)
	local bufnr = (args and args.buf) or api.nvim_get_current_buf()

	schedule_handle(bufnr, 50)

	local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	local manifest_key = entry and entry.key or nil

	commands.create_buf_commands_for(bufnr, manifest_key)
end

local function on_buf_write(args)
	local bufnr = (args and args.buf) or api.nvim_get_current_buf()
	schedule_handle(bufnr, 200)
end

M.init = function()
	local group = api.nvim_create_augroup("LvimDependencies", { clear = true })

	local patterns = { "package.json", "Cargo.toml", "pubspec.yaml", "pubspec.yml", "composer.json", "go.mod" }

	api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
		group = group,
		pattern = patterns,
		callback = on_buf_enter,
	})

	api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = patterns,
		callback = on_buf_write,
	})
end

return M
