-- lvim-dependencies.config.lsp: config for the plugin's lightweight LSP integration. The
-- blank-space border (all cells " " on FloatBorder) gives hover/code-action floats a padded,
-- ringless frame that matches the rest of the plugin's chrome; on_attach wires K / ga.
---@module "lvim-dependencies.config.lsp"

-- Eight-cell border spec (all blank cells) for hover / code-action floats: a padded frame
-- without a visible ring, consistent with the plugin's other windows.
---@type string[][]
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

---@class LvimDependenciesLspConfig
return {
    enabled = true,
    --- Buffer-local LSP keymaps for a dependency manifest buffer.
    ---@param _ vim.lsp.Client The attaching client (unused)
    ---@param bufnr integer Buffer the client attached to
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
    --- Enable the buffer omnifunc (v:lua.vim.lsp.omnifunc) on attach. Off by default:
    --- the in-process server advertises no completionProvider, so nothing feeds it yet.
    completion = false,
}
