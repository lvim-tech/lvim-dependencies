-- lvim-dependencies.core.events: a tiny synchronous pub/sub bus. Handlers per event are
-- kept in insertion order and invoked under pcall so one throwing handler can't abort the
-- rest of the emit; off() walks back-to-front so removal during dispatch is safe.
--
---@module "lvim-dependencies.core.events"

-- LuaJIT compatibility: table.unpack may not be available
local _unpack = table.unpack or unpack
local notify = require("lvim-dependencies.utils.notify")

---@type table<string, EventHandler[]>
local handlers = {}

local M = {}

--- Register an event handler
---@param event PreDefinedEvents|string The event name to listen for
---@param handler EventHandler Function to call when event is emitted
function M.on(event, handler)
    local event_handlers = handlers[event]
    if not event_handlers then
        event_handlers = {}
        handlers[event] = event_handlers
    end
    event_handlers[#event_handlers + 1] = handler
end

--- Emit an event
---@param event PreDefinedEvents|string The event name to emit
---@param ... any Arguments to pass to event handlers
function M.emit(event, ...)
    local event_handlers = handlers[event]
    if not event_handlers then
        return
    end
    local args = { ... }
    for i = 1, #event_handlers do
        local ok, err = pcall(event_handlers[i], _unpack(args, 1, select("#", ...)))
        if not ok then
            notify(string.format("Event handler error for %s: %s", event, err), vim.log.levels.ERROR)
        end
    end
end

--- Remove a specific handler from an event
---@param event PreDefinedEvents|string The event name
---@param handler EventHandler The handler to remove
---@return boolean success True if handler was found and removed
function M.off(event, handler)
    local event_handlers = handlers[event]
    if not event_handlers then
        return false
    end
    for i = #event_handlers, 1, -1 do
        if event_handlers[i] == handler then
            table.remove(event_handlers, i)
            return true
        end
    end
    return false
end

--- Clear all handlers for an event
---@param event PreDefinedEvents|string The event name to clear handlers for
function M.clear(event)
    handlers[event] = nil
end

--- Clear all handlers for all events
function M.clear_all()
    handlers = {}
end

--- Get all registered events
---@return string[]
function M.list_events()
    local keys = {}
    for event in pairs(handlers) do
        keys[#keys + 1] = event
    end
    return keys
end

--- Get handler count for an event
---@param event PreDefinedEvents|string
---@return integer
function M.handler_count(event)
    local event_handlers = handlers[event]
    return event_handlers and #event_handlers or 0
end

--- Check if an event has any handlers
---@param event PreDefinedEvents|string
---@return boolean
function M.has_handlers(event)
    local event_handlers = handlers[event]
    return event_handlers ~= nil and #event_handlers > 0
end

--- Emit event once and then remove handler
---@param event PreDefinedEvents|string
---@param handler EventHandler
function M.once(event, handler)
    local once_handler
    once_handler = function(...)
        M.off(event, once_handler)
        handler(...)
    end
    M.on(event, once_handler)
end

return M
