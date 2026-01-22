if vim.fn.has("nvim-0.10.0") == 0 then
	print("Lvim dependencies requires Neovim >= 0.10.0")
	return
end

-- Автоматично зареждане на plugin
if vim.g.loaded_lvim_dependencies then
	return
end
vim.g.loaded_lvim_dependencies = 1

-- Plugin ще бъде зареден чрез require("lvim-dependencies").setup()
