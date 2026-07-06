-- lvim-dependencies.managers.pubspec.manifest: the static description of the pubspec ecosystem.
-- Declares the technical facts (file/lock patterns, dependency sections, SDK/special keys,
-- pub.dev registry endpoints, flutter/dart CLI commands) AND the per-dependency-type render logic
-- (M.dependency_types): each type knows how to detect itself from a raw YAML value, extract its
-- fields, and format both the inline virtual text and the hover lines. The values marked
-- "overridden by config.*" are defaults the live config layers on top of.
--
---@module "lvim-dependencies.managers.pubspec.manifest"

local compare_version = require("lvim-dependencies.managers.pubspec.compare_versions")
local config = require("lvim-dependencies.config")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class PubspecManifest
local M = {}

-- ============================================================================
-- Manager identification and detection (TECHNICAL - stays here)
-- ============================================================================

M.key = "pubspec"

M.file_patterns = {
    "pubspec.yaml",
    "pubspec.yml",
}

M.lock_files = { "pubspec.lock" }

M.dependency_sections = {
    "dependencies",
    "dev_dependencies",
    "dependency_overrides",
}

M.sdk_packages = {
    flutter = true,
    flutter_test = true,
    flutter_web_plugins = true,
}

M.special_keys = {
    "git",
    "url",
    "ref",
    "branch",
    "path",
    "sdk",
    "dependencies",
    "dev_dependencies",
    "dependency_overrides",
    "environment",
    "version",
    "name",
    "description",
    "publish_to",
    "assets",
    "fonts",
    "family",
    "image_path",
    "platforms",
    "android",
    "ios",
    "macos",
    "windows",
    "linux",
    "web",
    "flutter_localizations",
}

M.package_patterns = {
    simple = "^%s*([%w_%-]+)%s*:%s*[\"']?[%^~=<>]?[%d%.]+",
    any = "^%s*([%w_%-]+)%s*:%s*[\"']?any[\"']?%s*$",
    complex = "^%s*([%w_%-]+)%s*:%s*{",
    git = "^%s*([%w_%-]+)%s*:%s*git:",
    path = "^%s*([%w_%-]+)%s*:%s*path:",
    sdk = "^%s*([%w_%-]+)%s*:%s*sdk:",
    bare = "^%s*([%w_%-]+)%s*:%s*$",
}

-- ============================================================================
-- Registry and API configuration (TECHNICAL - stays here)
-- ============================================================================

M.default_registry = "https://pub.dev/api"

M.registry = {
    base_url = "https://pub.dev/api",
    package_endpoint = "/packages/%s",
    response = {
        version_path = { "latest", "version" },
        versions_path = { "versions" },
    },
}

-- The timeout value is now overridden by config.pubspec.api.timeout
M.api = {
    timeout = 10, -- Default, can be overridden by config
}

-- ============================================================================
-- Commands and project detection (TECHNICAL - stays here)
-- ============================================================================

M.commands = {
    remove = {
        flutter = { "flutter", "pub", "remove" },
        dart = { "dart", "pub", "remove" },
    },
    get = {
        flutter = { "flutter", "pub", "get" },
        dart = { "dart", "pub", "get" },
    },
}

M.project_type_detectors = {
    flutter = "^%s*flutter%s*:",
}

-- ============================================================================
-- Formatting and validation (USER PREFERENCES - move to config)
-- ============================================================================

-- These values are now overridden by config.pubspec.file_ops
M.formatting = {
    indent = "  ", -- Overridden by config.pubspec.file_ops.indent
    sort_dependencies = false, -- Overridden by config.pubspec.sections.sort_alphabetically
}

M.package_validation = {
    pattern = "^[a-zA-Z][a-zA-Z0-9_]*$",
    min_length = 1,
    max_length = 64,
}

-- These values are now overridden by config.pubspec.virtual_text
M.virtual_text = {
    position = "eol", -- Overridden by config.ui.virtual_text.position
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
    local is_current = is_versioned and installed ~= nil and compare_version.compare(latest, installed) ~= 1

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
}

--- Append metadata lines for hover display
---@param lines string[]
---@param metadata table|nil
local function add_metadata(lines, metadata)
    if not metadata then
        return
    end

    for _, entry in ipairs(HOVER_METADATA_FIELDS) do
        if is_valid_string(metadata[entry.field]) then
            if entry.label == "" then
                lines[#lines + 1] = ""
                lines[#lines + 1] = metadata[entry.field]
            else
                lines[#lines + 1] = string.format("**%s:** `%s`", entry.label, metadata[entry.field])
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

--- Build standard virtual text: declared → installed → latest
---@param dep table
---@param declared_text string
---@return VirtualTextChunk[]
local function standard_vt(dep, declared_text)
    local vt = {}
    vt[#vt + 1] = { declared_text, groups.declared }
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

--- Extract git reference info from raw dependency value
---@param v table Raw dependency value
---@param g table|string Git field value
---@return table git_info
local function extract_git_info(v, g)
    local info = {}

    if type(g) == "string" then
        info.url = g
        info.ref = v.ref or v.branch or v.tag
    elseif type(g) == "table" then
        info.url = g.url
        info.ref = g.ref or g.branch or g.tag or v.ref or v.branch or v.tag
        info.path = g.path or v.path
    end

    if v.ref then
        info.ref_type = "tag"
        info.ref_value = v.ref
    elseif v.branch then
        info.ref_type = "branch"
        info.ref_value = v.branch
    elseif v.tag then
        info.ref_type = "tag"
        info.ref_value = v.tag
    end

    if info.ref and #info.ref == 40 and info.ref:match("^[a-f0-9]+$") then
        info.is_commit = true
        info.ref_type = "commit"
    end

    return info
end

--- Format git ref for display (truncate commits to 7 chars)
---@param git table
---@return string
local function display_ref(git)
    if git.is_commit then
        return git.ref:sub(1, 7)
    end
    return git.ref
end

-- ============================================================================
-- Dependency type definitions
-- ============================================================================

---@type table<string, DependencyTypeDef>
M.dependency_types = {
    no_version = {
        type = "no_version",
        detect = function(v)
            if type(v) == "boolean" and v == true then
                return true
            end
            if type(v) == "table" then
                return next(v) == nil
            end
            return false
        end,
        extract = function(_, dep)
            dep.declared = nil
        end,
        format = function(dep)
            return standard_vt(dep, "Not declared")
        end,
        format_hover = function(dep, _, metadata)
            local lines = {}
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },

    git = {
        type = "git",
        detect = function(v)
            return type(v) == "table" and v.git ~= nil
        end,
        extract = function(v, dep)
            dep.git = extract_git_info(v, v.git)
        end,
        format = function(dep)
            local vt = {}
            local git = dep.git

            if git and git.url then
                vt[#vt + 1] = { git.url, groups.declared }
                if git.ref then
                    vt[#vt + 1] = { "@", groups.info }
                    vt[#vt + 1] = { "ref:", groups.declared }
                    vt[#vt + 1] = { display_ref(git), groups.declared }
                end
                if git.path then
                    vt[#vt + 1] = { "@", groups.info }
                    vt[#vt + 1] = { "path:", groups.declared }
                    vt[#vt + 1] = { git.path, groups.declared }
                end
            end

            add_transition(vt)

            local inst = dep.installed
            if inst == "not installed" then
                vt[#vt + 1] = { "Not installed", groups.installed }
            elseif inst and inst:match("^%d") then
                vt[#vt + 1] = { inst, groups.installed }
            end

            if dep.latest then
                add_divider(vt)
                add_latest(vt, dep.latest, inst)
            end

            return vt
        end,
        format_hover = function(dep, _, metadata)
            local lines = {}
            local git = dep.git

            if git and git.url then
                lines[#lines + 1] = string.format("**Git URL:** `%s`", git.url)
                if git.ref then
                    lines[#lines + 1] = string.format("**Ref:** `%s`", display_ref(git))
                end
                if git.path then
                    lines[#lines + 1] = string.format("**Path:** `%s`", git.path)
                end
            end
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end

            add_metadata(lines, metadata)
            return lines
        end,
    },

    path = {
        type = "path",
        detect = function(v)
            return type(v) == "table" and v.path ~= nil
        end,
        extract = function(v, dep)
            dep.path = { location = type(v.path) == "string" and v.path or nil }
        end,
        format = function(dep)
            local vt = {}
            vt[#vt + 1] = { "path:", groups.declared }
            if dep.path and dep.path.location then
                vt[#vt + 1] = { dep.path.location, groups.declared }
            end
            add_transition(vt)
            if dep.installed == "not installed" then
                vt[#vt + 1] = { "Not installed", groups.installed }
            elseif dep.installed == "path" then
                vt[#vt + 1] = { "installed", groups.installed }
            end
            if dep.latest then
                add_divider(vt)
                add_latest(vt, dep.latest, dep.installed)
            end
            return vt
        end,
        format_hover = function(dep, _, metadata)
            local lines = {}
            if dep.path and dep.path.location then
                lines[#lines + 1] = string.format("**Path:** `%s`", dep.path.location)
            end
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },

    sdk = {
        type = "sdk",
        detect = function(v)
            return type(v) == "table" and v.sdk ~= nil
        end,
        extract = function(v, dep)
            dep.sdk = { name = v.sdk }
            if M.sdk_packages[dep.name] then
                dep.sdk.name = "flutter"
            end
        end,
        format = function(dep)
            local vt = {}
            if dep.sdk and dep.sdk.name then
                if icons.sdk then
                    vt[#vt + 1] = { icons.sdk .. " ", groups.sdk }
                end
                local ver = dep.installed or "sdk"
                vt[#vt + 1] = { string.format("%s (sdk)", ver), "LvimDepsInfo" }
            end
            return vt
        end,
        format_hover = function(dep, _, metadata)
            local lines = {}
            if dep.sdk and dep.sdk.name then
                lines[#lines + 1] = string.format("**SDK:** `%s`", dep.sdk.name)
            end
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },

    hosted = {
        type = "hosted",
        detect = function(v)
            return type(v) == "table" and v.hosted ~= nil
        end,
        extract = function(v, dep)
            dep.hosted = {
                url = type(v.hosted.url) == "string" and v.hosted.url or nil,
                version = v.version,
            }
            if v.version then
                dep.declared = v.version
            end
        end,
        format = function(dep)
            local vt = {}
            vt[#vt + 1] = { "hosted", groups.declared }
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
            local lines = standard_hover(dep, latest, metadata)
            if dep.hosted and dep.hosted.url then
                -- Insert registry before metadata
                lines[#lines + 1] = string.format("**Registry:** `%s`", dep.hosted.url)
            end
            return lines
        end,
    },

    registry = {
        type = "registry",
        detect = function(v)
            return type(v) == "string"
        end,
        extract = function(v, dep)
            dep.declared = v
        end,
        format = function(dep)
            return standard_vt(dep, dep.declared or "Not declared")
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata, { show_fetching = true })
        end,
    },

    complex = {
        type = "complex",
        detect = function(v)
            return type(v) == "table" and not v.git and not v.path and not v.sdk and not v.hosted and next(v) ~= nil
        end,
        extract = function() end,
        format = function()
            return { { "Invalid", "LvimDepsInvalidVersion" } }
        end,
        format_hover = function(_, _, metadata)
            local lines = { "**Invalid dependency format**" }
            add_metadata(lines, metadata)
            return lines
        end,
    },
}

return M
