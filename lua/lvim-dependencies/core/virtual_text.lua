-- lvim-dependencies.core.virtual_text: renders each package's version status as an
-- end-of-line extmark. Owns a per-buffer record table (declared/installed/latest + the
-- live extmark id) and repaints it as data arrives, moving marks to follow edits (guarded
-- by _moving so a repaint can't re-enter). Line ↔ package resolution is delegated to the
-- manager's find_package_in_line when present, with a universal YAML/TOML/JSON fallback,
-- so the core stays format-agnostic. All redraws bail out of fast events (extmark APIs are
-- unsafe there) and reschedule.
--
---@module "lvim-dependencies.core.virtual_text"

local api = vim.api
local init = require("lvim-dependencies.core.init")
local package_loader = require("lvim-dependencies.core.package_loader")
local declared = require("lvim-dependencies.core.hub.declared")
local config = require("lvim-dependencies.config")
local async = require("lvim-dependencies.core.async_util")
local utils = require("lvim-dependencies.utils")
local const = require("lvim-dependencies.core.const")
local metrics = require("lvim-dependencies.core.metrics")

local config_icons = config.ui.virtual_text.icons
local config_groups = config.groups
local debug = utils.debug
local notify = utils.notify

-- ============================================================================
-- Constants
-- ============================================================================
local NAMESPACE_VIRTUAL_TEXT = const.NAMESPACES.VIRTUAL_TEXT
local VT_POSITION = config.ui.virtual_text.position

-- Cache for vt modules
local vt_module_cache = {}

---@type VirtualTexts
local virt_texts = {}

---@class VirtualTextDef
local M = {
    _moving = {},
    _updating = {},
    ---@type VirtualTextHandlers
    _handlers = {
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
    },
    namespace = api.nvim_create_namespace(NAMESPACE_VIRTUAL_TEXT),
    virt_texts = virt_texts,
}

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get the virtual text module for a manager type (with caching)
---@param manifest_type string|nil
---@return table|nil
local function get_vt_module(manifest_type)
    if not manifest_type then
        return nil
    end
    if vt_module_cache[manifest_type] then
        return vt_module_cache[manifest_type]
    end
    local module = init.get_virtual_text(manifest_type)
    vt_module_cache[manifest_type] = module
    return module
end

--- Find a package name in a single buffer line.
--- Delegates to the manager's find_package_in_line(line) if available,
--- otherwise uses a universal fallback that handles both YAML (":") and
--- TOML/JSON ("=") separators.
---
--- Manager modules can implement this to support any format:
---   YAML  (pubspec):   "pkg :"   → function M.find_package_in_line(line) return line:match("^%s*([%w%-_%.]+)%s*:") end
---   TOML  (cargo):     "pkg ="   → function M.find_package_in_line(line) return line:match("^%s*([%w%-_%.]+)%s*=") end
---   JSON  (npm):       '"pkg" :' → function M.find_package_in_line(line) return line:match('^%s*"([^"]+)"%s*:') end
---   Go    (go.mod):    "require pkg v" → custom pattern
---
---@param vt_module table|nil Manager virtual text module
---@param line string Buffer line to inspect
---@return string|nil package_name
local function find_pkg_in_line(vt_module, line)
    -- Delegate to manager-specific implementation if available
    if vt_module and vt_module.find_package_in_line then
        return vt_module.find_package_in_line(line)
    end
    -- Universal fallback: handles YAML ("pkg :") and TOML/JSON ("pkg =")
    return line:match("^%s*([%w%-_%.]+)%s*[=:]")
end

--- Validate a single virtual text chunk
---@param chunk any
---@return table|nil
local function validate_chunk(chunk)
    if type(chunk) ~= "table" then
        return nil
    end
    if #chunk >= 1 and #chunk <= 2 then
        if type(chunk[1]) ~= "string" then
            return nil
        end
        if chunk[2] and type(chunk[2]) ~= "string" then
            return nil
        end
        return chunk
    end
    return nil
end

--- Validate all chunks in a list, returning a fallback on failure
---@param chunks VirtualTextChunk[]
---@return VirtualTextChunk[]
local function validate_chunks(chunks)
    if type(chunks) ~= "table" then
        debug("Invalid chunks: not a table", vim.log.levels.WARN)
        return {}
    end

    local valid_chunks = {}
    for i, chunk in ipairs(chunks) do
        local valid = validate_chunk(chunk)
        if valid then
            valid_chunks[#valid_chunks + 1] = valid
        else
            debug(string.format("Invalid chunk at position %d: %s", i, vim.inspect(chunk)), vim.log.levels.WARN)
        end
    end

    if #valid_chunks == 0 then
        debug("No valid chunks, using fallback", vim.log.levels.WARN)
        return { { " ? ", "Comment" } }
    end

    return valid_chunks
end

--- Build a prefix chunk with separator icon
---@return VirtualTextChunk
local function prefix_chunk()
    return { "  " .. config_icons.separators.prefix .. " ", config_groups.separator }
end

--- Build loading indicator chunks
---@param vt_module table|nil
---@return VirtualTextChunk[]
local function loading_chunks(vt_module)
    if vt_module and vt_module.get_loading_parts then
        return vt_module.get_loading_parts()
    end
    return { prefix_chunk(), { config_icons.loading, config_groups.loading or "Comment" } }
end

--- Build working indicator chunks
---@param vt_module table|nil
---@return VirtualTextChunk[]
local function working_chunks(vt_module)
    if vt_module and vt_module.get_working_parts then
        return vt_module.get_working_parts()
    end
    local icon = config_icons.working or config_icons.loading
    return { prefix_chunk(), { icon, config_groups.loading or "Comment" } }
end

--- Build error indicator chunks
---@param err_msg string|nil
---@return VirtualTextChunk[]
local function error_chunks(err_msg)
    local error_icon = config_icons.error or ""
    local text = err_msg and (error_icon .. " " .. err_msg) or error_icon
    return { prefix_chunk(), { text, config_groups.error or "Comment" } }
end

--- Get latest version string from a record
---@param record PackageRecord|nil
---@return string|nil
local function get_latest_version(record)
    if not record or not record.latest then
        return nil
    end
    return type(record.latest) == "table" and record.latest.version or nil
end

--- Extract declared version string from raw declared data
---@param declared_data any
---@return string|nil
local function extract_declared_version(declared_data)
    if type(declared_data) == "string" then
        return declared_data
    end
    if type(declared_data) == "table" then
        return declared_data.declared or declared_data.version
    end
    return nil
end

--- Delete all extmarks on a specific line
---@param buf integer
---@param line_num integer
local function delete_extmarks_on_line(buf, line_num)
    local extmarks = api.nvim_buf_get_extmarks(buf, M.namespace, { line_num, 0 }, { line_num, -1 }, {})
    for _, em in ipairs(extmarks) do
        pcall(api.nvim_buf_del_extmark, buf, M.namespace, em[1])
    end
end

--- Determine the appropriate chunk list for a package
---@param vt_module table|nil
---@param record PackageRecord|nil
---@param mode? "loading"|"working"
---@return VirtualTextChunk[]
local function get_package_chunks(vt_module, record, mode)
    local chunks

    if record then
        if record.installed_err then
            chunks = error_chunks("inst: " .. record.installed_err)
        elseif record.latest_err then
            chunks = error_chunks("latest: " .. record.latest_err)
        end
    end

    if not chunks then
        if mode == "loading" then
            chunks = loading_chunks(vt_module)
        elseif mode == "working" then
            chunks = working_chunks(vt_module)
        end
    end

    if
        not chunks
        and record
        and (record.installed or record.latest)
        and vt_module
        and vt_module.format_package_chunks
    then
        chunks = vt_module.format_package_chunks(record)
    end

    if not chunks then
        if record and record.is_transient then
            chunks = working_chunks(vt_module)
        elseif not record then
            chunks = loading_chunks(vt_module)
        else
            chunks = error_chunks()
        end
    end

    return validate_chunks(chunks)
end

--- Create a new record data structure for a package
---@param pkg string
---@param declared_data any
---@param manifest_type string
---@param existing PackageRecord|nil
---@return PackageRecord
local function create_record(pkg, declared_data, manifest_type, existing)
    if existing then
        return vim.tbl_extend("force", {}, existing)
    end
    return {
        package = pkg,
        manifest_type = manifest_type,
        installed = nil,
        latest = nil,
        installed_err = nil,
        latest_err = nil,
        declared = declared_data,
        declared_version = extract_declared_version(declared_data),
        is_transient = true,
        created_at = vim.uv.now(),
    }
end

--- Create or update an extmark for a package
---@param buf integer
---@param package_name string
---@param line_num integer
---@param chunks VirtualTextChunk[]
---@param record PackageRecord
---@return integer extmark_id
local function set_extmark(buf, package_name, line_num, chunks, record)
    chunks = validate_chunks(chunks)

    local opts = { virt_text = chunks, virt_text_pos = VT_POSITION }
    if type(record.extmark_id) == "number" then
        opts.id = record.extmark_id
    end

    M.virt_texts[buf] = M.virt_texts[buf] or {}
    local line_count = api.nvim_buf_line_count(buf)
    if line_num < 0 or line_num >= line_count then
        local fresh_line = M.find_package_line(buf, package_name)
        if not fresh_line or fresh_line < 0 or fresh_line >= line_count then
            return record.extmark_id or 0
        end
        line_num = fresh_line
    end

    local ok, extmark_id = pcall(api.nvim_buf_set_extmark, buf, M.namespace, line_num, 0, opts)
    if not ok or not extmark_id then
        delete_extmarks_on_line(buf, line_num)
        local retry_ok, retry_id = pcall(api.nvim_buf_set_extmark, buf, M.namespace, line_num, 0, {
            virt_text = chunks,
            virt_text_pos = VT_POSITION,
        })
        if not retry_ok or not retry_id then
            return record.extmark_id or 0
        end
        extmark_id = retry_id
    end

    record.extmark_id = extmark_id
    record.last_line = line_num
    M.virt_texts[buf][package_name] = record

    return extmark_id
end

--- Ensure buffer virtual text table is initialized with metadata
---@param buf integer
---@param manifest_type? string
---@param packages? table<string, any>
local function ensure_buf_init(buf, manifest_type, packages)
    M.virt_texts[buf] = M.virt_texts[buf] or {}
    if manifest_type then
        M.virt_texts[buf].manifest_type = manifest_type
    end
    if packages then
        M.virt_texts[buf].declared = packages
    else
        M.virt_texts[buf].declared = M.virt_texts[buf].declared or {}
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Move virtual texts to correct lines after buffer changes
---@param buf integer
function M.move_virt_texts_only(buf)
    if vim.in_fast_event() or not M.virt_texts[buf] or M._moving[buf] then
        return
    end
    M._moving[buf] = true

    local declared_packages = M.virt_texts[buf].declared or {}
    local total_packages = vim.tbl_count(declared_packages)
    if total_packages == 0 then
        M._moving[buf] = nil
        return
    end

    local ok, lines = pcall(api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok or not lines then
        M._moving[buf] = nil
        return
    end

    local manifest_type = M.virt_texts[buf].manifest_type
    local vt_module = get_vt_module(manifest_type)

    local seen = {}
    local found_count = 0

    for i, line in ipairs(lines) do
        -- Delegate line parsing to the manager module (or universal fallback)
        local matched_pkg = find_pkg_in_line(vt_module, line)

        if matched_pkg and declared_packages[matched_pkg] and not seen[matched_pkg] then
            seen[matched_pkg] = true
            found_count = found_count + 1

            local line_num = i - 1
            local record = M.virt_texts[buf][matched_pkg]
            local rec_module = get_vt_module(record and record.manifest_type or manifest_type)

            local mode
            if not record or record.is_transient then
                mode = "working"
            elseif not record.installed and not get_latest_version(record) then
                mode = "loading"
            end

            local chunks = get_package_chunks(rec_module, record, mode)
            local record_data = create_record(matched_pkg, declared_packages[matched_pkg], manifest_type, record)
            set_extmark(buf, matched_pkg, line_num, chunks, record_data)

            if found_count >= total_packages then
                break
            end
        end
    end

    -- Remove extmarks for packages no longer in buffer
    for key, val in pairs(M.virt_texts[buf]) do
        if type(key) == "string" and type(val) == "table" and val.package and not seen[key] then
            if val.extmark_id then
                pcall(api.nvim_buf_del_extmark, buf, M.namespace, val.extmark_id)
            end
            M.virt_texts[buf][key] = nil
        end
    end

    M._moving[buf] = nil
end

--- Get loaded packages with their version data
---@param buf integer
---@return table<string, {declared: any, installed: string|nil, latest: table|nil}>
function M.get_loaded_packages(buf)
    if not M.virt_texts[buf] then
        return {}
    end
    local result = {}
    for pkg, record in pairs(M.virt_texts[buf]) do
        if type(record) == "table" and record.package then
            result[pkg] = {
                declared = record.declared_version or extract_declared_version(record.declared),
                installed = record.installed,
                latest = record.latest,
            }
        end
    end
    return result
end

--- Find the line number of a package in the buffer
---@param buf integer
---@param package_name string
---@return integer|nil
function M.find_package_line(buf, package_name)
    if not M.virt_texts[buf] or not M.virt_texts[buf].declared then
        return nil
    end

    local vt_module = get_vt_module(M.virt_texts[buf].manifest_type)
    if vt_module and vt_module.find_package_line then
        return vt_module.find_package_line(buf, package_name)
    end

    local ok, lines = pcall(api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok or not lines then
        return nil
    end

    -- Universal fallback
    local pattern = "^%s*" .. vim.pesc(package_name) .. "%s*[=:]"
    for i, line in ipairs(lines) do
        if line:match(pattern) then
            return i - 1
        end
    end
    return nil
end

--- Remove a package's virtual text
---@param buf integer
---@param package_name string
function M.remove_package(buf, package_name)
    if not M.virt_texts[buf] or not M.virt_texts[buf][package_name] then
        return
    end
    local record = M.virt_texts[buf][package_name]
    if record.extmark_id then
        pcall(api.nvim_buf_del_extmark, buf, M.namespace, record.extmark_id)
    end
    M.virt_texts[buf][package_name] = nil
end

--- Clear all virtual texts for a buffer
---@param buf integer
function M.clear_buffer(buf)
    if not M.virt_texts[buf] then
        return
    end
    local extmarks = api.nvim_buf_get_extmarks(buf, M.namespace, 0, -1, {})
    for _, em in ipairs(extmarks) do
        pcall(api.nvim_buf_del_extmark, buf, M.namespace, em[1])
    end
    M.virt_texts[buf] = nil
end

--- Display loading indicators for all packages in a manifest
---@param buf integer
---@param manifest_type string
---@param packages table<string, any>
---@param is_initial? boolean
function M.display_loading(buf, manifest_type, packages, is_initial)
    local _ = is_initial
    local measure_token = metrics.start_measure("vt:display_loading:" .. manifest_type)

    if vim.in_fast_event() then
        vim.schedule(function()
            M.display_loading(buf, manifest_type, packages)
        end)
        return
    end

    if not api.nvim_buf_is_valid(buf) then
        debug("Cannot display loading: buffer invalid", vim.log.levels.WARN)
        return
    end

    local vt_module = get_vt_module(manifest_type)
    if not vt_module or not vt_module.find_package_line then
        debug(string.format("No suitable virtual_text module for %s", manifest_type), vim.log.levels.WARN)
        return
    end

    ensure_buf_init(buf, manifest_type, packages)

    local count = 0
    for pkg, declared_data in pairs(packages) do
        if not M.virt_texts[buf][pkg] then
            local line_num = vt_module.find_package_line(buf, pkg)
            if line_num then
                local chunks = loading_chunks(vt_module)
                local record = create_record(pkg, declared_data, manifest_type, nil)
                set_extmark(buf, pkg, line_num, chunks, record)
                count = count + 1
            end
        end
    end

    local duration = metrics.end_measure(measure_token)
    metrics.record_operation("vt_display_loading", duration)

    if count > 0 then
        debug(string.format("Displayed loading for %d packages in %s", count, manifest_type), vim.log.levels.DEBUG)
    end
end

--- Display loading indicator for a single package
---@param buf integer
---@param manifest_type string
---@param package_info NewPackage
---@param mode? "loading"|"working"
function M.display_loading_for_package(buf, manifest_type, package_info, mode)
    mode = mode or "loading"

    if vim.in_fast_event() then
        vim.schedule(function()
            M.display_loading_for_package(buf, manifest_type, package_info, mode)
        end)
        return
    end

    if not api.nvim_buf_is_valid(buf) then
        debug("Cannot display loading for package: buffer invalid", vim.log.levels.WARN)
        return
    end

    local vt_module = get_vt_module(manifest_type)
    if not vt_module then
        debug(string.format("No virtual_text module for %s", manifest_type), vim.log.levels.WARN)
        return
    end

    ensure_buf_init(buf, manifest_type)

    if not M.virt_texts[buf].declared[package_info.name] then
        M.virt_texts[buf].declared[package_info.name] = (package_info.info and type(package_info.info) == "table")
                and package_info.info
            or { name = package_info.name }
    end

    local existing = M.virt_texts[buf][package_info.name]
    if existing and existing.extmark_id then
        pcall(api.nvim_buf_del_extmark, buf, M.namespace, existing.extmark_id)
    else
        delete_extmarks_on_line(buf, package_info.line)
    end

    local chunks = get_package_chunks(vt_module, nil, mode)
    local declared_data = M.virt_texts[buf].declared[package_info.name]
    local record = create_record(package_info.name, declared_data, manifest_type, nil)
    set_extmark(buf, package_info.name, package_info.line, chunks, record)

    debug(string.format("Displayed %s for %s", mode, package_info.name), vim.log.levels.DEBUG)
end

--- Update a package's virtual text with actual data
---@param buf integer
---@param package_data PackageResult
function M.update_package(buf, package_data)
    if not package_data or type(package_data) ~= "table" or not package_data.package then
        debug("Invalid package data in update_package", vim.log.levels.WARN)
        return
    end

    local measure_token = metrics.start_measure("vt:update:" .. package_data.package)

    if not api.nvim_buf_is_valid(buf) or not M.virt_texts[buf] then
        debug("Cannot update package: buffer invalid or no virtual text", vim.log.levels.WARN)
        return
    end

    local pkg = package_data.package
    local record = M.virt_texts[buf][pkg]

    if not record then
        if M.virt_texts[buf].declared and M.virt_texts[buf].declared[pkg] then
            local line_num = M.find_package_line(buf, pkg)
            if line_num then
                record = create_record(pkg, M.virt_texts[buf].declared[pkg], M.virt_texts[buf].manifest_type, nil)
                M.virt_texts[buf][pkg] = record
            else
                debug(string.format("Package %s not found in buffer", pkg), vim.log.levels.WARN)
                return
            end
        else
            debug(string.format("Package %s not found in virtual text data", pkg), vim.log.levels.WARN)
            return
        end
    end

    if package_data.declared ~= nil then
        record.declared = package_data.declared
        record.declared_version = extract_declared_version(package_data.declared)
    end
    record.installed = package_data.installed
    record.latest = package_data.latest
    record.installed_err = package_data.installed_err
    record.latest_err = package_data.latest_err
    record.is_transient = false

    local line_num = record.last_line
    if not line_num then
        line_num = M.find_package_line(buf, pkg)
    end

    if not line_num then
        M.remove_package(buf, pkg)
        return
    end

    record.last_line = line_num

    local vt_module = get_vt_module(record.manifest_type)
    local chunks = get_package_chunks(vt_module, record, nil)
    set_extmark(buf, pkg, line_num, chunks, record)

    local duration = metrics.end_measure(measure_token)
    metrics.record_operation("vt_update", duration)

    debug(string.format("Updated virtual text for %s", pkg), vim.log.levels.DEBUG)
end

--- Check if buffer has any virtual text displayed
---@param buf integer
---@return boolean
function M.has_virtual_text(buf)
    return M.virt_texts[buf] ~= nil
end

--- Show virtual text for a manifest
---@param buf integer
---@param manifest_type string
---@param packages? table<string, any>
function M.show(buf, manifest_type, packages)
    if not manifest_type then
        return
    end

    packages = packages or (M.virt_texts[buf] and M.virt_texts[buf].declared) or declared.get_data(manifest_type) or {}

    M.clear_buffer(buf)
    M.display_loading(buf, manifest_type, packages)

    for pkg, _ in pairs(packages) do
        async.run(function()
            package_loader.load_package_data_async(manifest_type, pkg, function(result)
                if api.nvim_buf_is_valid(buf) then
                    M.update_package(buf, result)
                end
            end, { initial = false })
        end)
    end

    notify("Virtual text shown", vim.log.levels.INFO)
end

--- Hide virtual text for a buffer
---@param buf integer
function M.hide(buf)
    M.clear_buffer(buf)
    notify("Virtual text hidden", vim.log.levels.INFO)
end

--- Toggle virtual text on/off
---@param buf integer
---@param manifest_type string
---@param packages? table<string, any>
function M.toggle(buf, manifest_type, packages)
    if M.has_virtual_text(buf) then
        M.hide(buf)
    else
        M.show(buf, manifest_type, packages)
    end
end

--- Set the handlers used by state module
---@param handlers VirtualTextHandlers
function M.setup_state_handlers(handlers)
    debug("Setting up state handlers", vim.log.levels.DEBUG)
    M._handlers = handlers
end

--- Clean up when buffer is closed
---@param buf integer
function M.on_buffer_close(buf)
    if M.virt_texts[buf] then
        M.clear_buffer(buf)
    end
end

--- Clear vt module cache
---@param manifest_type? string
function M.clear_cache(manifest_type)
    if manifest_type then
        vt_module_cache[manifest_type] = nil
    else
        vt_module_cache = {}
    end
end

return M
