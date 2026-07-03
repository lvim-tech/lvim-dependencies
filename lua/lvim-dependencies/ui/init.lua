-- lvim-dependencies.ui: an independent lvim-utils.ui instance for lvim-dependencies.
-- The instance is created lazily and cached on first use, so its geometry/icons are read
-- from lvim-dependencies.config.ui.popup only once the config has been merged. lvim-utils
-- is required inline (cross-plugin dependency) to avoid a load-order requirement.
--
---@module "lvim-dependencies.ui"

local M = {}

---@type table? cached lvim-utils.ui instance (nil until first ui() call)
local _instance = nil

--- Lazily build and cache the plugin's private ui instance from config.ui.popup.
---@return table instance
local function ui()
    if _instance then
        return _instance
    end
    local popup = require("lvim-dependencies.config").ui.popup
    -- max_height / close_keys / position come from the SHARED lvim-utils `config.ui` (the presenters read them),
    -- so we only forward lvim-dependencies-specific values: the list-row cap and the active-item marker.
    _instance = require("lvim-utils").ui.new({
        max_items = popup.max_items,
        icons = { current = popup.current },
    })
    return _instance
end

--- The shared global lvim-utils.ui (used for info floats, not the private select instance).
---@return table
local function global_ui()
    return require("lvim-utils").ui
end

-- ── Info / float ──────────────────────────────────────────────────────────────

---@param content string|string[]
---@param title? string
---@return integer buf, integer win
function M.open(content, title)
    local opts = {
        close_keys = { "q", "<ESC>" },
        filetype = "LvimDepsInfo",
        markview = true,
    }
    if title then
        opts.title = title
    end
    return global_ui().info(content, opts)
end

---@param win integer
function M.close(win)
    global_ui().close_info(win)
end

-- ── Select ────────────────────────────────────────────────────────────────────

---@param title string|nil
---@param subtitle string|nil
---@param subject string|nil
---@param items any[]
---@param callback fun(confirmed: boolean, result: any)
---@param opts? {default_index?: integer, current_item?: string}
function M.select(title, subtitle, subject, items, callback, opts)
    opts = opts or {}
    local current_item = opts.current_item
    if not current_item and opts.default_index and items and items[opts.default_index] then
        current_item = items[opts.default_index]
    end
    ui().select({
        title = title,
        subtitle = subtitle,
        info = subject,
        items = items or {},
        current_item = current_item,
        callback = callback,
    })
end

-- ── Multiselect ───────────────────────────────────────────────────────────────

---@param title string|nil
---@param subtitle string|nil
---@param subject string|nil
---@param items any[]
---@param callback fun(confirmed: boolean, result: any)
---@param opts? {initial_selected?: table<string, boolean>}
function M.multiselect(title, subtitle, subject, items, callback, opts)
    opts = opts or {}
    ui().multiselect({
        title = title,
        subtitle = subtitle,
        info = subject,
        items = items or {},
        initial_selected = opts.initial_selected,
        callback = callback,
    })
end

-- ── Input ─────────────────────────────────────────────────────────────────────

---@param title string|nil
---@param subtitle string|nil
---@param placeholder string|nil
---@param callback fun(confirmed: boolean, result: any)
function M.input(title, subtitle, placeholder, callback)
    ui().input({
        title = title,
        subtitle = subtitle,
        placeholder = placeholder or "",
        callback = callback,
    })
end

-- ── Aliases ───────────────────────────────────────────────────────────────────

M.confirm_async = M.select
M.multiselect_async = M.multiselect
M.input_async = M.input

return M
