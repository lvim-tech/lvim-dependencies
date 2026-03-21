-- UI — independent lvim-utils.ui instance for lvim-dependencies.
-- Config is sourced exclusively from lvim-dependencies.config.ui.popup.

local M = {}

local _instance = nil

local function ui()
    if _instance then
        return _instance
    end
    local popup = require("lvim-dependencies.config").ui.popup
    _instance = require("lvim-utils").ui.new({
        border = popup.border,
        max_items = popup.max_items,
        max_height = popup.max_height,
        icons = { current = popup.current },
    })
    return _instance
end

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
