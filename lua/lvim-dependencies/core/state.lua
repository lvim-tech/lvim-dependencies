-- lvim-dependencies.core.state: per-buffer lifecycle bookkeeping and the bridge between
-- buffer events and the virtual-text handlers. Tracks each buffer's open/save/modify
-- counts, drives package (re)loading on open and a debounced diff on save (new / changed /
-- removed packages), and de-duplicates concurrent loads of the same manifest:package via a
-- pending_loads set + waiter queue so a second request just attaches to the in-flight one.
-- The initial open uses a randomized per-package delay (hence the one-time randomseed) to
-- stagger the virtual-text reveal.
--
---@module "lvim-dependencies.core.state"

local api = vim.api
local registry = require("lvim-dependencies.core.registry")
local utils = require("lvim-dependencies.utils")
local package_loader = require("lvim-dependencies.core.package_loader")
local declared = require("lvim-dependencies.core.hub.declared")
local async = require("lvim-dependencies.core.async_util")
local metrics = require("lvim-dependencies.core.metrics")
local virtual_text = require("lvim-dependencies.core.virtual_text")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")

-- Seed random once per session for shuffle()
math.randomseed(os.time() + math.floor(vim.uv.hrtime() / 1e6))

local utils_buffer = utils.buffer
local debug = utils.debug
local notify = utils.notify

-- ============================================================================
-- Constants
-- ============================================================================
-- Source values from config, not from const.DEFAULTS
local SAVE_DEBOUNCE_MS = config.async.debounce.save or 200
local VISUAL_DELAY_MIN = config.ui.visual_delay_min or 100
local VISUAL_DELAY_MAX = config.ui.visual_delay_max or 900
local NAMESPACE_VIRTUAL_TEXT = const.NAMESPACES.VIRTUAL_TEXT
-- Cache the numeric namespace ID — nvim_create_namespace is safe at require time
local VT_NAMESPACE_ID = api.nvim_create_namespace(NAMESPACE_VIRTUAL_TEXT)

local EVENT_BUFFER_OPENED = const.EVENTS.BUFFER_OPENED
local EVENT_BUFFER_SAVED = const.EVENTS.BUFFER_SAVED
local EVENT_BUFFER_CLOSED = const.EVENTS.BUFFER_CLOSED
local EVENT_BUFFER_ENTERED = const.EVENTS.BUFFER_ENTERED
local EVENT_BUFFER_FILETYPE_CHANGED = const.EVENTS.BUFFER_FILETYPE_CHANGED

---@type VirtualTextHandlers
local DEFAULT_HANDLERS = {
    get_loaded_packages = function()
        return {}
    end,
    find_package_line = function()
        return nil
    end,
    move_virt_texts_only = function() end,
    display_loading = function() end,
    update_package = function() end,
    display_loading_for_package = function() end,
    remove_package = function() end,
    clear_buffer = function() end,
}

---@class StateModule
local M = {
    _state = {
        buffers = {}, ---@type table<integer, StateBufferData>
        _event_handlers = {}, ---@type table<string, function[]>
    },
    ---@type VirtualTextHandlers
    _handlers = vim.deepcopy(DEFAULT_HANDLERS),
}

---@type table<string, boolean>
local pending_loads = {}

---@type table<string, function[]>
local pending_waiters = {}

---@type table<integer, table>
local save_timers = {}

---@param manifest_type string
---@param package_name string
---@return string
local function make_key(manifest_type, package_name)
    return string.format("%s:%s", manifest_type, package_name)
end

---@param timer table|nil
local function close_timer(timer)
    if not timer then
        return
    end
    pcall(function()
        if timer:is_active() then
            timer:stop()
        end
        if not timer:is_closing() then
            timer:close()
        end
    end)
end

---@param buf integer
---@return StateBufferData
local function get_or_create_buffer_state(buf)
    local state = M._state.buffers[buf]
    if not state then
        state = {
            filename = "",
            filetype = "",
            count_open = 0,
            count_save = 0,
            count_filetype_changes = 0,
            count_enter = 0,
            is_open = false,
            initial_load_complete = false,
        }
        M._state.buffers[buf] = state
    end
    return state
end

---@param key string
---@param ... any
local function notify_waiters(key, ...)
    local waiters = pending_waiters[key]
    if not waiters then
        return
    end
    for _, waiter in ipairs(waiters) do
        pcall(waiter, ...)
    end
    pending_waiters[key] = nil
end

---@param key string
---@param callback function
local function add_waiter(key, callback)
    local waiters = pending_waiters[key]
    if not waiters then
        waiters = {}
        pending_waiters[key] = waiters
    end
    waiters[#waiters + 1] = callback
end

---@param manifest_type string
---@param package_name string
---@param is_initial boolean
---@return async_task_function
local function make_package_task(manifest_type, package_name, is_initial)
    return function(cb)
        local key = make_key(manifest_type, package_name)

        if pending_loads[key] then
            debug(string.format("Already loading %s, adding waiter", key), vim.log.levels.DEBUG)
            add_waiter(key, function(...)
                pcall(cb, ...)
            end)
            return
        end

        pending_loads[key] = true
        debug(string.format("Starting load for %s", key), vim.log.levels.DEBUG)

        async.run(function()
            package_loader.load_package_data_async(manifest_type, package_name, function(package_data)
                pending_loads[key] = nil
                pcall(cb, nil, package_data)
                notify_waiters(key, nil, package_data)
            end, { initial = is_initial })
        end)
    end
end

---@param list any[]
local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
end

local function update_buffer_stats()
    local active_count = 0
    local vt_count = 0

    for buf in pairs(M._state.buffers) do
        if utils_buffer.is_valid(buf) then
            active_count = active_count + 1
            if virtual_text.has_virtual_text and virtual_text.has_virtual_text(buf) then
                vt_count = vt_count + 1
            end
        end
    end

    metrics.update_buffers(active_count, vt_count)
end

---@param buf integer
---@param manifest_type string
---@param is_initial boolean
local function load_manifest_packages(buf, manifest_type, is_initial)
    debug(string.format("Loading packages for buffer %d, type: %s", buf, manifest_type), vim.log.levels.INFO)

    if not utils_buffer.is_valid(buf) then
        debug("Buffer invalid, cannot load packages", vim.log.levels.WARN)
        return
    end

    async.run(function()
        local declared_data = declared.get_data(manifest_type, { force_refresh = true })
        local pkg_count = vim.tbl_count(declared_data or {})
        debug(string.format("Found %d packages in %s", pkg_count, manifest_type), vim.log.levels.INFO)

        if not utils_buffer.is_valid(buf) then
            debug("Buffer became invalid, aborting package loading", vim.log.levels.WARN)
            return
        end

        local buffer_state = get_or_create_buffer_state(buf)
        buffer_state.initial_load_complete = false

        M._handlers.display_loading(buf, manifest_type, declared_data, is_initial)

        local packages = vim.tbl_keys(declared_data or {})
        shuffle(packages)

        for _, pkg_name in ipairs(packages) do
            local key = make_key(manifest_type, pkg_name)

            if pending_loads[key] then
                debug(string.format("%s already pending, attaching waiter", pkg_name), vim.log.levels.DEBUG)
                add_waiter(key, function(_, package_data)
                    if utils_buffer.is_valid(buf) then
                        M._handlers.update_package(buf, package_data)
                    end
                end)
            else
                pending_loads[key] = true

                async.run(function()
                    debug(string.format("Loading package %s", pkg_name), vim.log.levels.INFO)

                    package_loader.load_package_data_async(manifest_type, pkg_name, function(package_data)
                        if is_initial then
                            local delay = math.random(VISUAL_DELAY_MIN, VISUAL_DELAY_MAX)
                            debug(string.format("Visual delay for %s: %dms", pkg_name, delay), vim.log.levels.DEBUG)
                            async.sleep(delay)
                        end

                        pending_loads[key] = nil

                        if utils_buffer.is_valid(buf) then
                            debug(string.format("Updating %s", pkg_name), vim.log.levels.DEBUG)
                            M._handlers.update_package(buf, package_data)
                        end

                        notify_waiters(key, nil, package_data)
                    end, { initial = is_initial })
                end)
            end
        end

        buffer_state.initial_load_complete = true
        debug("All packages started loading", vim.log.levels.INFO)
    end)
end

---@param buf integer
---@param all_results table|nil
---@param err string|nil
---@param context string
---@return boolean
local function process_async_results(buf, all_results, err, context)
    if err then
        vim.schedule(function()
            notify(string.format("%s: %s", context, tostring(err)), vim.log.levels.ERROR)
        end)
        return false
    end
    return all_results ~= nil and utils_buffer.is_valid(buf)
end

---@param buf integer
---@param new_packages NewPackage[]
---@param is_initial boolean
local function handle_new_packages(buf, new_packages, is_initial)
    if not utils_buffer.is_valid(buf) or #new_packages == 0 then
        return
    end

    local filename = api.nvim_buf_get_name(buf)
    local manifest_type = registry.determine_manifest_type(filename)
    if not manifest_type then
        return
    end

    async.run(function()
        for _, pkg in ipairs(new_packages) do
            M._handlers.display_loading_for_package(buf, manifest_type, pkg, "loading")
        end

        local tasks = {}
        for _, pkg in ipairs(new_packages) do
            local key = make_key(manifest_type, pkg.name)
            if not pending_loads[key] then
                tasks[#tasks + 1] = make_package_task(manifest_type, pkg.name, is_initial)
            else
                add_waiter(key, function(_, result)
                    if result and utils_buffer.is_valid(buf) then
                        M._handlers.update_package(buf, result)
                    end
                end)
            end
        end

        if #tasks == 0 then
            return
        end

        local all_results, err = async.all_with_limit(tasks)
        if not process_async_results(buf, all_results, err, "Error loading new packages") then
            return
        end

        for _, package_data in ipairs(all_results) do
            if type(package_data) == "table" and package_data.package then
                M._handlers.update_package(buf, package_data)
            end
        end
    end)
end

---@param buf integer
---@param manifest_type string
---@param changed_packages ChangedPackage[]
local function handle_changed_packages(buf, manifest_type, changed_packages)
    if not utils_buffer.is_valid(buf) or #changed_packages == 0 then
        return
    end

    async.run(function()
        local tasks = {}
        local task_packages = {}
        for _, pkg in ipairs(changed_packages) do
            local key = make_key(manifest_type, pkg.name)
            if not pending_loads[key] then
                tasks[#tasks + 1] = make_package_task(manifest_type, pkg.name, false)
                task_packages[#task_packages + 1] = pkg
            else
                local new_version = pkg.new_version
                add_waiter(key, function(_, result)
                    if result and utils_buffer.is_valid(buf) then
                        result.declared = new_version
                        M._handlers.update_package(buf, result)
                    end
                end)
            end
        end

        if #tasks == 0 then
            return
        end

        local all_results, err = async.all_with_limit(tasks)
        if not process_async_results(buf, all_results, err, "Error loading changed packages") then
            return
        end

        for i, package_data in ipairs(all_results) do
            if type(package_data) == "table" and package_data.package then
                package_data.declared = task_packages[i] and task_packages[i].new_version
                M._handlers.update_package(buf, package_data)
            end
        end
    end)
end

---@param buf integer
---@param removed_packages string[]
local function handle_removed_packages(buf, removed_packages)
    if not utils_buffer.is_valid(buf) or #removed_packages == 0 then
        return
    end

    for _, pkg_name in ipairs(removed_packages) do
        M._handlers.remove_package(buf, pkg_name)
    end
end

---@param buf integer
---@param manifest_type string
---@return PackageChanges
local function find_package_changes(buf, manifest_type)
    local changes = { new = {}, changed = {}, removed = {} }
    if not utils_buffer.is_valid(buf) then
        return changes
    end

    local fresh_declared = declared.get_data(manifest_type, { force_refresh = true }) or {}
    local loaded = M._handlers.get_loaded_packages(buf) or {}

    for pkg_name, fresh_info in pairs(fresh_declared) do
        local fresh_version = type(fresh_info) == "table" and (fresh_info.declared or fresh_info.version) or fresh_info

        if not loaded[pkg_name] then
            local line_num = M._handlers.find_package_line(buf, pkg_name)
            if line_num then
                changes.new[#changes.new + 1] = { name = pkg_name, line = line_num, info = fresh_info }
            end
        else
            local loaded_version = loaded[pkg_name] and loaded[pkg_name].declared
            if loaded_version ~= fresh_version then
                changes.changed[#changes.changed + 1] = {
                    name = pkg_name,
                    old_version = loaded_version,
                    new_version = fresh_version,
                }
            end
        end
    end

    for pkg_name in pairs(loaded) do
        if not fresh_declared[pkg_name] then
            changes.removed[#changes.removed + 1] = pkg_name
        end
    end

    return changes
end

---@param buf integer
---@param manifest_type string
local function check_for_package_changes_on_save(buf, manifest_type)
    if not utils_buffer.is_valid(buf) or not manifest_type then
        return
    end

    local changes = find_package_changes(buf, manifest_type)

    if #changes.new > 0 then
        handle_new_packages(buf, changes.new, false)
    end
    if #changes.changed > 0 then
        handle_changed_packages(buf, manifest_type, changes.changed)
    end
    if #changes.removed > 0 then
        handle_removed_packages(buf, changes.removed)
    end

    M._handlers.move_virt_texts_only(buf)
end

-- ============================================================================
-- Event handlers
-- ============================================================================

---@param buf integer
---@param buffer_state StateBufferData
---@param buffer_info table
---@param event_data BufferEventData
local function handle_opened_event(buf, buffer_state, buffer_info, event_data)
    if buffer_state.skip_next_check then
        buffer_state.skip_next_check = false
        debug(string.format("Skipping re-open for %s (skip_next_check)", buffer_info.filename), vim.log.levels.DEBUG)
        return
    end

    debug(string.format("Buffer opened: %s", buffer_info.filename), vim.log.levels.INFO)

    buffer_state.filename = buffer_info.filename
    buffer_state.filetype = buffer_info.filetype
    buffer_state.last_opened = event_data.timestamp
    buffer_state.count_open = (buffer_state.count_open or 0) + 1
    buffer_state.is_open = true
    buffer_state.initial_load_complete = false

    local manifest_type = registry.determine_manifest_type(buffer_info.filename)
    debug(string.format("Manifest type: %s", manifest_type or "none"), vim.log.levels.DEBUG)

    if manifest_type and utils_buffer.is_valid(buf) then
        debug(string.format("Loading packages for %s", manifest_type), vim.log.levels.INFO)
        load_manifest_packages(buf, manifest_type, true)
    end

    update_buffer_stats()
end

---@param buf integer
---@param buffer_state StateBufferData
---@param buffer_info table
---@param event_data BufferEventData
local function handle_saved_event(buf, buffer_state, buffer_info, event_data)
    debug(string.format("Buffer saved: %s", buffer_info.filename), vim.log.levels.INFO)

    buffer_state.last_saved = event_data.timestamp
    buffer_state.count_save = (buffer_state.count_save or 0) + 1

    local manifest_type = registry.determine_manifest_type(buffer_info.filename)
    if not manifest_type or not utils_buffer.is_valid(buf) then
        return
    end

    close_timer(save_timers[buf])
    save_timers[buf] = nil

    local timer = vim.uv.new_timer()
    if not timer then
        return
    end

    save_timers[buf] = timer

    timer:start(
        SAVE_DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
            save_timers[buf] = nil
            if utils_buffer.is_valid(buf) then
                check_for_package_changes_on_save(buf, manifest_type)
            end
            close_timer(timer)
        end)
    )
end

---@param buf integer
---@param buffer_state StateBufferData
---@param buffer_info table
---@param event_data BufferEventData
---@diagnostic disable-next-line: unused-local
local function handle_closed_event(buf, buffer_state, buffer_info, event_data)
    local force = type(event_data.extra) == "table" and event_data.extra.force
    local windows = not force and vim.fn.win_findbuf(buf) or {}
    if not force and #windows > 0 then
        debug(
            string.format("Buffer %d still visible in %d window(s), not closing", buf, #windows),
            vim.log.levels.DEBUG
        )
        buffer_state.is_open = true
        return
    end

    debug(string.format("Buffer closed: %s", buffer_state.filename), vim.log.levels.INFO)

    buffer_state.last_closed = event_data.timestamp
    buffer_state.is_open = false
    M._handlers.clear_buffer(buf)
    M._state.buffers[buf] = nil

    close_timer(save_timers[buf])
    save_timers[buf] = nil

    update_buffer_stats()
end

---@param buf integer
---@param buffer_state StateBufferData
---@param buffer_info table
---@param event_data BufferEventData
---@diagnostic disable-next-line: unused-local
local function handle_filetype_changed(buf, buffer_state, buffer_info, event_data)
    buffer_state.filetype = buffer_info.filetype
    buffer_state.count_filetype_changes = (buffer_state.count_filetype_changes or 0) + 1
end

---@param buf integer
---@param buffer_state StateBufferData
---@param buffer_info table
---@param event_data BufferEventData
---@diagnostic disable-next-line: unused-local
local function handle_entered_event(buf, buffer_state, buffer_info, event_data)
    buffer_state.last_entered = event_data.timestamp
    buffer_state.count_enter = (buffer_state.count_enter or 0) + 1
end

---@type table<string, fun(buf: integer, buffer_state: StateBufferData, buffer_info: table, event_data: BufferEventData)>
local EVENT_HANDLERS = {
    [EVENT_BUFFER_OPENED] = handle_opened_event,
    [EVENT_BUFFER_SAVED] = handle_saved_event,
    [EVENT_BUFFER_CLOSED] = handle_closed_event,
    [EVENT_BUFFER_FILETYPE_CHANGED] = handle_filetype_changed,
    [EVENT_BUFFER_ENTERED] = handle_entered_event,
}

-- ============================================================================
-- Public API
-- ============================================================================

---@param buf integer
---@param event_type string
---@param data? any
---@return BufferEventData|nil
function M.handle_buffer_event(buf, event_type, data)
    if not utils_buffer.is_valid(buf) then
        return nil
    end

    local buffer_info = utils_buffer.get_info(buf)
    if not buffer_info then
        return nil
    end
    local is_manifest = buffer_info.filename ~= ""
        and require("lvim-dependencies.core.registry").is_manifest_file(buffer_info.filename)
    if event_type == EVENT_BUFFER_CLOSED then
        if not M._state.buffers[buf] then
            return nil
        end
    elseif event_type ~= EVENT_BUFFER_FILETYPE_CHANGED and not is_manifest then
        return nil
    end
    local buffer_state = get_or_create_buffer_state(buf)

    ---@type BufferEventData
    local event_data = {
        type = event_type,
        timestamp = os.time(),
        filename = buffer_info.filename,
        filetype = buffer_info.filetype,
        lines = buffer_info.lines,
        modified = buffer_info.modified,
        extra = data or {},
    }

    local handler = EVENT_HANDLERS[event_type]
    if handler then
        handler(buf, buffer_state, buffer_info, event_data)
    end

    buffer_state.last_accessed = event_data.timestamp
    buffer_state.last_event = event_type

    for _, custom_handler in ipairs(M._state._event_handlers[event_type] or {}) do
        pcall(custom_handler, buf, event_data, buffer_state)
    end

    return event_data
end

---@param buf integer
---@return StateBufferData
function M.get_buffer_state(buf)
    return get_or_create_buffer_state(buf)
end

---@param bufnr integer
function M.clear_pending_state(bufnr)
    if not utils_buffer.is_valid(bufnr) then
        return
    end

    local buffer_state = M._state.buffers[bufnr]
    if not buffer_state then
        return
    end

    buffer_state.is_loading = false
    buffer_state.pending_dep = nil
    buffer_state.pending_lnum = nil
    buffer_state.pending_scope = nil

    if buffer_state.pending_anchor_id then
        pcall(api.nvim_buf_del_extmark, bufnr, VT_NAMESPACE_ID, buffer_state.pending_anchor_id)
        buffer_state.pending_anchor_id = nil
    end

    debug(string.format("Cleared pending state for buffer %d", bufnr), vim.log.levels.DEBUG)
end

---@param bufnr integer
function M.handle_buffer_change(bufnr)
    if not utils_buffer.is_valid(bufnr) then
        return
    end

    local buffer_state = M._state.buffers[bufnr]
    if buffer_state and buffer_state.is_loading then
        M.clear_pending_state(bufnr)
    end
end

---@param handlers VirtualTextHandlers
function M.set_handlers(handlers)
    debug("Setting virtual text handlers", vim.log.levels.DEBUG)
    M._handlers = vim.tbl_deep_extend("force", M._handlers, handlers)
end

--- Reset all buffer state and pending loads, and stop any save timers.
function M.setup()
    debug("Initializing state module", vim.log.levels.DEBUG)
    M._state.buffers = {}
    M._state._event_handlers = {}
    for key, waiters in pairs(pending_waiters) do
        for _, waiter in ipairs(waiters) do
            pcall(waiter, "aborted")
        end
        pending_waiters[key] = nil
    end
    pending_loads = {}

    for buf, timer in pairs(save_timers) do
        close_timer(timer)
        save_timers[buf] = nil
    end
end

---@param event string
---@param handler fun(buf: integer, event_data: BufferEventData, buffer_state: StateBufferData)
function M.on(event, handler)
    local handlers = M._state._event_handlers[event]
    if not handlers then
        handlers = {}
        M._state._event_handlers[event] = handlers
    end
    handlers[#handlers + 1] = handler
end

return M
