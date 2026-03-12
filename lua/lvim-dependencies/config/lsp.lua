local border = {
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
    { " ", "FloatBorder" },
}
return {
    enabled = true,
    on_attach = function(_, bufnr)
        vim.keymap.set("n", "K", function()
            vim.lsp.buf.hover({ border = border })
        end, { buffer = bufnr, desc = "Lvim Dependencies: Show hover" })

        vim.keymap.set("n", "ga", function()
            vim.lsp.buf.code_action({ border = border })
        end, { buffer = bufnr, desc = "Lvim Dependencies: Code actions" })
    end,
    actions = true,
    hover = true,
}
