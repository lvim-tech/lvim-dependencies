-- lvim-dependencies/lsp/server.lua
-- In-process LSP server implementation

local hover = require("lvim-dependencies.lsp.hover")
local action = require("lvim-dependencies.lsp.action")
local utils = require("lvim-dependencies.utils")
local config = require("lvim-dependencies.config")
local registry = require("lvim-dependencies.core.registry")

local debug = utils.debug
local config_lsp = config.lsp

local SERVER_NAME = "lvim-deps"
local SERVER_VER = "1.0.0"

local M = {}

M.client_id = nil

-- LSP server capabilities
function M.get_capabilities()
    return {
        textDocumentSync = 1,
        hoverProvider = config_lsp.hover,
        codeActionProvider = config_lsp.actions,
    }
end

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

-- In-process command function
function M.cmd(dispatchers)
    return {
        request = function(method, params, callback)
            debug(string.format("LSP request: %s", method), vim.log.levels.DEBUG)

            if method == "initialize" then
                callback(nil, {
                    capabilities = M.get_capabilities(),
                    serverInfo = {
                        name = SERVER_NAME,
                        version = SERVER_VER,
                    },
                })
            elseif method == "shutdown" then
                callback(nil, nil)
            elseif method == "textDocument/hover" then
                local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
                local result = hover.handle(params, bufnr)
                callback(nil, result)
            elseif method == "textDocument/codeAction" then
                -- Call action.handle with params and a callback; action.handle derives bufnr internally.
                action.handle(params, function(err, actions)
                    callback(err, actions)
                end)
            else
                callback(nil, nil)
            end
            return true
        end,

        notify = function(method, _)
            debug(string.format("LSP notify: %s", method), vim.log.levels.DEBUG)
            if method == "exit" then
                dispatchers.on_exit(0, 15)
            end
            return true
        end,

        is_closing = function()
            return false
        end,

        terminate = function() end,
    }
end

-- Start LSP server
function M.start()
    if M.client_id then
        local client = vim.lsp.get_client_by_id(M.client_id)
        if client and not client:is_stopped() then
            return M.client_id
        end
    end

    -- Empty filetypes list means LSP will start for all files
    -- We filter using is_manifest_buffer in on_attach
    local filetypes = {}

    M.client_id = vim.lsp.start({
        name = SERVER_NAME,
        cmd = M.cmd,
        filetypes = filetypes,
        root_dir = vim.fs.root(0, { ".git" }) or vim.fn.getcwd(),
        on_attach = function(client, bufnr)
            if not is_manifest_buffer(bufnr) then
                -- Detach if not a manifest file
                vim.lsp.buf_detach_client(bufnr, client.id)
                debug(string.format("Detached LSP from non-manifest buffer %d", bufnr), vim.log.levels.DEBUG)
                return
            end

            debug(string.format("LSP attached to manifest buffer %d", bufnr), vim.log.levels.INFO)

            -- Call user's on_attach if provided
            if config_lsp.on_attach then
                config_lsp.on_attach(client, bufnr)
            end

            -- Enable omnifunc for completion
            if config_lsp.completion then
                vim.api.nvim_buf_set_option(bufnr, "omnifunc", "v:lua.vim.lsp.omnifunc")
            end
        end,
    })

    if M.client_id then
        debug(string.format("LSP server started with client ID: %d", M.client_id), vim.log.levels.INFO)
    else
        debug("Failed to start LSP server", vim.log.levels.ERROR)
    end

    return M.client_id
end

-- Stop LSP server
function M.stop()
    if M.client_id then
        vim.lsp.stop_client(M.client_id)
        M.client_id = nil
        debug("LSP server stopped", vim.log.levels.INFO)
    end
end

-- Check if server is running
function M.is_running()
    return M.client_id
        and vim.lsp.get_client_by_id(M.client_id)
        and not vim.lsp.get_client_by_id(M.client_id):is_stopped()
end

return M
