-- lvim-dependencies.config.message: settings for the messaging subsystem — user-facing
-- notifications, the on-disk debug log, and metrics collection. The debug log path is
-- resolved through the shared state dir so it lands next to the plugin's other state.
---@module "lvim-dependencies.config.message"

local utils_file_system = require("lvim-dependencies.utils.file_system")

---@class LvimDependenciesMessageConfig
return {
    notify = {
        enabled = true,
        min_level = vim.log.levels.INFO,
        title = "Lvim Dependencies",
        timeout = 10000,
    },
    debug = {
        enabled = false,
        min_level = vim.log.levels.DEBUG,
        file = utils_file_system.get_state_file("debug.log"),
    },
    metrics = {
        enabled = true,
        max_examples = 3,
        max_top_messages = 5,
        max_slowest_packages = 5,
        default_refresh_interval = 2, -- seconds
        auto_save_interval = 3600000, -- 1 hour in ms
    },
}
