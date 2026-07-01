-- lvim-dependencies.utils.notify: user-facing notification helper. Honours the config
-- enable flag and min-level threshold, then defers `vim.notify` through `vim.schedule`
-- (wrapped in pcall) so it is callable from fast-event context and a notifier error is
-- swallowed rather than propagated.
--
---@module "lvim-dependencies.utils.notify"

local config = require("lvim-dependencies.config")
local levels = require("lvim-dependencies.utils.levels")

--- Show notification message
---@param msg string Message to display
---@param level string|integer Log level (defaults to INFO if nil)
---@return nil
return function(msg, level)
    if not config.notify.enabled then
        return
    end

    if type(msg) ~= "string" or msg == "" then
        return
    end

    local min_level = config.notify.min_level or levels.INFO
    if not levels.should_show(level, min_level) then
        return
    end

    local level_num = levels.to_level_number(level)
    local options = {
        title = config.notify.title or "Lvim Dependencies",
        timeout = config.notify.timeout or 3000,
    }

    vim.schedule(function()
        pcall(vim.notify, msg, level_num, options)
    end)
end
