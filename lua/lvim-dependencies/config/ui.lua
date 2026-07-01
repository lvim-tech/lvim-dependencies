-- lvim-dependencies.config.ui: presentation settings for the two surfaces the plugin draws —
-- inline virtual text (position, per-buffer status file, glyphs) and the version popup
-- (geometry, current-item pointer). The status file persists the virtual-text toggle state.
---@module "lvim-dependencies.config.ui"

local utils_file_system = require("lvim-dependencies.utils.file_system")

---@class LvimDependenciesUiConfig
return {
    --- Bounds (ms) for the randomized delay before initial virtual-text appears, so
    --- packages fade in staggered rather than all at once on the first render.
    visual_delay_min = 100,
    visual_delay_max = 900,
    virtual_text = {
        --- Position of virtual text relative to the line (default: "eol")
        --- Valid values: "eol", "overlay", "right_align", "inline"
        position = nil,
        status = {
            enabled = { default = true },
            file = utils_file_system.get_state_file("vt"),
        },
        icons = {
            separators = {
                prefix = "➤➤➤",
                transition = "→",
                divider = "|",
            },
            up_to_date = "",
            outdated = "",
            loading = "Loading...",
            working = "Working... ",
            error = "?",
        },
    },
    popup = {
        width = "auto",
        height = "auto",
        max_height = 0.8,
        current = "➤",
        max_items = 20,
    },
}
