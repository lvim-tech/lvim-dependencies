local config = require("lvim-dependencies.config")
local state = require("lvim-dependencies.state")
local virtual_text = require("lvim-dependencies.ui.virtual_text")

local package_parser = require("lvim-dependencies.parsers.package")
local cargo_parser = require("lvim-dependencies.parsers.cargo")
local pubspec_parser = require("lvim-dependencies.parsers.pubspec")

local ok_pkg_checker, pkg_checker = pcall(require, "lvim-dependencies.actions.check_outdated")
local ok_crates_checker, crates_checker = pcall(require, "lvim-dependencies.actions.check_crates_outdated")
local ok_pub_checker, pub_checker = pcall(require, "lvim-dependencies.actions.check_pub_outdated")

local M = {}

local parsers = {
	["package.json"] = {
		parser = package_parser,
		key = "package",
		checker = ok_pkg_checker and pkg_checker or nil,
		checker_fn = "check_outdated",
	},
	["Cargo.toml"] = {
		parser = cargo_parser,
		key = "crates",
		checker = ok_crates_checker and crates_checker or nil,
		checker_fn = "check_crates_outdated",
	},
	["pubspec.yaml"] = {
		parser = pubspec_parser,
		key = "pubspec",
		checker = ok_pub_checker and pub_checker or nil,
		checker_fn = "check_pub_outdated",
	},
}

local function call_manifest_checker(entry, bufnr)
	if not entry or not entry.checker then
		return
	end
	local fn_name = entry.checker_fn
	if not fn_name then
		return
	end
	local fn = entry.checker[fn_name]
	if type(fn) == "function" then
		pcall(fn, bufnr)
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
		if state.update_last_run then
			state.update_last_run(bufnr)
		end
	end)
end

local function on_buf_enter(args)
	local bufnr = args and args.buf or vim.api.nvim_get_current_buf()
	handle_buffer_parse_and_check(bufnr)
end

local function on_buf_write(args)
	local bufnr = args and args.buf or vim.api.nvim_get_current_buf()

	vim.defer_fn(function()
		handle_buffer_parse_and_check(bufnr)
	end, 50)
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
