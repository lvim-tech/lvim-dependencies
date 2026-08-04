-- lvim-dependencies.managers.composer.manifest: the static descriptor the core registry reads
-- to drive composer support — file/lock patterns, dependency sections, registry endpoint,
-- validation, and the per-type virtual-text / hover formatters. is_package_actionable is the
-- single seam that classifies platform requirements (php / ext-* / lib-* / composer-*), which
-- are not on packagist and cannot be require/remove'd, so every other module funnels through it.
--
---@module "lvim-dependencies.managers.composer.manifest"

local compare_version = require("lvim-dependencies.managers.composer.compare_versions")
local config = require("lvim-dependencies.config")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class ComposerManifest : ManagerManifest
local M = {}

-- ============================================================================
-- Manager identification
-- ============================================================================

M.key = "composer"

M.file_patterns = {
    "composer.json",
}

M.lock_files = {
    "composer.lock",
}

--- Sections inside composer.json that contain dependencies
M.dependency_sections = {
    "require",
    "require-dev",
}

--- Platform packages — not manageable via composer require/remove
--- Matches: "php", "php-64bit", "ext-json", "lib-curl", "composer-plugin-api"
---@param package_name string
---@return boolean
function M.is_package_actionable(package_name)
    if package_name == "php" then
        return false
    end
    if package_name:match("^php%-") then
        return false
    end
    if package_name:match("^ext%-") then
        return false
    end
    if package_name:match("^lib%-") then
        return false
    end
    if package_name:match("^composer%-") then
        return false
    end
    return true
end

--- Keys at root level that are NOT packages
M.special_keys = {
    "name",
    "description",
    "version",
    "type",
    "keywords",
    "homepage",
    "readme",
    "time",
    "license",
    "authors",
    "support",
    "funding",
    "require",
    "require-dev",
    "conflict",
    "replace",
    "provide",
    "suggest",
    "autoload",
    "autoload-dev",
    "include-path",
    "target-dir",
    "minimum-stability",
    "prefer-stable",
    "repositories",
    "config",
    "scripts",
    "extra",
    "bin",
    "archive",
    "abandoned",
    "non-feature-branches",
}

--- Patterns to match a package name on a line (JSON format)
M.package_patterns = {
    quoted = '^%s*"([^"]+/[^"]+)"%s*:',
}

-- ============================================================================
-- Registry and API
-- ============================================================================

M.default_registry = "https://packagist.org"

M.registry = {
    base_url = "https://packagist.org",
    --- Endpoint for latest version info
    --- Response: {"package": {"name": "...", "versions": {...}}}
    package_endpoint = "/packages/%s.json",
    response = {
        version_path = { "package", "versions" },
    },
}

M.api = {
    timeout = 10,
}

-- ============================================================================
-- Commands
-- ============================================================================

M.commands = {
    install = {
        composer = { "composer", "require" },
    },
    remove = {
        composer = { "composer", "remove" },
    },
    update = {
        composer = { "composer", "require" },
    },
    outdated = {
        composer = { "composer", "outdated" },
    },
}

-- ============================================================================
-- Validation
-- ============================================================================

M.package_validation = {
    -- Composer: vendor/package format
    pattern = "^[%w%-_%.]+/[%w%-_%.]+$",
    min_length = 3,
    max_length = 255,
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
    local is_versioned = installed and installed ~= "not installed" and installed:match("^%d")
    local cmp = is_versioned and compare_version.compare(latest, installed) or nil
    local is_current = is_versioned and cmp ~= nil and cmp ~= 1
    local icon = is_current and icons.up_to_date or icons.outdated
    local hl = is_current and groups.up_to_date or groups.outdated
    vt[#vt + 1] = { icon .. " ", hl }
    vt[#vt + 1] = { latest, hl }
end

local HOVER_METADATA_FIELDS = {
    { field = "description", label = "" },
    { field = "homepage", label = "Homepage" },
    { field = "repository", label = "Repository" },
    { field = "license", label = "License" },
    { field = "keywords", label = "Keywords" },
}

local function add_metadata(lines, metadata)
    if not metadata then
        return
    end
    for _, entry in ipairs(HOVER_METADATA_FIELDS) do
        local value = metadata[entry.field]
        if value then
            if entry.label == "" then
                if is_valid_string(value) then
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = value
                end
            elseif type(value) == "table" then
                local items = {}
                for _, item in ipairs(value) do
                    if is_valid_string(item) then
                        items[#items + 1] = item
                    end
                end
                if #items > 0 then
                    lines[#lines + 1] = string.format("**%s:** `%s`", entry.label, table.concat(items, ", "))
                end
            elseif is_valid_string(value) then
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

    --- Standard version constraint: "^1.0", "~2.3", "1.2.3", "*"
    registry = {
        type = "registry",
        detect = function(v)
            return type(v) == "string"
        end,
        extract = function(v, dep)
            dep.declared = v
        end,
        format = function(dep)
            return standard_vt(dep, dep.declared or "*")
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata, { show_fetching = true })
        end,
    },

    --- PHP platform requirement: "php", "ext-json", "lib-curl"
    platform = {
        type = "platform",
        detect = function(v)
            if type(v) ~= "string" then
                return false
            end
            return v:match("^php") ~= nil
                or v:match("^ext%-") ~= nil
                or v:match("^lib%-") ~= nil
                or v:match("^composer%-") ~= nil
        end,
        extract = function(v, dep)
            dep.declared = v
        end,
        format = function(dep)
            -- Show: platform → constraint (e.g. "^8.4")
            -- Never show "Not installed" — platform packages aren't in composer.lock
            local vt = { { "platform", groups.info } }
            if dep.declared and dep.declared ~= "" then
                add_transition(vt)
                vt[#vt + 1] = { dep.declared, groups.declared }
            end
            return vt
        end,
        format_hover = function(dep, _, metadata)
            local lines = { "**Platform requirement**" }
            if dep.declared then
                lines[#lines + 1] = string.format("**Constraint:** `%s`", dep.declared)
            end
            lines[#lines + 1] = "_Platform packages are not tracked in composer.lock_"
            add_metadata(lines, metadata)
            return lines
        end,
    },

    --- VCS/path repository: detected by URL or path patterns
    vcs = {
        type = "vcs",
        detect = function(v)
            if type(v) ~= "string" then
                return false
            end
            return v:match("^dev%-") ~= nil
        end,
        extract = function(v, dep)
            dep.declared = v
            dep.vcs = { ref = v:match("^dev%-(.+)") or v }
        end,
        format = function(dep)
            local vt = { { "dev:", groups.declared } }
            if dep.vcs then
                vt[#vt + 1] = { dep.vcs.ref, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            return vt
        end,
        format_hover = function(dep, _, metadata)
            local lines = {}
            if dep.vcs then
                lines[#lines + 1] = string.format("**Branch:** `%s`", dep.vcs.ref)
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
