local api = vim.api

local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local state = require("lvim-dependencies.state")
local check_manifests = require("lvim-dependencies.actions.check_manifests")
local virtual_text = require("lvim-dependencies.ui.virtual_text")
local pubspec_parser = require("lvim-dependencies.parsers.pubspec")

local L = vim.log.levels

local M = {}

local function urlencode(str)
    if not str then
        return ""
    end
    str = tostring(str)
    return (str:gsub("[^%w%-._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function find_pubspec_path()
    local manifest_files = const.MANIFEST_FILES.pubspec or { "pubspec.yaml" }
    local cwd = vim.fn.getcwd()
    local found = vim.fs.find(manifest_files, { upward = true, path = cwd, type = "file" })
    return found and found[1] or nil
end

local function read_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil
    end
    return lines
end

local function write_lines(path, lines)
    local ok, res = pcall(vim.fn.writefile, lines, path)
    if not ok then
        return false, tostring(res)
    end
    if res ~= 0 then
        return false, "writefile failed (code=" .. tostring(res) .. ")"
    end
    return true
end

local function apply_buffer_change(path, change)
    if not change then
        return
    end
    local bufnr = vim.fn.bufnr(path)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return
    end

    local cur_buf = api.nvim_get_current_buf()
    local cur_win = api.nvim_get_current_win()
    local saved_cursor = nil

    if cur_buf == bufnr then
        saved_cursor = api.nvim_win_get_cursor(cur_win)
    end

    local start0 = change.start0 or 0
    local end0 = change.end0 or 0
    local replacement = change.lines or {}

    api.nvim_buf_set_lines(bufnr, start0, end0, false, replacement)

    if saved_cursor then
        local row = saved_cursor[1]
        if start0 < row - 1 then
            local removed = end0 - start0
            local added = #replacement
            local delta = added - removed
            row = math.max(1, row + delta)
        end
        api.nvim_win_set_cursor(cur_win, { row, saved_cursor[2] })
    end

    vim.bo[bufnr].modified = false
end

local function force_refresh_buffer(path, fresh_lines)
    local bufnr = vim.fn.bufnr(path)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return
    end

    local cur_buf = api.nvim_get_current_buf()
    local cur_win = api.nvim_get_current_win()
    local saved_cursor = nil

    if cur_buf == bufnr then
        saved_cursor = api.nvim_win_get_cursor(cur_win)
    end

    api.nvim_buf_set_lines(bufnr, 0, -1, false, fresh_lines)

    if saved_cursor then
        api.nvim_win_set_cursor(cur_win, saved_cursor)
    end

    vim.bo[bufnr].modified = false
end

local function find_section_index(lines, section_name)
    for i, ln in ipairs(lines) do
        if ln:match("^%s*" .. vim.pesc(section_name) .. "%s*:") then
            return i
        end
    end
    return nil
end

local function find_section_end(lines, section_idx)
    local section_end = #lines
    for i = section_idx + 1, #lines do
        local ln = lines[i]
        if ln:match("^%S") then
            section_end = i - 1
            break
        end
    end
    return section_end
end

local function find_package_lnum_in_section(buf_lines, scope, pkg_name)
    if type(buf_lines) ~= "table" or not scope or scope == "" or not pkg_name or pkg_name == "" then
        return nil
    end

    local section_idx = find_section_index(buf_lines, scope)
    if not section_idx then
        return nil
    end
    local section_end = find_section_end(buf_lines, section_idx)

    for i = section_idx + 1, section_end do
        local ln = buf_lines[i]
        local m = ln and ln:match("^%s*([%w_%-%.]+)%s*:")
        if m == pkg_name then
            return i
        end
    end

    return nil
end

local function find_package_block(lines, section_idx, section_end, pkg_name)
    for i = section_idx + 1, section_end do
        local ln = lines[i]
        local m_name = ln:match("^%s*([%w%-%_%.]+)%s*:")
        if m_name and tostring(m_name) == tostring(pkg_name) then
            local pkg_indent = ln:match("^(%s*)") or ""
            local pkg_indent_len = #pkg_indent
            local block_end = i
            for j = i + 1, section_end do
                local next_ln = lines[j]
                if not next_ln then
                    break
                end
                if next_ln:match("^%S") then
                    break
                end
                local next_indent = next_ln:match("^(%s*)") or ""
                if #next_indent > pkg_indent_len then
                    block_end = j
                else
                    break
                end
            end
            return i, block_end, ln
        end
    end
    return nil, nil, nil
end

local function replace_package_in_section(lines, section_idx, section_end, pkg_name, new_line)
    local i, block_end = find_package_block(lines, section_idx, section_end, pkg_name)
    if not i then
        return nil, false, nil
    end

    local out = {}
    for k = 1, i - 1 do
        out[#out + 1] = lines[k]
    end
    out[#out + 1] = new_line
    for k = block_end + 1, #lines do
        out[#out + 1] = lines[k]
    end

    local change = { start0 = i - 1, end0 = block_end, lines = { new_line } }
    return out, true, change
end

local function insert_package_in_section(lines, section_idx, new_line)
    local out = {}
    for k = 1, section_idx do
        out[#out + 1] = lines[k]
    end
    out[#out + 1] = new_line
    for k = section_idx + 1, #lines do
        out[#out + 1] = lines[k]
    end

    local insert_at = section_idx + 1
    local change = { start0 = insert_at - 1, end0 = insert_at - 1, lines = { new_line } }
    return out, true, change
end

local function remove_package_from_section(lines, section_idx, section_end, pkg_name)
    local i, block_end = find_package_block(lines, section_idx, section_end, pkg_name)
    if not i then
        return nil, nil
    end

    local out = {}
    for k = 1, i - 1 do
        out[#out + 1] = lines[k]
    end
    for k = block_end + 1, #lines do
        out[#out + 1] = lines[k]
    end

    local change = { start0 = i - 1, end0 = block_end, lines = {} }
    return out, change
end

local function apply_single_line_version_edit(bufnr, lnum1, dep_name, new_version)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_loaded(bufnr) then
        return false
    end
    if type(lnum1) ~= "number" or lnum1 < 1 then
        return false
    end
    if not dep_name or dep_name == "" then
        return false
    end
    if not new_version or new_version == "" then
        return false
    end

    local line = api.nvim_buf_get_lines(bufnr, lnum1 - 1, lnum1, false)[1]
    if not line then
        return false
    end

    local m = line:match("^%s*([%w_%-%.]+)%s*:")
    if m ~= dep_name then
        return false
    end

    local colon = line:find(":", 1, true)
    if not colon then
        return false
    end
    local start_col = colon
    while start_col < #line and line:sub(start_col + 1, start_col + 1):match("%s") do
        start_col = start_col + 1
    end
    start_col = start_col + 1

    local hash = line:find("#", start_col, true)
    local end_col = hash and (hash - 1) or #line

    while end_col > start_col and line:sub(end_col, end_col):match("%s") do
        end_col = end_col - 1
    end

    local start0 = start_col - 1
    local end0 = end_col

    api.nvim_buf_set_text(bufnr, lnum1 - 1, start0, lnum1 - 1, end0, { tostring(new_version) })
    vim.bo[bufnr].modified = false
    return true
end

local function trigger_package_updated()
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function ensure_deps_namespace()
    state.namespace = state.namespace or {}
    state.namespace.id = state.namespace.id or api.nvim_create_namespace("lvim_dependencies")
    return state.namespace.id
end

local function set_pending_anchor(bufnr, lnum1)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    if type(lnum1) ~= "number" or lnum1 < 1 then
        return nil
    end
    local ns = ensure_deps_namespace()
    local id = api.nvim_buf_set_extmark(bufnr, ns, lnum1 - 1, 0, {
        right_gravity = false,
    })
    return id
end

local function clear_pending_anchor(bufnr)
    if not (bufnr and bufnr ~= -1) then
        return
    end
    local rec = state.buffers and state.buffers[bufnr]
    if not rec or not rec.pending_anchor_id then
        return
    end
    local ns = ensure_deps_namespace()
    api.nvim_buf_del_extmark(bufnr, ns, rec.pending_anchor_id)
    rec.pending_anchor_id = nil
end

local function clear_all_caches()
    utils.clear_file_cache()
    pubspec_parser.clear_lock_cache()
end

local function parse_pubspec_state(path)
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
        pubspec_parser.parse_buffer(buf)
    elseif pubspec_parser.parse_file then
        pubspec_parser.parse_file(path)
    end
end

local function choose_pub_get_cmd(pubspec_path)
    local lines = read_lines(pubspec_path)
    local has_flutter = false
    if lines then
        for _, l in ipairs(lines) do
            if l:match("^%s*flutter%s*:") then
                has_flutter = true
                break
            end
        end
    end

    if has_flutter and vim.fn.executable("flutter") == 1 then
        return { "flutter", "pub", "get" }
    end
    if vim.fn.executable("dart") == 1 then
        return { "dart", "pub", "get" }
    end
    return nil
end

local function choose_pub_remove_cmd(pubspec_path, name)
    local lines = read_lines(pubspec_path)
    local has_flutter = false
    if lines then
        for _, l in ipairs(lines) do
            if l:match("^%s*flutter%s*:") then
                has_flutter = true
                break
            end
        end
    end

    if has_flutter and vim.fn.executable("flutter") == 1 then
        return { "flutter", "pub", "remove", name }
    end
    if vim.fn.executable("dart") == 1 then
        return { "dart", "pub", "remove", name }
    end
    return nil
end

local function run_recovery_pub_get(cmd, cwd, cb)
    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            if cb then
                cb(res and res.code == 0, res)
            end
        end)
    end)
end

function M.fetch_versions(name, _)
    if not name or name == "" then
        return nil
    end

    local current = state.get_installed_version("pubspec", name)

    local pkg = urlencode(name)
    local url = ("https://pub.dev/api/packages/%s"):format(pkg)

    local res = vim.system({ "curl", "-fsS", "--max-time", "10", url }, { text = true }):wait()
    if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
        return nil
    end

    local ok, parsed = pcall(vim.json.decode, res.stdout)
    if not ok or type(parsed) ~= "table" then
        return nil
    end

    local raw_versions = parsed.versions
    if not raw_versions or type(raw_versions) ~= "table" then
        return nil
    end

    local seen, uniq = {}, {}
    for _, v in ipairs(raw_versions) do
        local ver = nil
        local is_retracted = false

        if type(v) == "table" then
            ver = v.version and tostring(v.version)
            is_retracted = v.retracted == true
        elseif type(v) == "string" then
            ver = tostring(v)
        end

        if ver and not seen[ver] and not is_retracted then
            seen[ver] = true
            uniq[#uniq + 1] = ver
        end
    end

    table.sort(uniq, function(a, b)
        return a > b
    end)

    return { versions = uniq, current = current }
end

local function run_pub_get(path, name, version, scope, on_success_msg, opts)
    opts = opts or {}
    local pending_lines = opts.pending_lines
    local change = opts.change
    local original_lines = opts.original_lines
    local pending_lnum = opts.pending_lnum

    local cmd = choose_pub_get_cmd(path)
    if not cmd then
        utils.notify_safe("pubspec: neither flutter nor dart CLI available", L.ERROR, {})
        return
    end

    local cwd = vim.fn.fnamemodify(path, ":h")

    state.set_updating(true)

    if pending_lines then
        local ok_write, werr = write_lines(path, pending_lines)
        if not ok_write then
            utils.notify_safe("pubspec: failed to write pubspec.yaml: " .. tostring(werr), L.ERROR, {})
            state.set_updating(false)
            return
        end
    end

    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            local bufnr = vim.fn.bufnr(path)

            if res and res.code == 0 then
                clear_all_caches()

                local applied = false
                if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) and type(pending_lnum) == "number" then
                    applied = apply_single_line_version_edit(bufnr, pending_lnum, name, version)
                end

                if not applied and pending_lines then
                    if change then
                        apply_buffer_change(path, change)
                    else
                        force_refresh_buffer(path, pending_lines)
                    end
                end

                utils.notify_safe(
                    on_success_msg or ("pubspec: %s@%s installed"):format(name, tostring(version)),
                    L.INFO,
                    {}
                )

                clear_all_caches()

                if name and version then
                    local deps = state.get_dependencies("pubspec")
                    if deps then
                        deps.installed = deps.installed or {}
                        deps.installed[name] = { current = version, in_lock = true }
                        state.set_installed("pubspec", deps.installed)
                    end
                    state.add_installed_dependency("pubspec", name, version, scope)
                end

                state.set_updating(false)

                if bufnr and bufnr ~= -1 then
                    state.buffers = state.buffers or {}
                    state.buffers[bufnr] = state.buffers[bufnr] or {}
                    state.buffers[bufnr].last_pubspec_hash = nil
                    state.buffers[bufnr].last_changedtick = nil
                    state.buffers[bufnr].last_pubspec_parsed = nil
                end

                vim.defer_fn(function()
                    clear_all_caches()

                    if bufnr and bufnr ~= -1 then
                        state.buffers = state.buffers or {}
                        state.buffers[bufnr] = state.buffers[bufnr] or {}
                        state.buffers[bufnr].is_loading = false
                        state.buffers[bufnr].pending_dep = nil
                        state.buffers[bufnr].checking_single_package = name
                    end

                    check_manifests.invalidate_package_cache(bufnr, "pubspec", name)
                    check_manifests.check_manifest_outdated(bufnr, "pubspec")
                end, 300)

                local poll_count = 0
                local max_polls = 30
                local function poll_for_outdated()
                    poll_count = poll_count + 1

                    local deps = state.get_dependencies("pubspec")
                    local outdated = deps and deps.outdated
                    local pkg_outdated = outdated and outdated[name]
                    local has_fresh_data = pkg_outdated and pkg_outdated.latest ~= nil

                    if has_fresh_data or poll_count >= max_polls then
                        if bufnr and bufnr ~= -1 then
                            state.buffers = state.buffers or {}
                            state.buffers[bufnr] = state.buffers[bufnr] or {}
                            clear_pending_anchor(bufnr)

                            state.buffers[bufnr].is_loading = false
                            state.buffers[bufnr].pending_dep = nil
                            state.buffers[bufnr].pending_lnum = nil
                            state.buffers[bufnr].pending_scope = nil
                            state.buffers[bufnr].checking_single_package = nil

                            state.buffers[bufnr].last_update_completed_at = vim.loop.now()
                        end

                        virtual_text.display(bufnr, "pubspec", { force_full = true })
                    else
                        vim.defer_fn(poll_for_outdated, 200)
                    end
                end

                vim.defer_fn(poll_for_outdated, 500)

                vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
                trigger_package_updated()
                return
            end

            if original_lines then
                write_lines(path, original_lines)
            end

            if original_lines and bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
                force_refresh_buffer(path, original_lines)
            end

            run_recovery_pub_get(cmd, cwd, function(_, _)
                clear_all_caches()
                parse_pubspec_state(path)
            end)

            state.set_updating(false)

            local msg = (res and res.stderr) or ""
            if msg == "" then
                msg = "pub get exited with code " .. tostring(res and res.code or "unknown")
            end
            utils.notify_safe(("pubspec: pub get failed. Error: %s"):format(msg), L.ERROR, {})

            if bufnr and bufnr ~= -1 then
                state.buffers = state.buffers or {}
                state.buffers[bufnr] = state.buffers[bufnr] or {}
                clear_pending_anchor(bufnr)

                state.buffers[bufnr].is_loading = false
                state.buffers[bufnr].pending_dep = nil
                state.buffers[bufnr].pending_lnum = nil
                state.buffers[bufnr].pending_scope = nil
                state.buffers[bufnr].checking_single_package = nil
            end

            virtual_text.display(bufnr, "pubspec", { force_full = true })
        end)
    end)
end

local function run_pub_remove(path, name)
    local cmd = choose_pub_remove_cmd(path, name)
    if not cmd then
        utils.notify_safe("pubspec: neither flutter nor dart CLI available", L.ERROR, {})
        return
    end
    local cwd = vim.fn.fnamemodify(path, ":h")

    state.set_updating(true)

    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            local bufnr = vim.fn.bufnr(path)

            if res and res.code == 0 then
                clear_all_caches()

                utils.notify_safe(("pubspec: %s removed"):format(name), L.INFO, {})

                local path_lines = read_lines(path)
                if path_lines then
                    force_refresh_buffer(path, path_lines)
                end

                state.remove_installed_dependency("pubspec", name)

                if bufnr and bufnr ~= -1 then
                    state.buffers = state.buffers or {}
                    state.buffers[bufnr] = state.buffers[bufnr] or {}
                    state.buffers[bufnr].last_pubspec_hash = nil
                    state.buffers[bufnr].last_changedtick = nil
                    state.buffers[bufnr].last_pubspec_parsed = nil
                    state.buffers[bufnr].last_update_completed_at = vim.loop.now()
                end

                vim.defer_fn(function()
                    clear_all_caches()
                    parse_pubspec_state(path)

                    local buf = vim.fn.bufnr(path)
                    if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
                        vim.defer_fn(function()
                            check_manifests.invalidate_package_cache(buf, "pubspec", name)
                            check_manifests.check_manifest_outdated(buf, "pubspec")
                        end, 300)
                    end
                end, 600)

                state.set_updating(false)

                vim.g.lvim_deps_last_updated = name .. "@removed"
                trigger_package_updated()
            else
                state.set_updating(false)

                local msg = (res and res.stderr) or ""
                if msg == "" then
                    msg = "pub remove exited with code " .. tostring(res and res.code or "unknown")
                end
                utils.notify_safe(("pubspec: pub remove failed. Error: %s"):format(msg), L.ERROR, {})
            end
        end)
    end)
end

function M.update(name, opts)
    if not name or name == "" then
        return { ok = false, msg = "package name required" }
    end
    opts = opts or {}
    local version = opts.version
    if not version or version == "" then
        return { ok = false, msg = "version is required" }
    end

    local scope = opts.scope or "dependencies"
    local valid_scopes = const.SECTION_NAMES.pubspec or { "dependencies", "dev_dependencies" }
    local scope_valid = false
    for _, s in ipairs(valid_scopes) do
        if scope == s then
            scope_valid = true
            break
        end
    end
    if not scope_valid then
        scope = "dependencies"
    end

    local bufname = api.nvim_buf_get_name(0)
    local path = nil
    if bufname ~= "" and bufname:match("pubspec%.ya?ml$") then
        path = bufname
    else
        path = find_pubspec_path()
    end
    if not path then
        return { ok = false, msg = "pubspec.yaml not found in project tree" }
    end

    local disk_lines = read_lines(path)
    if not disk_lines then
        return { ok = false, msg = "unable to read pubspec.yaml from disk" }
    end
    local original_lines = vim.deepcopy(disk_lines)

    local section_idx = find_section_index(disk_lines, scope)
    if not section_idx then
        disk_lines[#disk_lines + 1] = ""
        disk_lines[#disk_lines + 1] = scope .. ":"
        section_idx = #disk_lines - 1
    end

    local section_end = find_section_end(disk_lines, section_idx)

    local pkg_indent = "  "
    local sample_ln = disk_lines[section_idx + 1]
    if sample_ln then
        local s_indent = sample_ln:match("^(%s*)") or ""
        if #s_indent > 0 then
            pkg_indent = s_indent
        end
    end
    local new_line = string.format("%s%s: %s", pkg_indent, name, tostring(version))

    local new_lines, replaced, change = replace_package_in_section(disk_lines, section_idx, section_end, name, new_line)
    if not replaced then
        new_lines, _, change = insert_package_in_section(disk_lines, section_idx, new_line)
    end

    if opts.from_ui then
        local bufnr = vim.fn.bufnr(path)

        local pending_lnum = nil
        if bufnr and bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
            local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
            pending_lnum = find_package_lnum_in_section(buf_lines, scope, name)
        end

        if bufnr and bufnr ~= -1 then
            state.buffers = state.buffers or {}
            state.buffers[bufnr] = state.buffers[bufnr] or {}

            state.buffers[bufnr].is_loading = true
            state.buffers[bufnr].pending_dep = name
            state.buffers[bufnr].pending_lnum = pending_lnum
            state.buffers[bufnr].pending_scope = scope

            clear_pending_anchor(bufnr)
            if pending_lnum then
                state.buffers[bufnr].pending_anchor_id = set_pending_anchor(bufnr, pending_lnum)
            end

            if pending_lnum then
                apply_single_line_version_edit(bufnr, pending_lnum, name, version)
            end

            local ns = ensure_deps_namespace()
            if pending_lnum then
                local marks = api.nvim_buf_get_extmarks(
                    bufnr,
                    ns,
                    { pending_lnum - 1, 0 },
                    { pending_lnum - 1, -1 },
                    {}
                )
                for _, mark in ipairs(marks) do
                    api.nvim_buf_del_extmark(bufnr, ns, mark[1])
                end

                api.nvim_buf_set_extmark(bufnr, ns, pending_lnum - 1, 0, {
                    virt_text = { { "Loading...", "LvimDepsLoading" } },
                    virt_text_pos = "eol",
                    priority = 1000,
                })
            end

            vim.cmd("redraw")
        end

        utils.notify_safe(("pubspec: installing %s %s..."):format(name, tostring(version)), L.INFO, {})

        run_pub_get(path, name, version, scope, nil, {
            pending_lines = new_lines,
            change = change,
            original_lines = original_lines,
            pending_lnum = pending_lnum,
        })
        return { ok = true, msg = "started" }
    end

    local okw, werr = write_lines(path, new_lines)
    if not okw then
        return { ok = false, msg = "failed to write pubspec.yaml: " .. tostring(werr) }
    end

    apply_buffer_change(path, change)
    force_refresh_buffer(path, new_lines)

    state.add_installed_dependency("pubspec", name, version, scope)

    vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
    trigger_package_updated()

    utils.notify_safe(("pubspec: %s -> %s"):format(name, tostring(version)), L.INFO, {})

    return { ok = true, msg = "written" }
end

function M.add(_, _)
    return { ok = true }
end

function M.delete(name, opts)
    if not name or name == "" then
        return { ok = false, msg = "package name required" }
    end
    opts = opts or {}

    local scope = opts.scope or "dependencies"
    local valid_scopes = const.SECTION_NAMES.pubspec or { "dependencies", "dev_dependencies" }
    local scope_valid = false
    for _, s in ipairs(valid_scopes) do
        if scope == s then
            scope_valid = true
            break
        end
    end
    if not scope_valid then
        scope = "dependencies"
    end

    local path = find_pubspec_path()
    if not path then
        return { ok = false, msg = "pubspec.yaml not found in project tree" }
    end

    if opts.from_ui then
        run_pub_remove(path, name)
        utils.notify_safe(("pubspec: removing %s..."):format(name), L.INFO, {})
        return { ok = true, msg = "started" }
    end

    local lines = read_lines(path)
    if not lines then
        return { ok = false, msg = "unable to read pubspec.yaml from disk" }
    end

    local section_idx = find_section_index(lines, scope)
    if not section_idx then
        return { ok = false, msg = "section " .. scope .. " not found" }
    end

    local section_end = find_section_end(lines, section_idx)
    local new_lines = remove_package_from_section(lines, section_idx, section_end, name)
    if not new_lines then
        return { ok = false, msg = "package " .. name .. " not found in " .. scope }
    end

    local okw, werr = write_lines(path, new_lines)
    if not okw then
        return { ok = false, msg = "failed to write pubspec.yaml: " .. tostring(werr) }
    end

    force_refresh_buffer(path, new_lines)

    state.remove_installed_dependency("pubspec", name)

    vim.g.lvim_deps_last_updated = name .. "@removed"
    trigger_package_updated()

    utils.notify_safe(("pubspec: %s removed"):format(name), L.INFO, {})

    return { ok = true, msg = "removed" }
end

function M.install(_)
    return { ok = true }
end

function M.check_outdated(_)
    return { ok = true }
end

return M
