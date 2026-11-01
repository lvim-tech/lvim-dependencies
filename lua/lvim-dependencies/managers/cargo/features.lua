-- lvim-dependencies.managers.cargo.features: centralized feature management for cargo
-- dependencies. Fetches the available feature set for a crate from crates.io (cached +
-- in-flight deduped), reads the currently-declared features out of Cargo.toml, rewrites the
-- dependency line to the chosen features/flags, then invalidates every layer's cache and
-- refreshes the buffer's virtual text so the change shows immediately.
---@module "lvim-dependencies.managers.cargo.features"

local utils = require("lvim-dependencies.utils")
local parser = require("lvim-dependencies.managers.cargo.parser")
local file_ops = require("lvim-dependencies.managers.cargo.core.file_ops")
local toml_ops = require("lvim-dependencies.managers.cargo.core.toml_ops")
local helpers = require("lvim-dependencies.managers.cargo.utils.helpers")
local installed_data = require("lvim-dependencies.managers.cargo.data.installed")
local ui = require("lvim-dependencies.ui")
local http = require("lvim-dependencies.utils.http")
local config = require("lvim-dependencies.config")
local vt = require("lvim-dependencies.core.virtual_text")
local hub_declared = require("lvim-dependencies.core.hub.declared")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local package_loader = require("lvim-dependencies.core.package_loader")

local notify = utils.notify
local debug = utils.debug
local api = vim.api

---@class CargoFeatures
local M = {}

--- Per-crate available-feature cache (feature name list), keyed by crate name.
---@type table<string, string[]>
local features_cache = {}
--- Pending crates.io requests → their queued callbacks (in-flight dedup).
---@type table<string, fun(features: string[]|nil, err: string|nil)[]>
local in_flight = {}

-- ============================================================================
-- Feature parsing utilities
-- ============================================================================

--- Split the inside of an inline table into its entries, keeping each value's text as written.
---@param text string  starts just after the opening brace
---@return { key: string, value: string }[]|nil entries
---@return string|nil rest  what follows the closing brace
local function split_inline_table(text)
    local entries, start, depth, quote = {}, 1, 0, nil
    local function push(stop)
        local raw = vim.trim(text:sub(start, stop))
        if raw == "" then
            return true
        end
        local key, value = raw:match("^([^=%s]+)%s*=%s*(.-)$")
        if not key then
            return false
        end
        entries[#entries + 1] = { key = key, value = (value:gsub("%s*\n%s*", " ")) }
        return true
    end
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if quote then
            if c == "\\" and quote == '"' then
                i = i + 1
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "#" then
            return nil
        elseif c == "[" or c == "{" then
            depth = depth + 1
        elseif c == "}" and depth == 0 then
            if not push(i - 1) then
                return nil
            end
            return entries, vim.trim(text:sub(i + 1))
        elseif c == "]" or c == "}" then
            depth = depth - 1
        elseif c == "," and depth == 0 then
            if not push(i - 1) then
                return nil
            end
            start = i + 1
        end
        i = i + 1
    end
    return nil
end

--- What opts asks to change, as keys to set or (nil value) remove. Features already chosen stay
--- as written, whatever their order.
---@param value_of fun(keys: string[]): string|nil
---@param opts { features?: string[], default_features?: boolean, optional?: boolean }
---@return { keys: string[], value: string|nil }[]
local function feature_changes(value_of, opts)
    local changes = {}
    if opts.features then
        local wanted = vim.deepcopy(opts.features)
        table.sort(wanted)
        local have = {}
        for feature in (value_of({ "features" }) or ""):gmatch("[\"']([^\"']*)[\"']") do
            have[#have + 1] = feature
        end
        table.sort(have)
        if not vim.deep_equal(wanted, have) then
            changes[#changes + 1] = {
                keys = { "features" },
                value = #wanted > 0 and '["' .. table.concat(wanted, '", "') .. '"]' or nil,
            }
        end
    end
    if opts.default_features ~= nil then
        changes[#changes + 1] = {
            keys = { "default-features", "default_features" },
            value = (not opts.default_features) and "false" or nil,
        }
    end
    if opts.optional ~= nil then
        changes[#changes + 1] = { keys = { "optional" }, value = opts.optional and "true" or nil }
    end
    return changes
end

--- A `[section.pkg]` block with the same keys changed and every other line as written.
---@param block string[]
---@param opts { features?: string[], default_features?: boolean, optional?: boolean }
---@return string[]|nil
function M.edit_dependency_table(block, opts)
    local entries = toml_ops.table_entries(block)
    if not entries then
        return nil
    end
    return toml_ops.edit_table_block(
        block,
        feature_changes(function(keys)
            for _, entry in ipairs(entries) do
                if vim.tbl_contains(keys, entry.key) then
                    return entry.value
                end
            end
        end, opts)
    )
end

--- A dependency's lines with its features, default-features and optional keys set, and every
--- other key (path, git, package, registry, workspace, ...) kept as written. A nil option
--- leaves that key alone. Nil when the block is not something this can safely rewrite.
---@param block string[]
---@param opts { features?: string[], default_features?: boolean, optional?: boolean }
---@return string|nil line
function M.edit_dependency_block(block, opts)
    local indent, name, value = table.concat(block, "\n"):match("^(%s*)([^=]-)%s*=%s*(.*)$")
    if not name then
        return nil
    end

    local entries, rest
    if value:sub(1, 1) == "{" then
        entries, rest = split_inline_table(value:sub(2))
    else
        local version = value:match('^"[^"]*"') or value:match("^'[^']*'")
        if version then
            entries, rest = { { key = "version", value = version } }, vim.trim(value:sub(#version + 1))
        end
    end
    if not entries or (rest ~= "" and rest:sub(1, 1) ~= "#") then
        return nil
    end

    local function value_of(keys)
        for _, entry in ipairs(entries) do
            if vim.tbl_contains(keys, entry.key) then
                return entry.value
            end
        end
    end
    for _, change in ipairs(feature_changes(value_of, opts)) do
        local index
        for i, entry in ipairs(entries) do
            if vim.tbl_contains(change.keys, entry.key) then
                index = i
                break
            end
        end
        if not change.value then
            if index then
                table.remove(entries, index)
            end
        elseif index then
            entries[index].value = change.value
        else
            entries[#entries + 1] = { key = change.keys[1], value = change.value }
        end
    end

    local rendered
    if #entries == 1 and entries[1].key == "version" then
        rendered = entries[1].value
    else
        local parts = {}
        for _, entry in ipairs(entries) do
            parts[#parts + 1] = entry.key .. " = " .. entry.value
        end
        rendered = #parts > 0 and "{ " .. table.concat(parts, ", ") .. " }" or "{}"
    end
    return indent .. name .. " = " .. rendered .. (rest ~= "" and " " .. rest or "")
end

--- The manifest behind a buffer, else the current project's.
---@param bufnr? integer
---@return string|nil
local function manifest_path(bufnr)
    local name = bufnr and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_get_name(bufnr) or ""
    return vim.fs.basename(name) == "Cargo.toml" and name or file_ops.find_cargo_toml_path()
end

--- The entries of a declaration in either form, or nil when it cannot be read.
---@param block string[]
---@param form "inline"|"table"
---@return { key: string, value: string }[]|nil
local function declaration_entries(block, form)
    if form == "table" then
        return toml_ops.table_entries(block)
    end
    local value = table.concat(block, "\n"):match("^%s*[^=]-%s*=%s*(.*)$")
    if not value then
        return nil
    end
    if value:sub(1, 1) == "{" then
        return (split_inline_table(value:sub(2)))
    end
    local version = value:match('^"[^"]*"') or value:match("^'[^']*'")
    return version and { { key = "version", value = version } } or nil
end

--- The features of one declaration: the section under the cursor, else the first. The parser's
--- merged table cannot answer this, since a crate may be declared in several sections.
---@param package_name string
---@param bufnr? integer  the manifest's buffer; a picker may be the current one by then
---@param section? string
---@return {features: string[], default_features: boolean, optional: boolean, version: string|nil}
function M.get_current_features(package_name, bufnr, section)
    local result = { features = {}, default_features = true, optional = false, version = nil }
    local path = manifest_path(bufnr)
    local lines = path and file_ops.read_lines(path)
    section = section or (path and helpers.find_package_section(package_name, path))
    if not lines or not section then
        return result
    end
    local first, last, form = toml_ops.locate_package(lines, section, package_name)
    if not first then
        return result
    end
    for _, entry in ipairs(declaration_entries(vim.list_slice(lines, first, last), form) or {}) do
        if entry.key == "features" then
            for feature in entry.value:gmatch("[\"']([^\"']*)[\"']") do
                result.features[#result.features + 1] = feature
            end
        elseif entry.key == "default-features" or entry.key == "default_features" then
            result.default_features = entry.value ~= "false"
        elseif entry.key == "optional" then
            result.optional = entry.value == "true"
        elseif entry.key == "version" then
            result.version = entry.value:match("^[\"'](.*)[\"']$")
        end
    end
    return result
end

-- ============================================================================
-- Fetch available features from crates.io
-- ============================================================================

---@param package_name string
---@param callback fun(features: string[], err: string|nil)
function M.fetch_available_features(package_name, callback)
    if features_cache[package_name] then
        callback(features_cache[package_name], nil)
        return
    end

    if in_flight[package_name] then
        table.insert(in_flight[package_name], callback)
        return
    end

    in_flight[package_name] = { callback }

    local url = string.format("https://crates.io/api/v1/crates/%s", package_name)
    local timeout = config.cargo.api.timeout or 10

    local function notify_all(feats, err)
        local waiters = in_flight[package_name] or {}
        in_flight[package_name] = nil
        for _, cb in ipairs(waiters) do
            cb(feats, err)
        end
    end

    http.get(url, function(output, err)
        if err then
            notify_all(nil, err)
            return
        end

        local ok, data = pcall(vim.json.decode, output)
        if not ok or not data then
            notify_all(nil, "Failed to parse response")
            return
        end

        local features = {}
        if data.versions and #data.versions > 0 then
            for _, version in ipairs(data.versions) do
                if not version.yanked then
                    if version.features then
                        for feature in pairs(version.features) do
                            table.insert(features, feature)
                        end
                    end
                    break
                end
            end
        end

        table.sort(features)
        features_cache[package_name] = features
        notify_all(features, nil)
    end, timeout)
end

---@param package_name? string
function M.clear_cache(package_name)
    -- Only the memoised feature lists are dropped; a request on the wire keeps its waiters,
    -- otherwise the callbacks queued behind it never fire.
    if package_name then
        features_cache[package_name] = nil
    else
        features_cache = {}
    end
end

-- ============================================================================
-- Update features in Cargo.toml
-- ============================================================================

---@param package_name string
---@param opts {features?: string[], default_features?: boolean, optional?: boolean, bufnr?: integer, section?: string}
---@param callback fun(success: boolean, message: string|nil)
function M.update_features(package_name, opts, callback)
    debug(string.format("Updating features for %s", package_name), vim.log.levels.INFO)

    local path = manifest_path(opts.bufnr)
    if not path then
        callback(false, "Cargo.toml not found")
        return
    end

    local lines = file_ops.read_lines(path)
    if not lines then
        callback(false, "Failed to read Cargo.toml")
        return
    end

    local bufnr = opts.bufnr or vim.fn.bufnr(path)
    local section = opts.section or helpers.find_package_section(package_name, path)
    local first, last, form
    if section then
        first, last, form = toml_ops.locate_package(lines, section, package_name)
    end
    if not first or not last then
        callback(false, string.format("Could not find package %s", package_name))
        return
    end

    local saved_view = nil
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
        saved_view = vim.fn.winsaveview()
    end

    local block = vim.list_slice(lines, first, last)
    local replacement
    if form == "table" then
        replacement = M.edit_dependency_table(block, opts)
    else
        local line = M.edit_dependency_block(block, opts)
        replacement = line and { line } or nil
    end
    if not replacement then
        callback(false, string.format("Cannot rewrite the declaration of %s; edit it by hand", package_name))
        return
    end

    local new_lines, change = toml_ops.replace_block(lines, first, last, replacement)

    local write_ok, write_err = file_ops.write_lines(path, new_lines)
    if not write_ok then
        callback(false, write_err)
        return
    end

    if change then
        file_ops.apply_buffer_change(path, change)
    end

    -- ==========================================================================
    -- Clear caches
    -- ==========================================================================
    parser.clear_cache()
    M.clear_cache(package_name)
    hub_declared.clear_cache("cargo", package_name)
    hub_declared.refresh_data("cargo")
    package_loader.clear_cache(package_name)
    hub_installed.clear_cache("cargo", package_name)
    installed_data.clear_cache()

    -- ==========================================================================
    -- Refresh virtual text via the public vt API (no direct virt_texts access)
    -- ==========================================================================
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
        vim.defer_fn(function()
            package_loader.load_package_data_async("cargo", package_name, function(package_data)
                if api.nvim_buf_is_valid(bufnr) then
                    vt.update_package(bufnr, package_data)
                end
                if saved_view and vim.api.nvim_get_current_buf() == bufnr then
                    vim.schedule(function()
                        pcall(vim.fn.winrestview, saved_view)
                    end)
                end
            end, { initial = false })
        end, 50)
    end

    callback(true, "Features updated successfully")
end

-- ============================================================================
-- UI
-- ============================================================================

---@param package_name string
---@param callback fun(features: string[]|nil, default_features: boolean|nil, optional: boolean|nil)
---@param bufnr? integer
---@param section? string
function M.show_features_ui(package_name, callback, bufnr, section)
    local current = M.get_current_features(package_name, bufnr, section)

    M.fetch_available_features(package_name, function(available_features, err)
        if err then
            notify("Failed to fetch features: " .. err, vim.log.levels.ERROR)
            callback(nil, nil, nil)
            return
        end

        if not available_features or #available_features == 0 then
            -- Nothing was chosen, so nothing is written: going on would rebuild the dependency
            -- declaration for no reason.
            notify("No features available for " .. package_name, vim.log.levels.INFO)
            callback(nil, nil, nil)
            return
        end

        local initial_selected = {}
        for _, f in ipairs(current.features) do
            initial_selected[f] = true
        end

        vim.schedule(function()
            ui.multiselect(
                "Cargo Features",
                string.format("Select features for %s", package_name),
                string.format("Current version: %s", current.version or "unknown"),
                available_features,
                function(confirmed, selected)
                    if not confirmed then
                        callback(nil, nil, nil)
                        return
                    end
                    local features = {}
                    for feature, enabled in pairs(selected) do
                        if enabled then
                            table.insert(features, feature)
                        end
                    end
                    table.sort(features)
                    callback(features, current.default_features, current.optional)
                end,
                { initial_selected = initial_selected }
            )
        end)
    end)
end

---@param package_name string
---@param bufnr integer
function M.show_ui(package_name, bufnr)
    -- Taken now: the cursor says which declaration is meant, and the picker is about to open.
    local path = manifest_path(bufnr)
    local section = path and helpers.find_package_section(package_name, path)
    M.show_features_ui(package_name, function(features, default_features, optional)
        if not features then
            return
        end
        M.update_features(package_name, {
            features = features,
            default_features = default_features,
            optional = optional,
            bufnr = bufnr,
            section = section,
        }, function(success, message)
            if success then
                notify(string.format("Features updated for %s", package_name), vim.log.levels.INFO)
            else
                notify(message or "Failed to update features", vim.log.levels.ERROR)
            end
        end)
    end, bufnr, section)
end

return M
