local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")
local virtual_text = require("lvim-dependencies.ui.virtual_text")

local M = {}

M.parse = function(content)
	local dependencies = {}
	local in_dependencies_section = false

	for line in content:gmatch("[^\r\n]+") do
		if line:match("^%[dependencies%]") then
			in_dependencies_section = true
		elseif line:match("^%[") then
			in_dependencies_section = false
		elseif in_dependencies_section then
			local name, version = line:match('^([%w_%-]+)%s*=%s*"([^"]+)"')
			if name and version then
				table.insert(dependencies, {
					name = name,
					version = version,
					type = "dependency",
				})
			end

			name, version = line:match('^([%w_%-]+)%s*=%s*{.-version%s*=%s*"([^"]+)"')
			if name and version then
				table.insert(dependencies, {
					name = name,
					version = version,
					type = "dependency",
				})
			end
		end
	end

	return dependencies
end

M.find_dependency_at_line = function(bufnr, line_num)
	local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
	if #lines == 0 then
		return nil
	end

	local line = lines[1]

	local name, version = line:match('^([%w_%-]+)%s*=%s*"([^"]+)"')
	if name and version then
		return { name = name, version = version }
	end

	name, version = line:match('^([%w_%-]+)%s*=%s*{.-version%s*=%s*"([^"]+)"')
	if name and version then
		return { name = name, version = version }
	end

	return nil
end

M.attach = function(bufnr)
	local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local dependencies = M.parse(content)

	if dependencies and config.virtual_text.enabled then
		virtual_text.show(bufnr, dependencies, "crates")
	end

	M.setup_keymaps(bufnr)
end

M.setup_keymaps = function(bufnr)
	local opts = { buffer = bufnr, silent = true }

	vim.keymap.set("n", config.keymaps.show_info, function()
		local line_num = vim.api.nvim_win_get_cursor(0)[1]
		local dep = M.find_dependency_at_line(bufnr, line_num)

		if dep then
			utils.notify(string.format("%s %s: %s", config.crates.icon, dep.name, dep.version))
		end
	end, opts)
end

return M
