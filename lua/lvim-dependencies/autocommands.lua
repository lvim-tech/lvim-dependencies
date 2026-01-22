local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local virtual_text = require("lvim-dependencies.ui.virtual_text")

local package_parser = require("lvim-dependencies.parsers.package")
local cargo_parser = require("lvim-dependencies.parsers.cargo")
local pubspec_parser = require("lvim-dependencies.parsers.pubspec")

local ok_checker, checker = pcall(require, "lvim-dependencies.actions.check_manifests")

local M = {}

local parsers = {
	["package.json"] = { parser = package_parser, key = "package" },
	["Cargo.toml"] = { parser = cargo_parser, key = "crates" },
	["pubspec.yaml"] = { parser = pubspec_parser, key = "pubspec" },
}

local function call_manifest_checker(entry, bufnr)
	if not entry then return end
	if ok_checker and checker and type(checker.check_manifest_outdated) == "function" then
		pcall(checker.check_manifest_outdated, bufnr, entry.key)
		return
	end
	-- legacy fallback omitted (we rely on unified checker)
end

local function handle_buffer_parse_and_check(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then return end

	local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
	local entry = parsers[filename]
	if not entry then return end

	local manifest_key = entry.key
	if config[manifest_key] and config[manifest_key].enabled == false then return end

	pcall(function()
		if entry.parser and type(entry.parser.parse_buffer) == "function" then
			entry.parser.parse_buffer(bufnr)
		elseif entry.parser and type(entry.parser.attach) == "function" then
			entry.parser.attach(bufnr)
		end
	end)

	pcall(function()
		call_manifest_checker(entry, bufnr)
	end)

	pcall(function()
		virtual_text.display(bufnr, manifest_key)
	end)

	pcall(function()
		if state.update_last_run then state.update_last_run(bufnr) end
	end)
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
	schedule_handle(bufnr, 50)
end

local function on_buf_write(args)
	local bufnr = args and args.buf or vim.api.nvim_get_current_buf()
	schedule_handle(bufnr, 200)
end

M.init = function()
	local group = vim.api.nvim_create_augroup("LvimDependencies", { clear = true })

	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = { "package.json", "Cargo.toml", "pubspec.yaml" },
		callback = on_buf_enter,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "package.json", "Cargo.toml", "pubspec.yaml" },
		callback = on_buf_write,
	})
end

return M
