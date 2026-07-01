-- lvim-dependencies.lsp: entry point for the in-process LSP integration.
-- Wires up the hover/action submodules and auto-attaches the in-process client to every
-- manifest buffer (both those opened later and those already loaded at setup time).
--
---@module "lvim-dependencies.lsp"

local config = require("lvim-dependencies.config")
local server = require("lvim-dependencies.lsp.server")
local registry = require("lvim-dependencies.core.registry")
local utils = require("lvim-dependencies.utils")
local hover = require("lvim-dependencies.lsp.hover")
local action = require("lvim-dependencies.lsp.action")

local debug = utils.debug
local config_lsp = config.lsp

local M = {}

-- Submodules re-exported for callers of the lsp entry point.
M.hover = hover
M.action = action

--- Check if buffer is a manifest file
---@param bufnr integer
---@return boolean
local function is_manifest_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local filename = vim.api.nvim_buf_get_name(bufnr)
    if filename == "" then
        return false
    end

    return registry.is_manifest_file(filename)
end

--- Attach LSP client to buffer if not already attached
---@param bufnr integer
---@return boolean
local function attach_lsp_to_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        debug(string.format("Buffer %d is invalid, cannot attach LSP", bufnr), vim.log.levels.WARN)
        return false
    end

    -- Check if buffer already has LSP client
    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    for _, client in ipairs(clients) do
        if client.name == "lvim-dependencies" then
            debug(string.format("LSP client already attached to buffer %d", bufnr), vim.log.levels.DEBUG)
            return true
        end
    end

    debug(string.format("Starting LSP server for buffer %d", bufnr), vim.log.levels.DEBUG)
    local client_id = server.start()

    if client_id then
        local ok = pcall(vim.lsp.buf_attach_client, bufnr, client_id)
        if ok then
            debug(string.format("LSP client attached to buffer %d", bufnr), vim.log.levels.INFO)
            return true
        else
            debug(string.format("Failed to attach LSP client to buffer %d", bufnr), vim.log.levels.ERROR)
        end
    else
        debug("Failed to start LSP server", vim.log.levels.ERROR)
    end

    return false
end

--- Setup LSP integration
function M.setup()
    if not config_lsp.enabled then
        debug("LSP integration is disabled in config", vim.log.levels.DEBUG)
        return
    end

    debug("Setting up LSP integration", vim.log.levels.INFO)

    -- Setup hover and action modules
    hover.setup()
    action.setup()

    -- Auto-attach LSP to manifest files when opened
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
        group = vim.api.nvim_create_augroup("lvim-deps-lsp", { clear = true }),
        callback = function(args)
            if is_manifest_buffer(args.buf) then
                debug(
                    string.format("Manifest file detected: %s", vim.api.nvim_buf_get_name(args.buf)),
                    vim.log.levels.DEBUG
                )
                attach_lsp_to_buffer(args.buf)
            end
        end,
    })

    -- Also check existing buffers
    vim.schedule(function()
        debug("Checking existing buffers for LSP attachment", vim.log.levels.DEBUG)
        local attached_count = 0

        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr) and is_manifest_buffer(bufnr) then
                if attach_lsp_to_buffer(bufnr) then
                    attached_count = attached_count + 1
                end
            end
        end

        if attached_count > 0 then
            debug(string.format("LSP attached to %d existing manifest buffers", attached_count), vim.log.levels.INFO)
        end
    end)

    debug("LSP integration setup complete", vim.log.levels.DEBUG)
end

return M
