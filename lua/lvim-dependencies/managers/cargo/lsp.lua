-- lvim-dependencies.managers.cargo.lsp: LSP extensions for the cargo manager. Provides the
-- hover markdown for a dependency (declared/installed/latest + git/path/workspace details and
-- crates.io metadata), a "Manage features" code action, and the vim.lsp command that action
-- invokes to open the features UI. Registered lazily (see register.lua) so it costs nothing
-- until an LSP client is active on a Cargo.toml.
---@module "lvim-dependencies.managers.cargo.lsp"

local actions = require("lvim-dependencies.managers.cargo.api")
local cache = require("lvim-dependencies.core.cache")
local features = require("lvim-dependencies.managers.cargo.features")

---@class CargoLsp
local M = {}

-- ============================================================================
-- Internal helpers — use cache API, never touch cache internals directly
-- ============================================================================

---@param pkg string
---@return string|nil
local function get_installed_version(pkg)
    local data = cache.get_installed("cargo", { pkg })
    local val = data and data[pkg]
    if type(val) == "table" then
        return val.version
    end
    return val
end

---@param pkg string
---@return any
local function get_declared_data(pkg)
    local data = cache.get_declared("cargo", { pkg })
    return data and data[pkg]
end

---@param declared_data any
---@return string
local function detect_dependency_type(declared_data)
    if not declared_data then
        return "registry"
    end
    if type(declared_data) == "table" then
        if declared_data.git then
            return "git"
        end
        if declared_data.path then
            return "path"
        end
        if declared_data.workspace then
            return "workspace"
        end
    end
    return "registry"
end

-- ============================================================================
-- CODE ACTIONS
-- ============================================================================

---@param params table
---@param bufnr integer
---@param pkg string|nil
---@return table[]
function M.get_actions(params, bufnr, pkg)
    if not pkg then
        pkg = actions.get_package_at_cursor({
            bufnr = bufnr,
            cursor_line = params.position and params.position.line,
        })
    end
    if not pkg then
        return {}
    end

    return {
        {
            title = string.format("Manage features for %s", pkg),
            kind = "quickfix",
            command = {
                title = "Manage features",
                command = "lvim-dependencies.cargo.features",
                arguments = { pkg },
            },
        },
    }
end

-- ============================================================================
-- HOVER
-- ============================================================================

---@param params table
---@param bufnr integer
---@param dep_name string|nil
---@param dep_data table|nil
---@return table|nil
function M.get_hover(params, bufnr, dep_name, dep_data)
    local pkg = dep_name
    if not pkg then
        pkg = actions.get_package_at_cursor({
            bufnr = bufnr,
            cursor_line = params.position and params.position.line,
        })
    end
    if not pkg then
        return nil
    end

    local declared_data = dep_data and dep_data.decl or get_declared_data(pkg)
    local latest_version = dep_data and dep_data.latest and dep_data.latest.version or nil
    local metadata = dep_data and dep_data.latest and dep_data.latest.metadata or {}
    local installed_version = dep_data and dep_data.installed or get_installed_version(pkg)
    local dep_type = detect_dependency_type(declared_data)

    local lines = {
        string.format("# %s", pkg),
        "",
        string.format("**Type:** `%s`", dep_type),
    }

    if declared_data then
        if type(declared_data) == "table" then
            if declared_data.version then
                lines[#lines + 1] = string.format("**Declared:** `%s`", declared_data.version)
            end
            if declared_data.features and #declared_data.features > 0 then
                lines[#lines + 1] = ""
                lines[#lines + 1] = "**Features:**"
                for _, feature in ipairs(declared_data.features) do
                    lines[#lines + 1] = string.format("- `%s`", feature)
                end
            end
            if declared_data.optional then
                lines[#lines + 1] = string.format("**Optional:** `%s`", tostring(declared_data.optional))
            end
            if declared_data.default_features == false then
                lines[#lines + 1] = "**Default features:** `false`"
            end
            if declared_data.git then
                lines[#lines + 1] = ""
                lines[#lines + 1] = "**Git:**"
                lines[#lines + 1] = string.format("- url: `%s`", declared_data.git.url)
                if declared_data.git.branch then
                    lines[#lines + 1] = string.format("- branch: `%s`", declared_data.git.branch)
                end
                if declared_data.git.tag then
                    lines[#lines + 1] = string.format("- tag: `%s`", declared_data.git.tag)
                end
                if declared_data.git.rev then
                    lines[#lines + 1] = string.format("- rev: `%s`", declared_data.git.rev)
                end
            end
            if declared_data.path then
                lines[#lines + 1] = string.format("**Path:** `%s`", declared_data.path.location)
            end
            if declared_data.workspace then
                lines[#lines + 1] = "**Workspace:** `true`"
            end
        else
            lines[#lines + 1] = string.format("**Declared:** `%s`", tostring(declared_data))
        end
    end

    if installed_version then
        lines[#lines + 1] = string.format("**Installed:** `%s`", installed_version)
    end
    if latest_version then
        lines[#lines + 1] = string.format("**Latest:** `%s`", latest_version)
    end

    if metadata and next(metadata) then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "**Metadata:**"
        for k, v in pairs(metadata) do
            lines[#lines + 1] = string.format("- `%s`: %s", k, tostring(v))
        end
    end

    return { contents = { kind = "markdown", value = table.concat(lines, "\n") } }
end

-- ============================================================================
-- LSP COMMANDS
-- ============================================================================

--- Register the vim.lsp command that the "Manage features" code action resolves to.
---@return nil
function M.setup_commands()
    if not vim.lsp.commands["lvim-dependencies.cargo.features"] then
        vim.lsp.commands["lvim-dependencies.cargo.features"] = function(command)
            local args = command.arguments or {}
            local pkg = args[1] and tostring(args[1]) or nil
            local bufnr = vim.api.nvim_get_current_buf()
            if pkg then
                features.show_ui(pkg, bufnr)
            end
        end
    end
end

--- Entry point for LSP-side setup (called from register.register_lsp).
---@return nil
function M.setup()
    M.setup_commands()
end

return M
