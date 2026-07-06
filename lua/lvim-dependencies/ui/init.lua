-- lvim-dependencies.ui: an independent lvim-ui instance for lvim-dependencies.
-- The instance is created lazily and cached on first use, so its geometry/icons are read
-- from lvim-dependencies.config.ui.popup only once the config has been merged. lvim-utils
-- is required inline (cross-plugin dependency) to avoid a load-order requirement.
--
-- The INFO viewer (`M.open`) — the registry / manager / cache / state / metrics browser — is the
-- plugin's MAIN panel. It routes through the shared dock STACK (`lvim-utils.dock`) when
-- `config.dock.dock_stack` is on. The dock keys every entry by (id, LAYOUT): the base id
-- ("lvim-dependencies") is the stable identity, and the SAME id opened in a DIFFERENT layout is a
-- SEPARATE entry in that other layout's stack — so the info panel can be VISIBLE in float AND bottom
-- AND area AT ONCE (one entry per stack), while re-opening the SAME (id, layout) RE-SHOWS the one
-- entry (never a duplicate in that stack). Each entry is cyclable via <Leader>n/p, killable with
-- <Leader>x, one-visible-per-layout; its geometry comes from the central `dock.slot` authority. Because
-- one id can live in every layout at once, ALL open-state is PER LAYOUT: `_panels[layout]` holds one
-- consumer / one window pair / one dock KEY, and the lifecycle APIs (`parked`/`hide`) take the STORED
-- KEY (not the bare id). With `dock_stack` off it opens STANDALONE — geometry still central
-- (`dock.slot` + `config.dock.force`), just NOT in the stack. The select / multiselect / input
-- sub-dialogs are transient modals spawned FROM the plugin (never their own dock entries).
--
---@module "lvim-dependencies.ui"

local api = vim.api

local M = {}

---@type table? cached lvim-ui instance (nil until first ui() call)
local _instance = nil

--- The stable dock IDENTITY — the base id shared across every layout the info viewer is docked in.
--- NEVER layout-encoded: the dock composes the (id, layout) ENTRY KEY and returns it from `dock.open`.
---@type string
local DOCK_ID = "lvim-dependencies"

--- The default layout for `M.open` when the caller names none — the info viewer is inherently a centred
--- FLOAT. Not a single constant assumption: `M.open` accepts a `layout`, so the panel can dock in
--- another stack (bottom / area) as its own (id, layout) entry, present alongside the float one.
---@type "float"|"area"|"bottom"
local DEFAULT_LAYOUT = "float"

--- A single-width nf-oct-package glyph (U+F487) for the <Leader>m dock menu row.
---@type string
local DOCK_ICON = ""

--- Live state of ONE layout's info-panel dock entry. Because the dock keys entries by (id, layout), the
--- SAME info panel can be docked in float, bottom AND area at once — so every piece of open-state lives
--- HERE, keyed by layout (see `panel_state`). `content`/`title` are REMEMBERED across a park so a dock
--- re-show (cycle / reveal) rebuilds the exact panel; `teardown` suppresses the self-dismiss notification
--- while WE (or the manager) close the window; `alive` gates pruning; `consumer` is the memoised handle
--- for THIS layout; `key` is the (id, layout) ENTRY KEY returned by `dock.open`, passed back to the
--- lifecycle APIs (`parked`/`hide`) for THIS entry.
---@class LvimDependenciesPanelState
---@field win      integer?
---@field buf      integer?
---@field content  (string|string[])?
---@field title    string?
---@field teardown boolean
---@field alive    boolean
---@field consumer table?
---@field key      string?

--- Per-LAYOUT panel state. A flat single-panel table would orphan the float window the moment the panel
--- is opened in a second layout — so open-state is kept per layout in `_panels[layout]`.
---@type table<string, LvimDependenciesPanelState>
local _panels = {}

--- Lazily create + return this layout's panel-state slot (one consumer / one window pair / one dock key
--- per layout, so an open in float and an open in bottom are wholly independent live entries).
---@param layout string  "float" | "area" | "bottom"
---@return LvimDependenciesPanelState
local function panel_state(layout)
    _panels[layout] = _panels[layout]
        or {
            win = nil,
            buf = nil,
            content = nil,
            title = nil,
            teardown = false,
            alive = false,
            consumer = nil,
            key = nil,
        }
    return _panels[layout]
end

--- Lazily build and cache the plugin's private ui instance from config.ui.popup.
---@return table instance
local function ui()
    if _instance then
        return _instance
    end
    local popup = require("lvim-dependencies.config").ui.popup
    -- max_height / close_keys / position come from the SHARED lvim-ui `config.ui` (the presenters read them),
    -- so we only forward lvim-dependencies-specific values: the list-row cap and the active-item marker.
    _instance = require("lvim-ui").new({
        max_items = popup.max_items,
        icons = { current = popup.current },
    })
    return _instance
end

--- The shared global lvim-ui (used for info floats, not the private select instance).
---@return table
local function global_ui()
    return require("lvim-ui")
end

--- The live dock config sub-table (namespaced under `config.dock`).
---@return LvimDependenciesDockConfig
local function dock_cfg()
    return require("lvim-dependencies.config").dock
end

--- The shared dock manager, pcall-guarded (cross-plugin; absent on an older lvim-utils).
---@return table? dock
local function get_dock()
    local ok, d = pcall(require, "lvim-utils.dock")
    return ok and d or nil
end

-- ── Info / float (the MAIN dock panel) ────────────────────────────────────────

--- Translate a resolved `dock.slot` rect into `lvim-ui.info` size opts: an `*_auto` axis becomes a
--- content-fit-up-to-`max`, else a fixed size. area/bottom are full-width (their slot width = the full
--- columns) — passed as a fixed width, harmless for the centred float.
---@param slot table? the LvimDockSlot from dock.slot (row/col/width/height + *_auto)
---@return table opts size opts for lvim-ui.info (width/height/max_width/max_height)
local function slot_size_opts(slot)
    local opts = {}
    if not slot then
        return opts
    end
    if slot.height ~= nil then
        if slot.height_auto then
            opts.max_height = slot.height
        else
            opts.height = slot.height
        end
    end
    if slot.width ~= nil then
        if slot.width_auto then
            opts.max_width = slot.width
        else
            opts.width = slot.width
        end
    end
    return opts
end

--- Close this layout's panel window WITHOUT notifying the dock (a manager park / content swap): set the
--- teardown guard so the WinClosed hook stays quiet, then close. Keeps `ps.content` intact.
---@param ps LvimDependenciesPanelState
local function close_window(ps)
    if ps.win and api.nvim_win_is_valid(ps.win) then
        ps.teardown = true
        pcall(api.nvim_win_close, ps.win, true)
    end
    ps.win, ps.buf = nil, nil
end

--- PARK this layout's panel: drop its window but KEEP `ps.content`/`ps.title` so a dock re-show rebuilds it.
---@param ps LvimDependenciesPanelState
local function park(ps)
    close_window(ps)
end

--- Render this layout's remembered content into a fresh info float sized to `slot`, storing the new
--- buf/win on `ps`. When `managed` (a dock-stack render) a WinClosed hook notifies the manager on a
--- self-dismiss (q / <Esc> / :q) BY THIS ENTRY'S STORED KEY so the entry parks (stays cyclable) rather
--- than lingering as a stale visible id.
---@param ps LvimDependenciesPanelState  this layout's panel state
---@param slot table? the LvimDockSlot to size to (nil = lvim-ui.info's own content-fit)
---@param managed boolean whether this render belongs to a dock-stack entry
---@return integer? buf, integer? win
local function render(ps, slot, managed)
    close_window(ps) -- a content swap / re-show replaces any existing panel window (no double float)
    local opts = {
        close_keys = { "q", "<ESC>" },
        filetype = "LvimDepsInfo",
        markview = true,
    }
    if ps.title then
        opts.title = ps.title
    end
    for k, v in pairs(slot_size_opts(slot)) do
        opts[k] = v
    end
    local buf, win = global_ui().info(ps.content or "", opts)
    ps.buf, ps.win = buf, win
    if managed and win and api.nvim_win_is_valid(win) then
        api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(win),
            once = true,
            callback = function()
                ps.win, ps.buf = nil, nil
                if ps.teardown then
                    ps.teardown = false -- WE / the manager closed it — no self-dismiss notification
                    return
                end
                -- User self-dismiss (q / <Esc> / :q): keep the entry on the stack (cyclable), collapse the
                -- layout — do NOT reveal a neighbour (that is `closed`), do NOT drop it (that is `dropped`).
                local d = get_dock()
                if d and ps.alive and ps.key then
                    pcall(d.parked, ps.key) -- park by this entry's STORED (id, layout) KEY
                end
            end,
            desc = "lvim-dependencies: notify the dock when the info panel self-dismisses",
        })
    end
    return buf, win
end

--- Build (once, memoised on `ps.consumer`) + return the info-panel dock consumer FOR ONE LAYOUT (the
--- `lvim-utils.dock` contract; a cross-plugin type annotated `table`). `id` is the UNCHANGED base identity
--- (layout is NOT baked into it; the dock composes the (id, layout) key), and every callback is scoped to
--- THIS layout's `ps`. `show` rebuilds the panel from the remembered content at the manager's slot; `hide`
--- PARKS (keep content, restorable); `close` (<Leader>x) tears down + forgets; `is_alive` tracks whether
--- it still has content to restore. The select / input sub-dialogs are transient modals, NOT part of this
--- entry.
---@param layout string  "float" | "area" | "bottom"
---@return table consumer the LvimDockConsumer handle for this layout
local function get_consumer(layout)
    local ps = panel_state(layout)
    if not ps.consumer then
        ps.consumer = {
            id = DOCK_ID, -- base identity, UNCHANGED across layouts — the dock keys the entry by (id, layout)
            name = "dependencies",
            icon = DOCK_ICON,
            layout = layout, -- which stack THIS entry joins (fixed for this per-layout consumer)
            show = function(ctx)
                ps.teardown = false
                ps.alive = true
                render(ps, ctx and ctx.rect, true)
            end,
            hide = function()
                park(ps) -- manager PARK: keep the remembered content, drop the window
            end,
            close = function()
                -- <Leader>x — KILL this layout's dock entry: tear the window down and forget the content so
                -- `is_alive` returns false and the entry drops from the stack. Other layouts are untouched.
                ps.alive = false
                park(ps)
                ps.content, ps.title = nil, nil
            end,
            is_alive = function()
                return ps.alive == true and ps.content ~= nil
            end,
            focus = function()
                if ps.win and api.nvim_win_is_valid(ps.win) then
                    pcall(api.nvim_set_current_win, ps.win)
                end
            end,
            is_current = function()
                return ps.win ~= nil and api.nvim_win_is_valid(ps.win) and api.nvim_get_current_win() == ps.win
            end,
            buffers = function()
                return (ps.buf and api.nvim_buf_is_valid(ps.buf)) and { ps.buf } or {}
            end,
        }
    end
    ps.consumer.layout = layout
    -- Refresh the ANCHORED geometry override per open: `do_show` feeds it to `dock.slot(layout, slot)`
    -- for this entry's rect. Empty {} = inherit the global geometry; a populated `force[layout]` forces it.
    ps.consumer.slot = dock_cfg().force[layout]
    return ps.consumer
end

--- Open (or re-show) the plugin's MAIN info panel with `content` in `layout`. With `config.dock.dock_stack`
--- on it routes THROUGH the dock manager (`dock.open`): the "lvim-dependencies" entry FOR THAT LAYOUT
--- re-shows with the new content, parking any other consumer visible in that layout — and, because the dock
--- keys entries by (id, layout), the panel can be present in float AND bottom AND area at once (one entry per
--- stack). `dock.open` RETURNS the (id, layout) ENTRY KEY; it is STORED on the layout's state and passed back
--- to `parked`/`hide`. With `dock_stack` off it opens STANDALONE — geometry still central
--- (`dock.slot(layout, force[layout])`), just NOT in the stack. Returns the panel buf/win (metrics binds its
--- reload keymaps on them).
---@param content string|string[]
---@param title? string
---@param layout? "float"|"area"|"bottom"  which dock stack to occupy (default: float)
---@return integer? buf, integer? win
function M.open(content, title, layout)
    layout = layout or DEFAULT_LAYOUT
    local ps = panel_state(layout)
    ps.content = content
    ps.title = title
    local d = get_dock()
    if d and dock_cfg().dock_stack then
        ps.alive = true
        -- STORE the returned ENTRY KEY (id, layout): SHOW-OR-CREATE → consumer.show → render at ctx.rect
        -- (sets ps.buf/win). Re-opening the same (id, layout) returns the same key and RE-SHOWS the one
        -- entry — never a duplicate in that stack. `parked`/`hide` take this key back.
        ps.key = d.open(get_consumer(layout))
        return ps.buf, ps.win
    end
    -- Standalone: geometry is STILL central + force (dock.slot), the panel simply does not join the stack.
    local slot = d and d.slot(layout, dock_cfg().force[layout]) or nil
    return render(ps, slot, false)
end

--- Close the info panel window. In the dock-stack mode a programmatic close of a panel PARKS it through the
--- manager BY ITS STORED KEY (keeps the entry restorable — metrics' reload closes then re-opens); otherwise
--- it just closes the standalone float. Finds which layout owns `win` (the panel can be open in several).
---@param win integer?
function M.close(win)
    if not win then
        return
    end
    if dock_cfg().dock_stack then
        local d = get_dock()
        if d then
            for _, ps in pairs(_panels) do
                if win == ps.win and ps.key then
                    d.hide(ps.key) -- park via the manager (consumer.hide → close_window, teardown-guarded)
                    return
                end
            end
        end
    end
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
