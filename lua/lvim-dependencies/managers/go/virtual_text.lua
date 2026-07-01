-- lvim-dependencies.managers.go.virtual_text: turns a package record into the eol
-- virtual-text chunks shown after each go.mod require line (declared → installed → latest,
-- plus loading/working/error states). It delegates per-dependency-kind rendering to the
-- manifest's dependency_types formatters and only falls back to a generic layout when a kind
-- has none; it also holds the go.mod-specific line matchers used to locate a package row.
--
---@module "lvim-dependencies.managers.go.virtual_text"

local api = vim.api
local config = require("lvim-dependencies.config")
local init = require("lvim-dependencies.core.init")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class GoVirtualText
local M = {}

-- ============================================================================
-- Helpers
-- ============================================================================

--- Fetch the Go manifest (typed).
---@return GoManifest|nil
local function get_manifest()
    local m = init.get_manifest("go")
    ---@cast m GoManifest|nil
    return m
end

--- Pull the latest version string out of a record's (table) latest field.
---@param record table
---@return string|nil
local function get_latest_version(record)
    if not record or not record.latest then
        return nil
    end
    return type(record.latest) == "table" and record.latest.version or nil
end

--- Classify a record as a "replace" directive or a plain "registry" dependency.
---@param record table
---@return string
local function get_dep_type_name(record)
    if type(record.declared) == "table" then
        if record.declared.replace then
            return "replace"
        end
        return "registry"
    end
    return "registry"
end

--- Resolve the manifest dependency-type definition for a record.
---@param record table
---@return DependencyTypeDef|nil
local function get_dep_config(record)
    local manifest_data = get_manifest()
    local dep_types = manifest_data and manifest_data.dependency_types or {}
    return dep_types[get_dep_type_name(record)]
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Find a package name in a single buffer line (go.mod format)
--- Matches: "    github.com/pkg/errors v1.0.0" or "require github.com/pkg v1.0.0"
---@param line string
---@return string|nil
function M.find_package_in_line(line)
    -- Inside require block: "\tgithub.com/pkg v1.0.0"
    local name = line:match("^%s+([%w%.%-%_/]+)%s+v[%w%.%-%+]+")
    if name then
        return name
    end
    -- Single-line: "require github.com/pkg v1.0.0"
    name = line:match("^require%s+([%w%.%-%_/]+)%s+v[%w%.%-%+]+")
    return name
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

    local escaped = vim.pesc(package_name)
    for i, line in ipairs(lines) do
        if line:match("^%s*" .. escaped .. "%s+v") then
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

--- A go.mod package record: the shared record plus the go-specific `indirect`
--- flag (carried in from the declared data — a `// indirect` require line).
---@class GoPackageRecord : PackageRecord
---@field indirect? boolean whether the go.mod require line is marked `// indirect`

--- Format package chunks based on dependency type
---@param record GoPackageRecord
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
            declared = record.declared_version,
            indirect = record.indirect,
        }

        if type(record.declared) == "table" then
            for k, v in pairs(record.declared) do
                if k ~= "name" and k ~= "type" then
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

---@param record GoPackageRecord
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
