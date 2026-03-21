-- lvim-dependencies/managers/cargo/manifest.lua
-- Configuration for Cargo (Rust) package manager

---@include "core/types.lua"

local compare_version = require("lvim-dependencies.managers.cargo.compare_versions")
local config = require("lvim-dependencies.config")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class CargoManifest
local M = {}

-- ============================================================================
-- Manager identification and detection (TECHNICAL - stays here)
-- ============================================================================

M.key = "cargo"

M.file_patterns = {
    "Cargo.toml",
}

M.lock_files = {
    "Cargo.lock",
}

M.dependency_sections = {
    "dependencies",
    "dev-dependencies",
    "build-dependencies",
}

M.special_keys = {
    "package",
    "lib",
    "bin",
    "example",
    "test",
    "bench",
    "features",
    "profile",
    "workspace",
    "patch",
    "replace",
    "target",
    "badges",
    "metadata",
}

M.package_patterns = {
    simple = '^%s*([%w%-_]+)%s*=%s*"([^"]+)"',
    table = "^%s*([%w%-_]+)%s*=%s*{",
    git = '^%s*([%w%-_]+)%s*=%s*{.*git%s*=%s*"',
    path = '^%s*([%w%-_]+)%s*=%s*{.*path%s*=%s*"',
    version = '^%s*([%w%-_]+)%s*=%s*{.*version%s*=%s*"',
    bare = "^%s*([%w%-_]+)%s*=%s*true",
}

-- ============================================================================
-- Registry and API configuration (TECHNICAL - stays here)
-- ============================================================================

M.default_registry = "https://crates.io"

M.registry = {
    base_url = "https://crates.io/api/v1",
    package_endpoint = "/crates/%s",
    response = {
        version_path = { "crate", "max_version" },
        versions_path = { "versions" },
    },
}

M.api = {
    timeout = 10, -- Can be overridden by config.cargo.api.timeout
}

-- ============================================================================
-- Commands and project detection (TECHNICAL - stays here)
-- ============================================================================

M.commands = {
    add = {
        cargo = { "cargo", "add" },
    },
    remove = {
        cargo = { "cargo", "rm" },
    },
    update = {
        cargo = { "cargo", "update" },
    },
    outdated = {
        cargo = { "cargo", "outdated" },
    },
}

-- ============================================================================
-- Formatting and validation (USER PREFERENCES - can be overridden by config)
-- ============================================================================

M.package_validation = {
    pattern = "^[a-zA-Z][a-zA-Z0-9_-]*$",
    min_length = 1,
    max_length = 64,
}

M.virtual_text = {
    position = "eol",
    priority = 1000,
}

-- ============================================================================
-- Virtual text helpers (shared across dependency types)
-- ============================================================================

--- Check if a value is a valid non-empty string (filters vim.NIL and empty strings)
---@param val any
---@return boolean
local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

--- Append a separator chunk to virtual text
---@param vt VirtualTextChunk[]
---@param sep string
---@param hl string
local function add_sep(vt, sep, hl)
    vt[#vt + 1] = { " " .. sep .. " ", hl }
end

--- Append a transition separator
---@param vt VirtualTextChunk[]
local function add_transition(vt)
    add_sep(vt, icons.separators.transition, groups.separator)
end

--- Append a divider separator
---@param vt VirtualTextChunk[]
local function add_divider(vt)
    add_sep(vt, icons.separators.divider, groups.separator)
end

--- Append installed version chunk
---@param vt VirtualTextChunk[]
---@param installed string|nil
local function add_installed(vt, installed)
    if installed and installed ~= "not installed" then
        vt[#vt + 1] = { installed, groups.installed }
    else
        vt[#vt + 1] = { "Not installed", groups.installed }
    end
end

--- Append latest version chunk with up-to-date/outdated indicator
---@param vt VirtualTextChunk[]
---@param latest string
---@param installed string|nil
local function add_latest(vt, latest, installed)
    local is_versioned = installed and installed ~= "not installed" and installed:match("^%d")
    local is_current = is_versioned and compare_version.compare(latest, installed) ~= 1

    local icon = is_current and icons.up_to_date or icons.outdated
    local hl = is_current and groups.up_to_date or groups.outdated

    vt[#vt + 1] = { icon .. " ", hl }
    vt[#vt + 1] = { latest, hl }
end

--- Metadata fields and their hover labels
---@type {field: string, label: string}[]
local HOVER_METADATA_FIELDS = {
    { field = "description", label = "" },
    { field = "homepage", label = "Homepage" },
    { field = "repository", label = "Repository" },
    { field = "documentation", label = "Documentation" },
    { field = "license", label = "License" },
    { field = "categories", label = "Categories" },
    { field = "keywords", label = "Keywords" },
}

--- Append metadata lines for hover display
---@param lines string[]
---@param metadata table|nil
local function add_metadata(lines, metadata)
    if not metadata then
        return
    end

    for _, entry in ipairs(HOVER_METADATA_FIELDS) do
        local value = metadata[entry.field]
        if value then
            if entry.label == "" then
                -- Description - string field, use is_valid_string
                if is_valid_string(value) then
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = value
                end
            elseif type(value) == "table" then
                -- Categories and keywords - tables, need special handling
                local valid_items = {}
                for _, item in ipairs(value) do
                    if is_valid_string(item) then
                        table.insert(valid_items, item)
                    end
                end
                if #valid_items > 0 then
                    lines[#lines + 1] = string.format("**%s:** `%s`", entry.label, table.concat(valid_items, ", "))
                end
            else
                -- Other string fields (homepage, repository, etc.) - use is_valid_string
                if is_valid_string(value) then
                    lines[#lines + 1] = string.format("**%s:** `%s`", entry.label, value)
                end
            end
        end
    end
end

--- Compute version comparison status string
---@param latest string
---@param installed string|nil
---@return string status " (outdated)", " (up to date)", or ""
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

--- Build standard hover lines for declared/installed/latest
---@param dep table
---@param latest string|nil
---@param metadata table|nil
---@param opts? {show_fetching?: boolean}
---@return string[]
local function standard_hover(dep, latest, metadata, opts)
    local lines = {}

    if dep.declared then
        lines[#lines + 1] = string.format("**Declared:** `%s`", dep.declared)
    end
    if dep.features and #dep.features > 0 then
        lines[#lines + 1] = string.format("**Features:** `%s`", table.concat(dep.features, ", "))
    end
    if dep.optional then
        lines[#lines + 1] = "**Optional:** `true`"
    end
    if dep.default_features == false then
        lines[#lines + 1] = "**Default features:** `false`"
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

--- Build standard virtual text: declared → [features] → installed → latest
---@param dep table
---@param declared_text string
---@return VirtualTextChunk[]
local function standard_vt(dep, declared_text)
    local vt = {}
    vt[#vt + 1] = { declared_text, groups.declared }

    -- Show features
    local display_config = config.cargo.display or {}

    if display_config.show_features and dep.features and #dep.features > 0 then
        local filtered = {}
        for _, f in ipairs(dep.features) do
            if display_config.filter_default and f == "default" then
                -- skip
            else
                table.insert(filtered, f)
            end
        end

        if #filtered > 0 then
            local max_features = display_config.max_features_display or 3
            local features_to_show = filtered
            local truncated = false

            if max_features > 0 and #filtered > max_features then
                features_to_show = {}
                for i = 1, max_features do
                    features_to_show[i] = filtered[i]
                end
                truncated = true
            end

            local features_text = table.concat(features_to_show, ",")
            if truncated then
                features_text = features_text .. (display_config.truncation_indicator or "...")
            end

            vt[#vt + 1] = { " [", groups.info }
            vt[#vt + 1] = { features_text, groups.info }
            vt[#vt + 1] = { "]", groups.info }
        end
    end

    -- Show optional flag
    if display_config.show_optional and dep.optional then
        vt[#vt + 1] = { " [opt]", groups.info }
    end

    -- Show default-features flag
    if display_config.show_default_features and dep.default_features == false then
        vt[#vt + 1] = { " [no-default]", groups.info }
    end

    add_transition(vt)
    add_installed(vt, dep.installed)
    if dep.latest then
        add_divider(vt)
        add_latest(vt, dep.latest, dep.installed)
    end

    return vt
end

-- ============================================================================
-- Git dependency helpers
-- ============================================================================

--- Extract git info from raw value
---@param v table
---@return table
local function extract_git_info(v)
    local info = {
        url = v.git,
        branch = v.branch,
        tag = v.tag,
        rev = v.rev,
    }
    return info
end

--- Format git ref for display
---@param git table
---@return string
local function format_git_ref(git)
    if git.rev and #git.rev == 40 then
        return git.rev:sub(1, 7)
    elseif git.tag then
        return git.tag
    elseif git.branch then
        return git.branch
    end
    return ""
end

-- ============================================================================
-- Dependency type definitions
-- ============================================================================

---@type table<string, DependencyTypeDef>
M.dependency_types = {
    git = {
        type = "git",
        detect = function(v)
            return type(v) == "table" and v.git ~= nil
        end,
        extract = function(v, dep)
            dep.git = extract_git_info(v)
            if v.version then
                dep.declared = v.version
            end
        end,
        format = function(dep)
            local vt = {}
            local inst = dep.installed

            if dep.git and dep.git.url then
                vt[#vt + 1] = { "git:", groups.declared }
                vt[#vt + 1] = { dep.git.url, groups.declared }
                if dep.git.branch then
                    vt[#vt + 1] = { "@", groups.info }
                    vt[#vt + 1] = { "branch:", groups.declared }
                    vt[#vt + 1] = { dep.git.branch, groups.declared }
                elseif dep.git.tag then
                    vt[#vt + 1] = { "@", groups.info }
                    vt[#vt + 1] = { "tag:", groups.declared }
                    vt[#vt + 1] = { dep.git.tag, groups.declared }
                elseif dep.git.rev then
                    vt[#vt + 1] = { "@", groups.info }
                    vt[#vt + 1] = { "rev:", groups.declared }
                    vt[#vt + 1] = { format_git_ref(dep.git), groups.declared }
                end
            end

            add_transition(vt)
            add_installed(vt, inst)

            if dep.latest then
                add_divider(vt)
                add_latest(vt, dep.latest, inst)
            end

            return vt
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata)
        end,
    },

    path = {
        type = "path",
        detect = function(v)
            return type(v) == "table" and v.path ~= nil
        end,
        extract = function(v, dep)
            dep.path = {
                location = v.path,
            }
            if v.version then
                dep.declared = v.version
            end
        end,
        format = function(dep)
            local vt = {}
            vt[#vt + 1] = { "path:", groups.declared }
            if dep.path and dep.path.location then
                vt[#vt + 1] = { dep.path.location, groups.declared }
            end
            if dep.declared then
                vt[#vt + 1] = { " ", groups.declared }
                vt[#vt + 1] = { dep.declared, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            if dep.latest then
                add_divider(vt)
                add_latest(vt, dep.latest, dep.installed)
            end
            return vt
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata)
        end,
    },

    workspace = {
        type = "workspace",
        detect = function(v)
            return type(v) == "table" and v.workspace ~= nil
        end,
        extract = function(v, dep)
            dep.workspace = {
                workspace = true,
                version = v.version,
            }
            if v.version then
                dep.declared = v.version
            end
        end,
        format = function(dep)
            local vt = {}
            vt[#vt + 1] = { "workspace", groups.info }
            if dep.declared then
                vt[#vt + 1] = { " ", groups.declared }
                vt[#vt + 1] = { dep.declared, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            return vt
        end,
        format_hover = function(dep, latest, metadata)
            local lines = {}
            lines[#lines + 1] = "**Workspace dependency**"
            lines[#lines + 1] = "*Version is managed by workspace*"
            if dep.declared then
                lines[#lines + 1] = string.format("**Declared:** `%s`", dep.declared)
            end
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            if latest then
                lines[#lines + 1] = string.format("**Latest:** `%s`%s", latest, version_status(latest, dep.installed))
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },

    registry = {
        type = "registry",
        detect = function(v)
            if type(v) == "string" then
                return true
            end
            if type(v) == "table" and v.version ~= nil and v.git == nil and v.path == nil and v.workspace == nil then
                return true
            end
            return false
        end,
        extract = function(v, dep)
            if type(v) == "string" then
                dep.declared = v
            else
                dep.declared = v.version
                dep.features = v.features
                dep.optional = v.optional
                dep.default_features = v["default-features"]
            end
        end,
        format = function(dep)
            return standard_vt(dep, dep.declared or "Not declared")
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata, { show_fetching = true })
        end,
    },

    no_version = {
        type = "no_version",
        detect = function(v)
            return type(v) == "boolean" and v == true
        end,
        extract = function(_, dep)
            dep.declared = nil
        end,
        format = function(dep)
            return standard_vt(dep, "No version")
        end,
        format_hover = function(dep, latest, metadata)
            local lines = {}
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            if latest then
                lines[#lines + 1] = string.format("**Latest:** `%s`%s", latest, version_status(latest, dep.installed))
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },
}

return M
