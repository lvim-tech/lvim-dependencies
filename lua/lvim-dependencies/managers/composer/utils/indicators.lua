-- lvim-dependencies.managers.composer.utils.indicators: buffer-local UI state around a composer
-- operation — the "pending" extmark anchor that keeps the working indicator glued to the right
-- line as the file changes, and the outdated-poll loop. After a require/remove the new latest
-- version is not known instantly, so poll_for_outdated retries get_package_latest on an interval
-- (after a start delay) until a version arrives or max attempts is hit, then clears loading state.
--
---@module "lvim-dependencies.managers.composer.utils.indicators"

local api = vim.api
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")
local init = require("lvim-dependencies.core.init")
local state = require("lvim-dependencies.core.state")
local cache = require("lvim-dependencies.core.cache")
local latest = require("lvim-dependencies.core.hub.latest")
local vt = require("lvim-dependencies.managers.composer.virtual_text")
local manifest = require("lvim-dependencies.managers.composer.manifest")

local config_groups = config.groups
local debug = utils.debug

local NAMESPACE_VIRTUAL_TEXT = const.NAMESPACES.VIRTUAL_TEXT

local POLLING = config.composer and config.composer.polling or {}
local DEFAULT_MAX_POLLS = POLLING.max_attempts or 30
local DEFAULT_INTERVAL = POLLING.interval_ms or 200
local DEFAULT_START_DELAY = POLLING.start_delay_ms or 500

---@class ComposerUIActions
local M = {}

local function is_valid_buffer_and_line(bufnr, lnum)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if lnum and (type(lnum) ~= "number" or lnum < 1) then
        return false
    end
    return true
end

local function reset_buffer_loading_state(bufnr)
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    local buf_state = state.get_buffer_state(bufnr)
    buf_state.is_loading = false
    buf_state.pending_dep = nil
    buf_state.pending_lnum = nil
    buf_state.pending_scope = nil
end

--- Resolve (creating if needed) the composer virtual-text extmark namespace id.
---@return integer
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
    return api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { right_gravity = false })
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

function M.clear_global_composer_cache()
    cache.clear("composer", const.CACHE_TYPES.INSTALLED)
    cache.clear("composer", const.CACHE_TYPES.LATEST)
    debug("composer: cleared global cache", vim.log.levels.INFO)
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

    -- Platform requirements (php / ext-* / …) have no packagist entry, so get_package_latest
    -- returns nil forever — polling would burn every attempt for nothing. Terminate immediately.
    if not manifest.is_package_actionable(name) then
        reset_buffer_loading_state(bufnr)
        if user_callback then
            user_callback()
        end
        return
    end

    local poll_count = 0
    local max_polls = opts.max_polls or DEFAULT_MAX_POLLS
    local interval = opts.interval or DEFAULT_INTERVAL

    local function poll()
        poll_count = poll_count + 1
        latest.get_package_latest("composer", name, function(_, version)
            if version ~= nil or poll_count >= max_polls then
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
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

return M
