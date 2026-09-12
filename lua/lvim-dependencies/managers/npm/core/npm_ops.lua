-- lvim-dependencies.managers.npm.core.npm_ops: which package manager runs for a project and how
-- its add / remove commands are spelled. The manager comes from `config.npm.preferred_manager`,
-- else from the lock file found next to the manifest (pnpm-lock.yaml → pnpm, yarn.lock → yarn,
-- otherwise npm); the executable honours `config.npm.executables`. The api layer runs the
-- commands; the update / remove lifecycle that used to live here duplicated the api's and had
-- no caller.
--
---@module "lvim-dependencies.managers.npm.core.npm_ops"

local config = require("lvim-dependencies.config")

---@class NpmOps
local M = {}

-- ============================================================================
-- Executable resolution
-- ============================================================================

--- Get executable path with config override support
---@param cmd_key string  "npm" | "yarn" | "pnpm"
---@return string|nil
local function get_executable(cmd_key)
    local configured = config.npm and config.npm.executables and config.npm.executables[cmd_key]
    if configured then
        local expanded = vim.fn.expand(configured)
        local path = vim.fn.exepath(expanded)
        if path and path ~= "" then
            return path
        end
    end
    local full_path = vim.fn.exepath(cmd_key)
    if full_path and full_path ~= "" then
        return full_path
    end
    if vim.fn.executable(cmd_key) == 1 then
        return cmd_key
    end
    return nil
end

--- Detect which package manager to use for a project: the configured preference, else the
--- lock file found upward from the manifest (a workspace package's lock sits at the root).
---@param manifest_path? string  the package.json being acted on (nil = cwd)
---@return string exe, string pm_type
function M.detect_package_manager(manifest_path)
    -- Explicit override in config
    local preferred = config.npm and config.npm.preferred_manager
    if preferred then
        local exe = get_executable(preferred)
        if exe then
            return exe, preferred
        end
    end

    local start = manifest_path and vim.fs.dirname(manifest_path) or vim.fn.getcwd()
    local function has_lock(name)
        local found = vim.fs.find(name, { upward = true, path = start, type = "file" })
        return found and found[1] ~= nil
    end

    -- pnpm-lock.yaml → pnpm
    if has_lock("pnpm-lock.yaml") then
        local exe = get_executable("pnpm")
        if exe then
            return exe, "pnpm"
        end
    end

    -- yarn.lock → yarn
    if has_lock("yarn.lock") then
        local exe = get_executable("yarn")
        if exe then
            return exe, "yarn"
        end
    end

    -- default: npm
    local exe = get_executable("npm") or "npm"
    return exe, "npm"
end

-- ============================================================================
-- Command builders
-- ============================================================================

--- Build add/update command for a package
---@param exe string
---@param pm_type string
---@param name string
---@param version string
---@param section string  dependency section
---@return string[]
function M.build_add_cmd(exe, pm_type, name, version, section)
    local pkg_spec = name .. "@" .. version
    local cmd = { exe }

    if pm_type == "yarn" then
        table.insert(cmd, "add")
        if section == "devDependencies" then
            table.insert(cmd, "--dev")
        end
        if section == "peerDependencies" then
            table.insert(cmd, "--peer")
        end
        if section == "optionalDependencies" then
            table.insert(cmd, "--optional")
        end
    elseif pm_type == "pnpm" then
        table.insert(cmd, "add")
        if section == "devDependencies" then
            table.insert(cmd, "--save-dev")
        end
        if section == "peerDependencies" then
            table.insert(cmd, "--save-peer")
        end
        if section == "optionalDependencies" then
            table.insert(cmd, "--save-optional")
        end
    else
        -- npm
        table.insert(cmd, "install")
        if section == "devDependencies" then
            table.insert(cmd, "--save-dev")
        end
        if section == "peerDependencies" then
            table.insert(cmd, "--save-peer")
        end
        if section == "optionalDependencies" then
            table.insert(cmd, "--save-optional")
        end
    end

    table.insert(cmd, pkg_spec)
    return cmd
end

--- Build remove command
---@param exe string
---@param pm_type string
---@param name string
---@return string[]
function M.build_remove_cmd(exe, pm_type, name)
    if pm_type == "yarn" then
        return { exe, "remove", name }
    end
    if pm_type == "pnpm" then
        return { exe, "remove", name }
    end
    return { exe, "uninstall", name }
end

return M
