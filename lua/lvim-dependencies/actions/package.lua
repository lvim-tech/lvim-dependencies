local api = vim.api

local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local state = require("lvim-dependencies.state")
local check_manifests = require("lvim-dependencies.actions.check_manifests")
local virtual_text = require("lvim-dependencies.ui.virtual_text")
local package_parser = require("lvim-dependencies.parsers.package")

local L = vim.log.levels

local M = {}

local function urlencode(str)
    if not str then
        return ""
    end
    str = tostring(str)
    return (str:gsub("[^%w%-._~@/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function find_package_json_path()
    local manifest_files = const.MANIFEST_FILES.package or { "package.json" }
    local cwd = vim.fn.getcwd()
    local found = vim.fs.find(manifest_files, { upward = true, path = cwd, type = "file" })
    return found and found[1] or nil
end

local function read_json(path)
    local ok, content = pcall(vim.fn.readfile, path)
    if not ok or type(content) ~= "table" then
        return nil
    end
    local text = table.concat(content, "\n")
    local ok_json, data = pcall(vim.json.decode, text)
    if not ok_json or type(data) ~= "table" then
        return nil
    end
    return data
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

local function get_installed_version_from_node_modules(name)
    local cwd = vim.fn.getcwd()
    local pkg_path = cwd .. "/node_modules/" .. name .. "/package.json"

    if vim.fn.filereadable(pkg_path) ~= 1 then
        return nil
    end

    local data = read_json(pkg_path)
    if data and data.version then
        return tostring(data.version)
    end

    return nil
end

local function parse_semver(v)
    if not v then
        return nil
    end
    v = tostring(v)
    v = v:gsub("^%s*", ""):gsub("%s*$", "")
    v = v:gsub("^v", "")
    v = v:gsub("^[%^~><=]+", "")
    v = v:gsub("%+.*$", "")

    local major, minor, patch, pre = v:match("^(%d+)%.(%d+)%.(%d+)%-(.+)$")
    if not major then
        major, minor, patch = v:match("^(%d+)%.(%d+)%.(%d+)$")
    end
    if major then
        return { major = tonumber(major) or 0, minor = tonumber(minor) or 0, patch = tonumber(patch) or 0, pre = pre }
    end

    local ma, mi = v:match("^(%d+)%.(%d+)$")
    if ma then
        return { major = tonumber(ma) or 0, minor = tonumber(mi) or 0, patch = 0, pre = nil }
    end
    local m1 = v:match("^(%d+)$")
    if m1 then
        return { major = tonumber(m1) or 0, minor = 0, patch = 0, pre = nil }
    end

    return nil
end

local function split_pre(pre)
    if not pre or pre == "" then
        return {}
    end
    return vim.split(pre, ".", { plain = true })
end

local function cmp_ident(a, b)
    local na = tonumber(a)
    local nb = tonumber(b)
    if na and nb then
        if na == nb then
            return 0
        end
        return na < nb and -1 or 1
    end
    if na and not nb then
        return -1
    end
    if not na and nb then
        return 1
    end
    if a == b then
        return 0
    end
    return a < b and -1 or 1
end

local function compare_semver(a, b)
    if not a and not b then
        return 0
    end
    if not a then
        return -1
    end
    if not b then
        return 1
    end

    if a.major ~= b.major then
        return a.major < b.major and -1 or 1
    end
    if a.minor ~= b.minor then
        return a.minor < b.minor and -1 or 1
    end
    if a.patch ~= b.patch then
        return a.patch < b.patch and -1 or 1
    end

    if not a.pre and not b.pre then
        return 0
    end
    if not a.pre and b.pre then
        return 1
    end
    if a.pre and not b.pre then
        return -1
    end

    local ap = split_pre(a.pre)
    local bp = split_pre(b.pre)
    local n = math.max(#ap, #bp)
    for i = 1, n do
        local ai = ap[i]
        local bi = bp[i]
        if ai == nil and bi == nil then
            return 0
        end
        if ai == nil then
            return -1
        end
        if bi == nil then
            return 1
        end
        local c = cmp_ident(ai, bi)
        if c ~= 0 then
            return c
        end
    end
    return 0
end

local function sort_versions_desc(versions)
    table.sort(versions, function(a, b)
        local pa = parse_semver(a)
        local pb = parse_semver(b)
        local cmp = compare_semver(pa, pb)
        if cmp == 0 then
            return tostring(a) > tostring(b)
        end
        return cmp == 1
    end)
end

local function curl_get_json(url)
    local res = vim.system({ "curl", "-fsS", "--max-time", "10", url }, { text = true }):wait()
    if not res or res.code ~= 0 or not res.stdout or res.stdout == "" then
        return nil
    end
    local ok, parsed = pcall(vim.json.decode, res.stdout)
    if not ok or type(parsed) ~= "table" then
        return nil
    end
    return parsed
end

local function trigger_package_updated()
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function clear_all_caches()
    utils.clear_file_cache()
    package_parser.clear_lock_cache()
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

function M.fetch_versions(name, _)
    if not name or name == "" then
        return nil
    end

    local current = get_installed_version_from_node_modules(name)

    if not current then
        current = state.get_installed_version("package", name)
    end

    local encoded_name = urlencode(name)

    local parsed = curl_get_json(("https://registry.npmjs.org/%s?fields=versions"):format(encoded_name))
    if not parsed or type(parsed.versions) ~= "table" then
        parsed = curl_get_json(("https://registry.npmjs.org/%s"):format(encoded_name))
    end
    if not parsed or type(parsed.versions) ~= "table" then
        return nil
    end

    local uniq = {}
    for ver, _ in pairs(parsed.versions) do
        if type(ver) == "string" then
            uniq[#uniq + 1] = ver
        end
    end
    if #uniq == 0 then
        return nil
    end

    sort_versions_desc(uniq)
    return { versions = uniq, current = current }
end

local function find_section_index(lines, section_name)
    local patt = '^%s*"' .. vim.pesc(section_name) .. '"%s*:%s*{'
    for i, ln in ipairs(lines) do
        if ln:match(patt) then
            return i
        end
    end
    return nil
end

local function find_section_end(lines, section_idx)
    local depth = 0
    local started = false
    for i = section_idx, #lines do
        local ln = lines[i]
        local open_count = select(2, ln:gsub("{", ""))
        local close_count = select(2, ln:gsub("}", ""))
        if open_count > 0 then
            started = true
        end
        depth = depth + open_count - close_count
        if started and depth == 0 then
            return i
        end
    end
    return #lines
end

local function find_entry_indent(lines, section_idx, section_end)
    for i = section_idx + 1, section_end - 1 do
        local ln = lines[i]
        if ln:match('^%s*".-"%s*:') then
            return ln:match("^(%s*)") or "    "
        end
    end
    local section_indent = lines[section_idx]:match("^(%s*)") or ""
    return section_indent .. "    "
end

local function find_last_entry_index(lines, section_idx, section_end)
    local last = nil
    for i = section_idx + 1, section_end - 1 do
        local ln = lines[i]
        if ln:match('^%s*".-"%s*:') then
            last = i
        end
    end
    return last
end

local function ensure_trailing_comma(line)
    if line:match(",%s*$") then
        return line
    end
    return line:gsub("%s*$", ",")
end

local function remove_trailing_comma(line)
    return line:gsub(",%s*$", "")
end

local function find_package_line(lines, section_idx, section_end, pkg_name)
    for i = section_idx + 1, section_end - 1 do
        local ln = lines[i]
        local m_name = ln:match('^%s*"(.-)"%s*:')
        if m_name and tostring(m_name) == tostring(pkg_name) then
            return i, ln
        end
    end
    return nil, nil
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

    for i = section_idx + 1, section_end - 1 do
        local ln = buf_lines[i]
        local m = ln and ln:match('^%s*"(.-)"%s*:')
        if m == pkg_name then
            return i
        end
    end

    return nil
end

local function replace_package_in_section(lines, section_idx, section_end, pkg_name, version_spec)
    local i, ln = find_package_line(lines, section_idx, section_end, pkg_name)
    if not i or not ln then
        return nil, false, nil
    end

    local indent = ln:match("^(%s*)") or ""
    local has_comma = ln:match(",%s*$") ~= nil
    local new_line = indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"'
    if has_comma then
        new_line = new_line .. ","
    end

    local out = {}
    for k = 1, i - 1 do
        out[#out + 1] = lines[k]
    end
    out[#out + 1] = new_line
    for k = i + 1, #lines do
        out[#out + 1] = lines[k]
    end

    local change = { start0 = i - 1, end0 = i, lines = { new_line } }
    return out, true, change
end

local function insert_package_in_section(lines, section_idx, section_end, pkg_name, version_spec)
    local indent = find_entry_indent(lines, section_idx, section_end)
    local new_line = indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"'

    local last_idx = find_last_entry_index(lines, section_idx, section_end)
    if last_idx then
        lines[last_idx] = ensure_trailing_comma(lines[last_idx])
    end

    local out = {}
    for k = 1, section_end - 1 do
        out[#out + 1] = lines[k]
    end
    out[#out + 1] = new_line
    for k = section_end, #lines do
        out[#out + 1] = lines[k]
    end

    local change = { start0 = section_end - 1, end0 = section_end - 1, lines = { new_line } }
    return out, true, change
end

local function remove_package_from_section(lines, section_idx, section_end, pkg_name)
    local target_idx = nil
    for i = section_idx + 1, section_end - 1 do
        local ln = lines[i]
        local m_name = ln:match('^%s*"(.-)"%s*:')
        if m_name and tostring(m_name) == tostring(pkg_name) then
            target_idx = i
            break
        end
    end
    if not target_idx then
        return nil, nil
    end

    local out = {}
    for k = 1, target_idx - 1 do
        out[#out + 1] = lines[k]
    end
    for k = target_idx + 1, #lines do
        out[#out + 1] = lines[k]
    end

    local new_section_end = find_section_end(out, section_idx)
    local prev_idx = find_last_entry_index(out, section_idx, new_section_end)
    if prev_idx and prev_idx < new_section_end - 1 then
        local next_idx = nil
        for i = prev_idx + 1, new_section_end - 1 do
            if out[i]:match('^%s*".-"%s*:') then
                next_idx = i
                break
            end
        end
        if not next_idx then
            out[prev_idx] = remove_trailing_comma(out[prev_idx])
        end
    end

    local change = { start0 = target_idx - 1, end0 = target_idx, lines = {} }
    return out, change
end

local function find_root_end(lines)
    for i = #lines, 1, -1 do
        if lines[i]:match("^%s*}%s*,?%s*$") then
            return i
        end
    end
    return #lines
end

local function find_top_level_indent(lines)
    for _, ln in ipairs(lines) do
        if ln:match('^%s*".-"%s*:') then
            return ln:match("^(%s*)") or "    "
        end
    end
    return "    "
end

local function find_last_top_level_entry(lines, root_end)
    for i = root_end - 1, 1, -1 do
        if lines[i]:match('^%s*".-"%s*:') then
            return i
        end
    end
    return nil
end

local function add_section_with_package(lines, section_name, pkg_name, version_spec)
    local root_end = find_root_end(lines)
    local indent = find_top_level_indent(lines)
    local entry_indent = indent .. "    "

    local prev_idx = find_last_top_level_entry(lines, root_end)
    if prev_idx then
        lines[prev_idx] = ensure_trailing_comma(lines[prev_idx])
    end

    local out = {}
    for i = 1, root_end - 1 do
        out[#out + 1] = lines[i]
    end

    out[#out + 1] = indent .. '"' .. section_name .. '": {'
    out[#out + 1] = entry_indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"'
    out[#out + 1] = indent .. "}"

    for i = root_end, #lines do
        out[#out + 1] = lines[i]
    end

    local section_idx = root_end
    local section_end = root_end + 2
    local change = {
        start0 = section_idx - 1,
        end0 = section_idx - 1,
        lines = {
            indent .. '"' .. section_name .. '": {',
            entry_indent .. '"' .. pkg_name .. '": "' .. version_spec .. '"',
            indent .. "}",
        },
    }
    return out, section_idx, section_end, change
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

    local m = line:match('^%s*"(.-)"%s*:')
    if m ~= dep_name then
        return false
    end

    local colon_pos = line:find(":", 1, true)
    if not colon_pos then
        return false
    end

    local first_quote = line:find('"', colon_pos + 1, true)
    if not first_quote then
        return false
    end

    local second_quote = line:find('"', first_quote + 1, true)
    if not second_quote then
        return false
    end

    local start0 = first_quote
    local end0 = second_quote - 1

    local version_spec = "^" .. tostring(new_version)
    api.nvim_buf_set_text(bufnr, lnum1 - 1, start0, lnum1 - 1, end0, { version_spec })
    vim.bo[bufnr].modified = false
    return true
end

local function get_preferred_pm()
    if vim.fn.executable("pnpm") == 1 then
        return "pnpm"
    end
    if vim.fn.executable("yarn") == 1 then
        return "yarn"
    end
    if vim.fn.executable("npm") == 1 then
        return "npm"
    end
    return nil
end

local function pm_install_cmd(pm, pkg_spec, scope)
    local is_dev = (scope == "devDependencies")
    if pm == "pnpm" then
        if is_dev then
            return { "pnpm", "add", "-D", pkg_spec }
        end
        return { "pnpm", "add", pkg_spec }
    elseif pm == "yarn" then
        if is_dev then
            return { "yarn", "add", "-D", pkg_spec }
        end
        return { "yarn", "add", pkg_spec }
    else
        if is_dev then
            return { "npm", "install", "--save-dev", pkg_spec }
        end
        return { "npm", "install", "--save", pkg_spec }
    end
end

local function run_pm_install(path, name, version, scope, on_success_msg, opts)
    opts = opts or {}
    local pending_lines = opts.pending_lines
    local change = opts.change
    local original_lines = opts.original_lines
    local pending_lnum = opts.pending_lnum

    local pm = get_preferred_pm()
    if not pm then
        utils.notify_safe("package: npm/yarn/pnpm not found", L.ERROR, {})
        return
    end

    local cwd = vim.fn.fnamemodify(path, ":h")
    local pkg_spec = ("%s@%s"):format(name, tostring(version))
    local cmd = pm_install_cmd(pm, pkg_spec, scope)

    state.set_updating(true)

    if pending_lines then
        local ok_write, werr = write_lines(path, pending_lines)
        if not ok_write then
            utils.notify_safe("package: failed to write package.json: " .. tostring(werr), L.ERROR, {})
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
                    on_success_msg or ("package: %s@%s installed"):format(name, tostring(version)),
                    L.INFO,
                    {}
                )

                clear_all_caches()

                if name and version then
                    local deps = state.get_dependencies("package")
                    if deps then
                        deps.installed = deps.installed or {}
                        deps.installed[name] = { current = version, in_lock = true }
                        state.set_installed("package", deps.installed)
                    end
                    state.add_installed_dependency("package", name, version, scope)
                end

                state.set_updating(false)

                if bufnr and bufnr ~= -1 then
                    state.buffers = state.buffers or {}
                    state.buffers[bufnr] = state.buffers[bufnr] or {}
                    state.buffers[bufnr].last_package_hash = nil
                    state.buffers[bufnr].last_changedtick = nil
                    state.buffers[bufnr].last_package_parsed = nil
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

                    check_manifests.invalidate_package_cache(bufnr, "package", name)
                    check_manifests.check_manifest_outdated(bufnr, "package")
                end, 300)

                local poll_count = 0
                local max_polls = 30
                local function poll_for_outdated()
                    poll_count = poll_count + 1

                    local deps = state.get_dependencies("package")
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

                        virtual_text.display(bufnr, "package", { force_full = true })
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

            state.set_updating(false)

            local msg = (res and res.stderr) or ""
            if msg == "" then
                msg = table.concat(cmd, " ") .. " exited with code " .. tostring(res and res.code or "unknown")
            end
            utils.notify_safe(("package: install failed. Error: %s"):format(msg), L.ERROR, {})

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

            virtual_text.display(bufnr, "package", { force_full = true })
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
    local valid_scopes = const.SECTION_NAMES.package or { "dependencies", "devDependencies" }
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
    if bufname ~= "" and bufname:match("package%.json$") then
        path = bufname
    else
        path = find_package_json_path()
    end
    if not path then
        return { ok = false, msg = "package.json not found in project tree" }
    end

    local disk_lines = read_lines(path)
    if not disk_lines then
        return { ok = false, msg = "unable to read package.json from disk" }
    end
    local original_lines = vim.deepcopy(disk_lines)

    local version_spec = "^" .. tostring(version)
    local section_idx = find_section_index(disk_lines, scope)
    local section_end = nil
    local change = nil
    local new_lines = nil

    if not section_idx then
        new_lines, section_idx, section_end, change = add_section_with_package(disk_lines, scope, name, version_spec)
    else
        section_end = find_section_end(disk_lines, section_idx)
        local replaced = false
        new_lines, replaced, change =
            replace_package_in_section(disk_lines, section_idx, section_end, name, version_spec)
        if not replaced then
            new_lines, _, change = insert_package_in_section(disk_lines, section_idx, section_end, name, version_spec)
        end
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

        utils.notify_safe(("package: installing %s@%s..."):format(name, tostring(version)), L.INFO, {})

        run_pm_install(path, name, version, scope, nil, {
            pending_lines = new_lines,
            change = change,
            original_lines = original_lines,
            pending_lnum = pending_lnum,
        })
        return { ok = true, msg = "started" }
    end

    local okw, werr = write_lines(path, new_lines)
    if not okw then
        return { ok = false, msg = "failed to write package.json: " .. tostring(werr) }
    end

    apply_buffer_change(path, change)
    force_refresh_buffer(path, new_lines)

    state.add_installed_dependency("package", name, version, scope)

    vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
    trigger_package_updated()

    utils.notify_safe(("package: %s -> %s"):format(name, tostring(version)), L.INFO, {})

    return { ok = true, msg = "written" }
end

function M.remove(name, opts)
    opts = opts or {}

    if not name or name == "" then
        return { ok = false, msg = "package name required" }
    end

    local bufname = api.nvim_buf_get_name(0)
    local path = nil
    if bufname ~= "" and bufname:match("package%.json$") then
        path = bufname
    else
        path = find_package_json_path()
    end
    if not path then
        return { ok = false, msg = "package.json not found in project tree" }
    end

    local lines = read_lines(path)
    if not lines then
        return { ok = false, msg = "unable to read package.json from disk" }
    end

    local scope = opts.scope
    local all_sections = const.SECTION_NAMES.package or { "dependencies", "devDependencies" }
    local found_section = nil
    local section_idx, section_end

    if scope then
        section_idx = find_section_index(lines, scope)
        if section_idx then
            section_end = find_section_end(lines, section_idx)
            local i, _ = find_package_line(lines, section_idx, section_end, name)
            if i then
                found_section = scope
            end
        end
    end

    if not found_section then
        for _, sec in ipairs(all_sections) do
            section_idx = find_section_index(lines, sec)
            if section_idx then
                section_end = find_section_end(lines, section_idx)
                local i, _ = find_package_line(lines, section_idx, section_end, name)
                if i then
                    found_section = sec
                    break
                end
            end
        end
    end

    if not found_section then
        return { ok = false, msg = ("package '%s' not found in any section"):format(name) }
    end

    local new_lines, change = remove_package_from_section(lines, section_idx, section_end, name)
    if not new_lines then
        return { ok = false, msg = ("failed to remove '%s'"):format(name) }
    end

    local okw, werr = write_lines(path, new_lines)
    if not okw then
        return { ok = false, msg = "failed to write package.json: " .. tostring(werr) }
    end

    apply_buffer_change(path, change)
    force_refresh_buffer(path, new_lines)

    state.remove_installed_dependency("package", name)

    local bufnr = vim.fn.bufnr(path)
    if bufnr and bufnr ~= -1 then
        state.buffers = state.buffers or {}
        state.buffers[bufnr] = state.buffers[bufnr] or {}
        state.buffers[bufnr].last_update_completed_at = vim.loop.now()
    end

    utils.notify_safe(("package: removed %s from %s"):format(name, found_section), L.INFO, {})

    return { ok = true, msg = "removed" }
end

return M
