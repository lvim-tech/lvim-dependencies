local utils_file_system = require("lvim-dependencies.utils.file_system")

return {
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
