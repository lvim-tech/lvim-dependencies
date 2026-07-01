-- lvim-dependencies.managers.composer.virtual_text: turns a package record into the inline
-- virtual-text chunks (declared → installed → latest, with up-to-date / outdated icons) shown
-- at end-of-line, and locates a package's line in the buffer. Dependency type (platform / vcs /
-- registry) is resolved from the package name first (most reliable), then the manifest's
-- per-type formatter is applied; a plain fallback formatter covers records with no type match.
--
---@module "lvim-dependencies.managers.composer.virtual_text"

local api = vim.api
local config = require("lvim-dependencies.config")
local init = require("lvim-dependencies.core.init")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class ComposerVirtualText
local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

---@return ComposerManifest|nil
local function get_manifest()
    local m = init.get_manifest("composer")
    ---@cast m ComposerManifest|nil
    return m
end

local function get_latest_version(record)
    if not record or not record.latest then
        return nil
    end
    return type(record.latest) == "table" and record.latest.version or nil
end

local function get_dep_type_name(record)
    -- Check package name first (most reliable)
    local name = record.package or ""
    if
        name == "php"
        or name:match("^php%-")
        or name:match("^ext%-")
        or name:match("^lib%-")
        or name:match("^composer%-")
    then
        return "platform"
    end

    if type(record.declared) == "table" then
        if record.declared.type then
            return record.declared.type
        end
        return "registry"
    elseif type(record.declared) == "string" then
        local v = record.declared
        if v:match("^dev%-") then
            return "vcs"
        end
        return "registry"
    end
    return "registry"
end

local function get_dep_config(record)
    local manifest_data = get_manifest()
    local dep_types = manifest_data and manifest_data.dependency_types or {}
    return dep_types[get_dep_type_name(record)]
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Find a package name in a single buffer line (JSON format: "vendor/pkg":)
--- Called by core/virtual_text.lua find_pkg_in_line
---@param line string
---@return string|nil
function M.find_package_in_line(line)
    -- vendor/package format: "laravel/framework":
    local vendor_pkg = line:match('^%s*"([^"]+/[^"]+)"%s*:')
    if vendor_pkg then
        return vendor_pkg
    end
    -- platform packages without slash: "php":, "ext-json":, "lib-curl":, "composer-*":
    return line:match('^%s*"(php[%-%w]*)"%s*:')
        or line:match('^%s*"(ext%-[^"]+)"%s*:')
        or line:match('^%s*"(lib%-[^"]+)"%s*:')
        or line:match('^%s*"(composer%-[^"]+)"%s*:')
end

--- Find line number of a package in the buffer
---@param buf integer
---@param package_name string
---@return integer|nil
function M.find_package_line(buf, package_name)
    if vim.in_fast_event() or not api.nvim_buf_is_valid(buf) then
        return nil
    end

    local ok, lines = pcall(api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok or not lines then
        return nil
    end

    local manifest_data = get_manifest()
    local patterns = manifest_data and manifest_data.package_patterns or {}

    for _, pattern in pairs(patterns) do
        for i, line in ipairs(lines) do
            if line:match(pattern) == package_name then
                return i - 1
            end
        end
    end

    -- Fallback: exact JSON key match
    local escaped = vim.pesc(package_name)
    local simple = string.format('^%%s*"%s"%%s*:', escaped)
    for i, line in ipairs(lines) do
        if line:match(simple) then
            return i - 1
        end
    end

    return nil
end

--- Get loading animation parts
---@return VirtualTextChunk[]
function M.get_loading_parts()
    return {
        { icons.separators.prefix .. " ", groups.separator },
        { icons.loading, groups.loading or "Comment" },
    }
end

--- Get working animation parts
---@return VirtualTextChunk[]
function M.get_working_parts()
    return {
        { icons.separators.prefix .. " ", groups.separator },
        { icons.working or icons.loading, groups.loading or "Comment" },
    }
end

--- Format package chunks based on dependency type
---@param record PackageRecord
---@return VirtualTextChunk[]
function M.format_package_chunks(record)
    if not record then
        return { { "?", groups.error or "Comment" } }
    end

    if record.installed_err or record.latest_err then
        local err_msg = record.installed_err or record.latest_err or "error"
        return {
            { icons.separators.prefix .. " ", groups.separator },
            { icons.error .. " " .. err_msg, groups.error or "Error" },
        }
    end

    local latest_version = get_latest_version(record)
    local dep_config = get_dep_config(record)
    local chunks = { { icons.separators.prefix .. " ", groups.separator } }

    if dep_config and dep_config.format then
        local format_data = {
            name = record.package,
            installed = record.installed,
            latest = latest_version,
            -- declared_version may be nil for platform packages — fall back to declared string
            declared = record.declared_version or (type(record.declared) == "string" and record.declared) or nil,
        }

        if type(record.declared) == "table" then
            for k, v in pairs(record.declared) do
                if k ~= "name" and k ~= "type" and k ~= "declared_version" then
                    format_data[k] = v
                end
            end
        end

        local config_chunks = dep_config.format(format_data)
        if type(config_chunks) == "table" then
            for _, chunk in ipairs(config_chunks) do
                chunks[#chunks + 1] = chunk
            end
            return chunks
        end
    end

    -- Fallback
    if record.declared_version then
        chunks[#chunks + 1] = { record.declared_version, groups.declared or "Comment" }
    end
    if record.installed then
        if #chunks > 1 then
            chunks[#chunks + 1] = { " " .. icons.separators.transition .. " ", groups.separator }
        end
        chunks[#chunks + 1] = { record.installed, groups.installed or "String" }
    end
    if latest_version then
        if #chunks > 1 then
            chunks[#chunks + 1] = { " " .. icons.separators.divider .. " ", groups.separator }
        end
        chunks[#chunks + 1] = { latest_version, groups.latest or "Special" }
    end

    if #chunks == 1 then
        return { { "?", groups.comment or "Comment" } }
    end
    return chunks
end

--- Format package as plain text (backward compatibility)
---@param record PackageRecord
---@return string
function M.format_package_text(record)
    local chunks = M.format_package_chunks(record)
    local parts = {}
    for _, chunk in ipairs(chunks) do
        parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts, "")
end

return M
