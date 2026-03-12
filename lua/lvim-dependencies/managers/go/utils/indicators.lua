-- lvim-dependencies/managers/go/utils/indicators.lua
-- UI state management for Go actions (loading, anchors, extmarks)

---@include "core/types.lua"

local api = vim.api
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")
local init = require("lvim-dependencies.core.init")
local state = require("lvim-dependencies.core.state")
local cache = require("lvim-dependencies.core.cache")
local latest = require("lvim-dependencies.core.hub.latest")
local vt = require("lvim-dependencies.managers.go.virtual_text")

local config_groups = config.highlight.groups
local debug = utils.debug

local NAMESPACE_VIRTUAL_TEXT = const.NAMESPACES.VIRTUAL_TEXT

local POLLING = config.go and config.go.polling or {}
local DEFAULT_MAX_POLLS = POLLING.max_attempts or 30
local DEFAULT_INTERVAL = POLLING.interval_ms or 200
local DEFAULT_START_DELAY = POLLING.start_delay_ms or 500

---@class GoUIActions
local M = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function is_valid_buffer_and_line(bufnr, lnum)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if lnum and (type(lnum) ~= "number" or lnum < 1) then
        return false
    end
    return true
end

local function clear_line_extmarks(bufnr, lnum, ns)
    local marks = api.nvim_buf_get_extmarks(bufnr, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, {})
    for _, mark in ipairs(marks) do
        api.nvim_buf_del_extmark(bufnr, ns, mark[1])
    end
end

local function reset_buffer_loading_state(bufnr)
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    local buf_state = state.get_buffer_state(bufnr)
    buf_state.is_loading = false
    buf_state.pending_dep = nil
    buf_state.pending_lnum = nil
end

-- ============================================================================
-- Public API
-- ============================================================================

function M.ensure_namespace()
    return api.nvim_create_namespace(NAMESPACE_VIRTUAL_TEXT)
end

---@param bufnr integer
---@param lnum integer
---@return integer|nil
function M.set_pending_anchor(bufnr, lnum)
    if not is_valid_buffer_and_line(bufnr, lnum) then
        return nil
    end
    local ns = M.ensure_namespace()
    local id = api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { right_gravity = false })
    debug(string.format("go: set anchor at line %d for buffer %d", lnum, bufnr), vim.log.levels.DEBUG)
    return id
end

---@param bufnr integer
function M.clear_pending_anchor(bufnr)
    if not is_valid_buffer_and_line(bufnr) then
        return
    end
    local buf_state = state.get_buffer_state(bufnr)
    if not buf_state.pending_anchor_id then
        return
    end
    local ns = M.ensure_namespace()
    pcall(api.nvim_buf_del_extmark, bufnr, ns, buf_state.pending_anchor_id)
    buf_state.pending_anchor_id = nil
end

---@param bufnr integer
---@param lnum integer
function M.set_loading_indicator(bufnr, lnum)
    if not is_valid_buffer_and_line(bufnr, lnum) then
        return
    end

    local ns = M.ensure_namespace()
    clear_line_extmarks(bufnr, lnum, ns)

    local manifest = init.get_manifest("go")
    local cfg_vt = config.go and config.go.virtual_text
    local priority = (cfg_vt and cfg_vt.priority)
        or (manifest and manifest.virtual_text and manifest.virtual_text.priority)
        or 1000
    local position = (cfg_vt and cfg_vt.position)
        or (manifest and manifest.virtual_text and manifest.virtual_text.position)
        or "eol"

    local loading_parts = vt.get_loading_parts()
    local loading_text = ""
    for _, part in ipairs(loading_parts) do
        loading_text = loading_text .. part[1]
    end

    api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        virt_text = { { loading_text, config_groups.loading } },
        virt_text_pos = position,
        priority = priority,
    })
    vim.cmd("redraw")
end

function M.clear_global_go_cache()
    cache.clear("go", const.CACHE_TYPES.INSTALLED)
    cache.clear("go", const.CACHE_TYPES.LATEST)
    debug("go: cleared global cache (via cache API)", vim.log.levels.INFO)
end

---@param bufnr integer
---@param name string
---@param callback fun()|{max_polls?: integer, interval?: integer, callback?: fun()}
function M.poll_for_outdated(bufnr, name, callback)
    local opts = {}
    local user_callback = callback

    if type(callback) == "table" then
        opts = callback
        user_callback = opts.callback
    end

    local poll_count = 0
    local max_polls = opts.max_polls or DEFAULT_MAX_POLLS
    local interval = opts.interval or DEFAULT_INTERVAL

    debug(
        string.format("go: starting poll for %s (max: %d, interval: %dms)", name, max_polls, interval),
        vim.log.levels.INFO
    )

    local function poll()
        poll_count = poll_count + 1
        latest.get_package_latest("go", name, function(_, version)
            if version ~= nil or poll_count >= max_polls then
                debug(
                    string.format("go: poll completed for %s after %d attempts", name, poll_count),
                    vim.log.levels.INFO
                )
                reset_buffer_loading_state(bufnr)
                if user_callback then
                    user_callback()
                end
            else
                vim.defer_fn(poll, interval)
            end
        end)
    end

    vim.defer_fn(poll, DEFAULT_START_DELAY)
end

function M.trigger_package_updated()
    debug("go: triggering LvimDepsPackageUpdated", vim.log.levels.DEBUG)
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

return M
