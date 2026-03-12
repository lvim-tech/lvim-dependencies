-- lvim-dependencies/hooks/autocommands.lua
-- Autocommands for buffer events

local api = vim.api
local state = require("lvim-dependencies.core.state")
local debug = require("lvim-dependencies.utils").debug

local M = {}

--- Autocommand group name
local GROUP_NAME = "LvimDepsState"

--- Map of autocommand events to the state event names they trigger
---@type {events: string|string[], state_event: string, handler?: fun(args: table)}[]
local AUTOCMD_DEFS = {
    {
        events = { "TextChanged", "TextChangedI" },
        state_event = "",
        handler = function(args)
            state.handle_buffer_change(args.buf)
        end,
    },
    {
        events = { "BufRead", "BufNewFile" },
        state_event = "opened",
    },
    {
        events = "BufWritePost",
        state_event = "saved",
    },
    {
        events = "BufLeave",
        state_event = "",
        handler = function(args)
            local bufnr = args.buf
            local wins = vim.fn.win_findbuf(bufnr)

            if #wins == 0 then
                state.handle_buffer_event(bufnr, "closed")
            else
                debug(string.format("Buffer %d lost focus but still visible", bufnr), vim.log.levels.DEBUG)
            end
        end,
    },
    {
        events = "BufEnter",
        state_event = "entered",
    },
    {
        events = "FileType",
        state_event = "filetype_changed",
    },
}

function M.setup()
    local group = api.nvim_create_augroup(GROUP_NAME, { clear = true })

    for _, def in ipairs(AUTOCMD_DEFS) do
        local callback
        if def.handler then
            callback = def.handler
        else
            local event_name = def.state_event
            callback = function(args)
                state.handle_buffer_event(args.buf, event_name)
            end
        end

        api.nvim_create_autocmd(def.events, {
            group = group,
            pattern = "*",
            callback = callback,
        })
    end

    debug("Autocommands setup complete", vim.log.levels.DEBUG)
end

return M
