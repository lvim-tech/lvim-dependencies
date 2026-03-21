-- lvim-dependencies/managers/go/manifest.lua
-- Configuration for Go modules manager

---@include "core/types.lua"

local compare_version = require("lvim-dependencies.managers.go.compare_versions")
local config = require("lvim-dependencies.config")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class GoManifest : ManagerManifest
local M = {}

-- ============================================================================
-- Manager identification
-- ============================================================================

M.key = "go"

M.file_patterns = {
    "go.mod",
}

M.lock_files = {
    "go.sum",
}

--- Sections inside go.mod that contain dependencies
M.dependency_sections = {
    "require",
}

--- Go proxy registry
M.default_registry = "https://proxy.golang.org"

M.registry = {
    base_url = "https://proxy.golang.org",
    --- List endpoint: returns newline-separated version list
    list_endpoint = "/%s/@v/list",
    --- Latest endpoint: returns JSON {Version, Time, ...}
    latest_endpoint = "/%s/@latest",
}

M.api = {
    timeout = 10,
}

-- ============================================================================
-- Commands
-- ============================================================================

M.commands = {
    update = {
        go = { "go", "get" },
    },
    remove = {
        go = { "go", "get" },
    },
}

-- ============================================================================
-- Validation
-- ============================================================================

M.package_validation = {
    --- Go module paths: github.com/user/pkg, golang.org/x/net, etc.
    pattern = "^[%w%.%-_/]+$",
    min_length = 3,
    max_length = 500,
}

M.virtual_text = {
    position = "eol",
    priority = 1000,
}

-- ============================================================================
-- Virtual text helpers
-- ============================================================================

local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

local function add_sep(vt, sep, hl)
    vt[#vt + 1] = { " " .. sep .. " ", hl }
end

local function add_transition(vt)
    add_sep(vt, icons.separators.transition, groups.separator)
end

local function add_divider(vt)
    add_sep(vt, icons.separators.divider, groups.separator)
end

local function add_installed(vt, installed)
    if installed and installed ~= "not installed" then
        vt[#vt + 1] = { installed, groups.installed }
    else
        vt[#vt + 1] = { "Not installed", groups.installed }
    end
end

local function add_latest(vt, latest, installed)
    local is_versioned = installed and installed ~= "not installed" and installed:match("^v%d")
    local is_current = is_versioned and compare_version.compare(latest, installed) == 0
    local icon = is_current and icons.up_to_date or icons.outdated
    local hl = is_current and groups.up_to_date or groups.outdated
    vt[#vt + 1] = { icon .. " ", hl }
    vt[#vt + 1] = { latest, hl }
end

local HOVER_METADATA_FIELDS = {
    { field = "description", label = "" },
    { field = "homepage", label = "Homepage" },
}

local function add_metadata(lines, metadata)
    if not metadata then
        return
    end
    for _, entry in ipairs(HOVER_METADATA_FIELDS) do
        local value = metadata[entry.field]
        if value and is_valid_string(value) then
            if entry.label == "" then
                lines[#lines + 1] = ""
                lines[#lines + 1] = value
            else
                lines[#lines + 1] = string.format("**%s:** `%s`", entry.label, value)
            end
        end
    end
end

local function version_status(latest, installed)
    if not installed or installed == "not installed" then
        return ""
    end
    local cmp = compare_version.compare(latest, installed)
    if cmp == 1 then
        return " (outdated)"
    elseif cmp == 0 then
        return " (up to date)"
    end
    return ""
end

local function standard_vt(dep, declared_text)
    local vt = { { declared_text, groups.declared } }
    add_transition(vt)
    add_installed(vt, dep.installed)
    if dep.latest then
        add_divider(vt)
        add_latest(vt, dep.latest, dep.installed)
    end
    return vt
end

local function standard_hover(dep, latest, metadata, opts)
    local lines = {}
    if dep.declared then
        lines[#lines + 1] = string.format("**Declared:** `%s`", dep.declared)
    end
    if dep.indirect then
        lines[#lines + 1] = "**Type:** `indirect`"
    end
    if dep.installed then
        lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
    end
    if latest then
        lines[#lines + 1] = string.format("**Latest:** `%s`%s", latest, version_status(latest, dep.installed))
    elseif opts and opts.show_fetching then
        lines[#lines + 1] = "**Latest:** `fetching...`"
    end
    add_metadata(lines, metadata)
    return lines
end

-- ============================================================================
-- Dependency type definitions
-- ============================================================================

---@type table<string, DependencyTypeDef>
M.dependency_types = {

    --- Registry version: v1.2.3, v1.2.3+incompatible
    registry = {
        type = "registry",
        detect = function(v)
            if type(v) == "string" then
                return true
            end
            if type(v) == "table" and v.version ~= nil then
                return true
            end
            return false
        end,
        extract = function(v, dep)
            dep.declared = type(v) == "string" and v or v.version
        end,
        format = function(dep)
            return standard_vt(dep, dep.declared or "unknown")
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata, { show_fetching = true })
        end,
    },

    --- Replace directive: replace github.com/foo => github.com/bar v1.0.0
    replace = {
        type = "replace",
        detect = function(v)
            return type(v) == "table" and v.replace ~= nil
        end,
        extract = function(v, dep)
            dep.declared = v.version
            dep.replace = v.replace
        end,
        format = function(dep)
            local vt = { { "replace:", groups.info } }
            if dep.replace then
                vt[#vt + 1] = { dep.replace, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            return vt
        end,
        ---@diagnostic disable-next-line: unused-local
        format_hover = function(dep, latest, metadata)
            local lines = { "**Replace directive**" }
            if dep.replace then
                lines[#lines + 1] = string.format("**Replaces with:** `%s`", dep.replace)
            end
            if dep.declared then
                lines[#lines + 1] = string.format("**Declared:** `%s`", dep.declared)
            end
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },
}

return M
