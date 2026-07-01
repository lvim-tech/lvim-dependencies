-- lvim-dependencies.managers.npm.manifest: the static description of the npm/yarn/pnpm
-- ecosystem the core reads to drive parsing, fetching and rendering. It declares the manifest
-- file patterns, lock files, dependency sections, non-package root keys, registry endpoints
-- and per-manager CLI commands, plus the per-dependency-type virtual-text / hover formatters
-- (registry / workspace / git / path). Kept declarative so the generic core stays manager-agnostic.
--
---@module "lvim-dependencies.managers.npm.manifest"

local compare_version = require("lvim-dependencies.managers.npm.compare_versions")
local config = require("lvim-dependencies.config")

local icons = config.ui.virtual_text.icons
local groups = config.groups

---@class NpmManifest : ManagerManifest
local M = {}

-- ============================================================================
-- Manager identification
-- ============================================================================

M.key = "npm"

M.file_patterns = {
    "package.json",
}

M.lock_files = {
    "package-lock.json", -- npm
    "yarn.lock", -- yarn
    "pnpm-lock.yaml", -- pnpm
}

--- Sections inside package.json that contain dependencies
M.dependency_sections = {
    "dependencies",
    "devDependencies",
    "peerDependencies",
    "optionalDependencies",
}

--- Keys at root level that are NOT packages
M.special_keys = {
    "name",
    "version",
    "description",
    "main",
    "module",
    "types",
    "typings",
    "exports",
    "imports",
    "bin",
    "man",
    "files",
    "scripts",
    "config",
    "engines",
    "os",
    "cpu",
    "private",
    "publishConfig",
    "workspaces",
    "resolutions",
    "overrides",
    "packageManager",
    "license",
    "author",
    "contributors",
    "repository",
    "bugs",
    "homepage",
    "keywords",
    "type",
    "sideEffects",
    "browserslist",
    "jest",
    "eslintConfig",
    "prettier",
    "babel",
    "stylelint",
    "lint-staged",
    "husky",
}

--- Patterns to match a package name on a line (JSON format: "  "pkg": "version"")
M.package_patterns = {
    quoted = '^%s*"([^"]+)"%s*:',
}

-- ============================================================================
-- Registry and API
-- ============================================================================

M.default_registry = "https://registry.npmjs.org"

M.registry = {
    base_url = "https://registry.npmjs.org",
    --- Endpoint for stable latest version (include_prerelease = false)
    --- Response: {"version":"1.2.3","description":"...",...}
    package_endpoint = "/%s/latest",
    --- Endpoint for all dist-tags including prerelease (include_prerelease = true)
    --- Response: {"latest":"1.2.3","next":"1.3.0-beta.1","esm":"1.3.0-esm.4"}
    package_endpoint_prerelease = "/-/package/%s/dist-tags",
    response = {
        version_path = { "version" },
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
        npm = { "npm", "install" },
        yarn = { "yarn", "add" },
        pnpm = { "pnpm", "add" },
    },
    remove = {
        npm = { "npm", "uninstall" },
        yarn = { "yarn", "remove" },
        pnpm = { "pnpm", "remove" },
    },
    update = {
        npm = { "npm", "install" },
        yarn = { "yarn", "add" },
        pnpm = { "pnpm", "add" },
    },
    outdated = {
        npm = { "npm", "outdated" },
        yarn = { "yarn", "outdated" },
        pnpm = { "pnpm", "outdated" },
    },
}

-- ============================================================================
-- Validation
-- ============================================================================

M.package_validation = {
    pattern = "^(@[%w%-_%.]+/)?[%w%-_%.]+$",
    min_length = 1,
    max_length = 214,
}

M.virtual_text = {
    position = "eol",
    priority = 1000,
}

-- ============================================================================
-- Virtual text helpers
-- ============================================================================

--- True when `val` is a non-empty string (guards against vim.NIL from decoded JSON).
---@param val any
---@return boolean
local function is_valid_string(val)
    return val ~= nil and val ~= vim.NIL and type(val) == "string" and val ~= ""
end

--- Append a padded separator chunk to a virtual-text list.
---@param vt VirtualTextChunk[]
---@param sep string
---@param hl string
local function add_sep(vt, sep, hl)
    vt[#vt + 1] = { " " .. sep .. " ", hl }
end

---@param vt VirtualTextChunk[]
local function add_transition(vt)
    add_sep(vt, icons.separators.transition, groups.separator)
end

---@param vt VirtualTextChunk[]
local function add_divider(vt)
    add_sep(vt, icons.separators.divider, groups.separator)
end

---@param vt VirtualTextChunk[]
---@param installed string|nil
local function add_installed(vt, installed)
    if installed and installed ~= "not installed" then
        vt[#vt + 1] = { installed, groups.installed }
    else
        vt[#vt + 1] = { "Not installed", groups.installed }
    end
end

---@param vt VirtualTextChunk[]
---@param latest string
---@param installed string|nil
local function add_latest(vt, latest, installed)
    local is_versioned = installed and installed ~= "not installed" and installed:match("^%d")
    -- Use compare_numeric: prerelease compared by major.minor.patch only
    -- e.g. installed=7.18.6, latest=7.21.4-esm.4 → outdated (7.21 > 7.18)
    local is_current = is_versioned and compare_version.compare_numeric(latest, installed) == 0
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

--- Append registry metadata (description/homepage/repo/license/keywords) to hover lines.
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

--- Human-readable " (outdated)" / " (up to date)" suffix for a hover line.
---@param latest string
---@param installed string|nil
---@return string
local function version_status(latest, installed)
    if not installed or installed == "not installed" then
        return ""
    end
    local cmp = compare_version.compare_numeric(latest, installed)
    if cmp == 1 then
        return " (outdated)"
    elseif cmp == 0 then
        return " (up to date)"
    end
    return ""
end

--- Build the standard "declared → installed ┊ latest" virtual-text row.
---@param dep table
---@param declared_text string
---@return VirtualTextChunk[]
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

--- Build the standard hover markdown (declared/installed/latest + metadata).
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

-- ============================================================================
-- Dependency type definitions
-- ============================================================================

---@type table<string, DependencyTypeDef>
M.dependency_types = {

    --- Standard semver version: "^1.0.0", "~2.3.4", "1.2.3", "*"
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
            return standard_vt(dep, dep.declared or "*")
        end,
        format_hover = function(dep, latest, metadata)
            return standard_hover(dep, latest, metadata, { show_fetching = true })
        end,
    },

    --- Workspace protocol: "workspace:*", "workspace:^1.0.0"
    workspace = {
        type = "workspace",
        detect = function(v)
            return type(v) == "string" and v:match("^workspace:")
        end,
        extract = function(v, dep)
            dep.declared = v
            dep.workspace = { ref = v:match("^workspace:(.*)") or "*" }
        end,
        format = function(dep)
            local vt = { { "workspace", groups.info } }
            if dep.workspace and dep.workspace.ref ~= "*" then
                vt[#vt + 1] = { ":" .. dep.workspace.ref, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            return vt
        end,
        -- _latest: workspace deps don't have a registry latest version
        ---@diagnostic disable-next-line: unused-local
        format_hover = function(dep, latest, metadata)
            local lines = { "**Workspace dependency**" }
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

    --- Git URL: "git+https://...", "git://...", "github:user/repo", "user/repo"
    git = {
        type = "git",
        detect = function(v)
            if type(v) ~= "string" then
                return false
            end
            return v:match("^git%+")
                or v:match("^git://")
                or v:match("^github:")
                or v:match("^gitlab:")
                or v:match("^bitbucket:")
                or v:match("^[%w%-]+/[%w%-_%.]+$")
        end,
        extract = function(v, dep)
            dep.declared = v
            dep.git = { url = v }
        end,
        format = function(dep)
            local vt = { { "git:", groups.declared } }
            if dep.git then
                vt[#vt + 1] = { dep.git.url, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            return vt
        end,
        -- _latest: git deps don't have a meaningful registry latest
        ---@diagnostic disable-next-line: unused-local
        format_hover = function(dep, latest, metadata)
            local lines = {}
            if dep.git then
                lines[#lines + 1] = string.format("**Git:** `%s`", dep.git.url)
            end
            if dep.installed then
                lines[#lines + 1] = string.format("**Installed:** `%s`", dep.installed)
            end
            add_metadata(lines, metadata)
            return lines
        end,
    },

    --- Local path: "file:../local-pkg", "link:../local-pkg"
    path = {
        type = "path",
        detect = function(v)
            if type(v) ~= "string" then
                return false
            end
            return v:match("^file:") or v:match("^link:") or v:match("^%.%./") or v:match("^%./")
        end,
        extract = function(v, dep)
            dep.declared = v
            dep.path = { location = v:gsub("^file:", ""):gsub("^link:", "") }
        end,
        format = function(dep)
            local vt = { { "path:", groups.declared } }
            if dep.path then
                vt[#vt + 1] = { dep.path.location, groups.declared }
            end
            add_transition(vt)
            add_installed(vt, dep.installed)
            return vt
        end,
        -- _latest: local path deps don't have a registry latest
        ---@diagnostic disable-next-line: unused-local
        format_hover = function(dep, latest, metadata)
            local lines = {}
            if dep.path then
                lines[#lines + 1] = string.format("**Path:** `%s`", dep.path.location)
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
