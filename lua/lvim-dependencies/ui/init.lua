-- UI — thin wrappers over lvim-utils.ui
-- Config is applied once via require("lvim-utils").setup() in plugin init.

local M = {}

local function ui()
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
    return ui().info(content, opts)
end

---@param win integer
function M.close(win)
    ui().close_info(win)
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
