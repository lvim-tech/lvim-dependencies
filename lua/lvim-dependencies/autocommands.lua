local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local virtual_text = require("lvim-dependencies.ui.virtual_text")
local utils = require("lvim-dependencies.utils")

local package_parser = require("lvim-dependencies.parsers.package")
local cargo_parser = require("lvim-dependencies.parsers.cargo")
local pubspec_parser = require("lvim-dependencies.parsers.pubspec")
local composer_parser = require("lvim-dependencies.parsers.composer")
local go_parser = require("lvim-dependencies.parsers.go")

local checker = require("lvim-dependencies.actions.check_manifests")

-- require commands with pcall and capture both results
local ok_commands, commands = pcall(require, "lvim-dependencies.commands")
if not ok_commands then
	vim.schedule(function()
		utils.notify_safe(
			"LvimDeps: failed to require commands module: " .. tostring(commands),
			vim.log.levels.WARN,
			{}
		)
	end)
	commands = nil
end

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
	if not entry then
		return
	end
	if type(checker.check_manifest_outdated) == "function" then
		local ok, err = pcall(checker.check_manifest_outdated, bufnr, entry.key)
		if not ok then
			utils.notify_safe(
				("LvimDeps: check_manifest_outdated failed for %s: %s"):format(tostring(entry.key), tostring(err)),
				vim.log.levels.ERROR,
				{}
			)
		end
	else
		utils.notify_safe("LvimDeps: checker.check_manifest_outdated not found", vim.log.levels.DEBUG, {})
	end
end

local function handle_buffer_parse_and_check(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	if not entry then
		return
	end

	local manifest_key = entry.key
	if config[manifest_key] and config[manifest_key].enabled == false then
		return
	end

	if entry.parser and type(entry.parser.parse_buffer) == "function" then
		local ok, err = pcall(entry.parser.parse_buffer, bufnr)
		if not ok then
			utils.notify_safe(
				("LvimDeps: parser.parse_buffer failed for %s: %s"):format(tostring(filename), tostring(err)),
				vim.log.levels.ERROR,
				{}
			)
		end
	end

	call_manifest_checker(entry, bufnr)

	if virtual_text and type(virtual_text.display) == "function" then
		local ok, err = pcall(virtual_text.display, bufnr, manifest_key)
		if not ok then
			utils.notify_safe(
				("LvimDeps: virtual_text.display failed for %s: %s"):format(tostring(manifest_key), tostring(err)),
				vim.log.levels.ERROR,
				{}
			)
		end
	end

	if state.update_last_run and type(state.update_last_run) == "function" then
		local ok, err = pcall(state.update_last_run, bufnr)
		if not ok then
			utils.notify_safe(
				("LvimDeps: state.update_last_run failed: %s"):format(tostring(err)),
				vim.log.levels.DEBUG,
				{}
			)
		end
	end
end

local function schedule_handle(bufnr, delay)
	state.buffers = state.buffers or {}
	state.buffers[bufnr] = state.buffers[bufnr] or {}
	if state.buffers[bufnr].check_scheduled then
		return
	end
	state.buffers[bufnr].check_scheduled = true
	vim.defer_fn(function()
		state.buffers[bufnr].check_scheduled = false
		handle_buffer_parse_and_check(bufnr)
	end, delay)
end

local function on_buf_enter(args)
	local bufnr = args and args.buf or vim.api.nvim_get_current_buf()

	-- schedule parse/check for the buffer
	schedule_handle(bufnr, 50)

	-- create buffer-local commands if available; surface errors
	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	local manifest_key = entry and entry.key or nil

	if commands and type(commands.create_buf_commands_for) == "function" then
		local ok, err = pcall(commands.create_buf_commands_for, bufnr, manifest_key)
		if not ok then
			utils.notify_safe(
				("LvimDeps: create_buf_commands_for failed: %s"):format(tostring(err)),
				vim.log.levels.ERROR,
				{}
			)
		end
	end
end

local function on_buf_write(args)
	local bufnr = args and args.buf or vim.api.nvim_get_current_buf()
	schedule_handle(bufnr, 200)
end

M.init = function()
	local group = vim.api.nvim_create_augroup("LvimDependencies", { clear = true })

	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = { "package.json", "Cargo.toml", "pubspec.yaml", "pubspec.yml", "composer.json", "go.mod" },
		callback = on_buf_enter,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "package.json", "Cargo.toml", "pubspec.yaml", "pubspec.yml", "composer.json", "go.mod" },
		callback = on_buf_write,
	})
end

return M
