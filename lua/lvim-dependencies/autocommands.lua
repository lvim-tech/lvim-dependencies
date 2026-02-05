local api = vim.api
local fn = vim.fn
local defer_fn = vim.defer_fn

local config = require("lvim-dependencies.config")
local const = require("lvim-dependencies.const")
local state = require("lvim-dependencies.state")
local virtual_text = require("lvim-dependencies.ui.virtual_text")

local package_parser = require("lvim-dependencies.parsers.package")
local cargo_parser = require("lvim-dependencies.parsers.cargo")
local pubspec_parser = require("lvim-dependencies.parsers.pubspec")
local composer_parser = require("lvim-dependencies.parsers.composer")
local go_parser = require("lvim-dependencies.parsers.go")

local checker = require("lvim-dependencies.actions.check_manifests")
local commands = require("lvim-dependencies.commands")

local M = {}

local parsers = {}
for filename, key in pairs(const.MANIFEST_KEYS) do
    local parser_map = {
        package = package_parser,
        crates = cargo_parser,
        pubspec = pubspec_parser,
        composer = composer_parser,
        go = go_parser,
    }
    parsers[filename] = { parser = parser_map[key], key = key }
end

local UPDATE_COOLDOWN_MS = 5000

local function is_in_update_cooldown(bufnr)
    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}

    local last_update = state.buffers[bufnr].last_update_completed_at
    if not last_update then
        return false
    end

    local now = vim.loop.now()
    return (now - last_update) < UPDATE_COOLDOWN_MS
end

local function clear_cooldown(bufnr)
    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}
    state.buffers[bufnr].last_update_completed_at = nil
end

local function clear_parser_caches(manifest_key)
    local utils = require("lvim-dependencies.utils")
    utils.clear_file_cache()

    local parser_modules = {
        package = package_parser,
        crates = cargo_parser,
        pubspec = pubspec_parser,
        composer = composer_parser,
        go = go_parser,
    }

    local parser = parser_modules[manifest_key]
    if parser and parser.clear_lock_cache then
        parser.clear_lock_cache()
    end
end

local function clear_buffer_parse_cache(bufnr, manifest_key)
    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}

    local cache_keys = {
        package = { "last_package_hash", "last_package_parsed" },
        crates = { "last_crates_hash", "last_crates_parsed" },
        pubspec = { "last_pubspec_hash", "last_pubspec_parsed" },
        composer = { "last_composer_hash", "last_composer_parsed" },
        go = { "last_go_hash", "last_go_parsed" },
    }

    local keys = cache_keys[manifest_key]
    if keys then
        for _, key in ipairs(keys) do
            state.buffers[bufnr][key] = nil
        end
    end

    state.buffers[bufnr].last_changedtick = nil
    state.buffers[bufnr].parse_scheduled = false
end

local function call_manifest_checker(entry, bufnr)
    checker.check_manifest_outdated(bufnr, entry.key)
end

local function parse_and_render(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end

    local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
    local entry = parsers[filename]
    if not entry then
        return
    end

    local manifest_key = entry.key
    if config[manifest_key] and config[manifest_key].enabled == false then
        return
    end

    entry.parser.parse_buffer(bufnr)
    virtual_text.display(bufnr, manifest_key, { force_full = true })
    state.update_last_run(bufnr)
end

local function handle_buffer_parse_and_check(bufnr, force_fresh)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end

    local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
    local entry = parsers[filename]
    if not entry then
        return
    end

    local manifest_key = entry.key
    if config[manifest_key] and config[manifest_key].enabled == false then
        return
    end

    if force_fresh then
        clear_parser_caches(manifest_key)
        clear_buffer_parse_cache(bufnr, manifest_key)
        checker.clear_buffer_cache(bufnr, manifest_key)
    end

    entry.parser.parse_buffer(bufnr)
    call_manifest_checker(entry, bufnr)
    virtual_text.display(bufnr, manifest_key, { force_full = true })
    state.update_last_run(bufnr)
end

local function schedule_handle(bufnr, delay, full_check, force_fresh)
    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}
    if state.buffers[bufnr].check_scheduled then
        return
    end
    state.buffers[bufnr].check_scheduled = true
    defer_fn(function()
        state.buffers[bufnr].check_scheduled = false

        if state.buffers[bufnr].skip_next_check then
            state.buffers[bufnr].skip_next_check = nil
            return
        end

        if full_check then
            handle_buffer_parse_and_check(bufnr, force_fresh)
        else
            parse_and_render(bufnr)
        end
    end, delay)
end

local function schedule_light_render(bufnr, delay)
    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}

    if state.buffers[bufnr].light_render_scheduled then
        return
    end

    state.buffers[bufnr].light_render_scheduled = true
    defer_fn(function()
        state.buffers[bufnr].light_render_scheduled = false

        if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
            return
        end

        local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
        local entry = parsers[filename]
        if not entry then
            return
        end

        local manifest_key = entry.key
        if config[manifest_key] and config[manifest_key].enabled == false then
            return
        end

        virtual_text.display(bufnr, manifest_key)
    end, delay or 25)
end

local function on_buf_enter(args)
    local bufnr = (args and args.buf) or api.nvim_get_current_buf()

    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}

    if state.buffers[bufnr].checking_single_package or state.buffers[bufnr].is_loading then
        return
    end

    if is_in_update_cooldown(bufnr) then
        local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
        local entry = parsers[filename]
        commands.create_buf_commands_for(bufnr, entry and entry.key or nil)
        return
    end

    schedule_handle(bufnr, 50, true, false)

    local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
    local entry = parsers[filename]
    local manifest_key = entry and entry.key or nil

    commands.create_buf_commands_for(bufnr, manifest_key)
end

local function on_buf_write(args)
    local bufnr = (args and args.buf) or api.nvim_get_current_buf()

    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}

    if state.buffers[bufnr].checking_single_package or state.buffers[bufnr].is_loading then
        return
    end

    local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
    local entry = parsers[filename]
    local manifest_key = entry and entry.key or nil

    local was_in_cooldown = is_in_update_cooldown(bufnr)
    if was_in_cooldown then
        clear_cooldown(bufnr)
    end

    if manifest_key then
        clear_parser_caches(manifest_key)
        clear_buffer_parse_cache(bufnr, manifest_key)
    end

    schedule_handle(bufnr, 200, true, true)
end

local function on_buf_read(args)
    local bufnr = (args and args.buf) or api.nvim_get_current_buf()

    state.buffers = state.buffers or {}
    state.buffers[bufnr] = state.buffers[bufnr] or {}

    if state.buffers[bufnr].checking_single_package or state.buffers[bufnr].is_loading then
        return
    end

    local filename = fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":t")
    local entry = parsers[filename]
    local manifest_key = entry and entry.key or nil

    local was_in_cooldown = is_in_update_cooldown(bufnr)
    if was_in_cooldown then
        clear_cooldown(bufnr)
    end

    if manifest_key then
        clear_parser_caches(manifest_key)
        clear_buffer_parse_cache(bufnr, manifest_key)
    end

    schedule_handle(bufnr, 100, true, true)
end

local function on_win_scrolled(args)
    local bufnr = (args and args.buf) or api.nvim_get_current_buf()
    schedule_light_render(bufnr, 20)
end

local function on_cursor_hold(args)
    local bufnr = (args and args.buf) or api.nvim_get_current_buf()
    schedule_light_render(bufnr, 40)
end

M.init = function()
    local group = api.nvim_create_augroup("LvimDependencies", { clear = true })

    api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
        group = group,
        pattern = const.MANIFEST_PATTERNS,
        callback = on_buf_enter,
    })

    api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = const.MANIFEST_PATTERNS,
        callback = on_buf_write,
    })

    api.nvim_create_autocmd("BufReadPost", {
        group = group,
        pattern = const.MANIFEST_PATTERNS,
        callback = on_buf_read,
    })

    api.nvim_create_autocmd({ "WinScrolled" }, {
        group = group,
        pattern = const.MANIFEST_PATTERNS,
        callback = on_win_scrolled,
    })

    api.nvim_create_autocmd({ "CursorHold" }, {
        group = group,
        pattern = const.MANIFEST_PATTERNS,
        callback = on_cursor_hold,
    })
end

return M
