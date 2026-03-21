-- lvim-dependencies/managers/npm/api/init.lua
-- Public API for npm/yarn/pnpm package actions

---@include "core/types.lua"

local cache = require("lvim-dependencies.core.cache")
local vt = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")
local state = require("lvim-dependencies.core.state")

local parser = require("lvim-dependencies.managers.npm.parser")
local compare_versions = require("lvim-dependencies.managers.npm.compare_versions")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED

---@class NpmActions
local M = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function trigger_package_updated()
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

local function clear_package_caches(name)
    cache.clear("npm", CACHE_TYPE_INSTALLED, name)
    hub_installed.clear_cache("npm", name)
    require("lvim-dependencies.managers.npm.data.installed").clear_cache()
    parser.clear_cache()
end

local function refresh_buffer_state(bufnr)
    if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    local buf_state = state.get_buffer_state(bufnr)
    buf_state.skip_next_check = true
    vim.bo[bufnr].modified = false
    api.nvim_buf_call(bufnr, function()
        vim.cmd("checktime")
    end)
end

--- Detect which package manager to use for this project
---@return string executable, string type
local function detect_package_manager()
    local cwd = vim.fn.getcwd()

    -- pnpm-lock.yaml → pnpm
    if vim.fn.filereadable(cwd .. "/pnpm-lock.yaml") == 1 then
        local pnpm = vim.fn.exepath("pnpm")
        if pnpm ~= "" then
            return pnpm, "pnpm"
        end
    end

    -- yarn.lock → yarn
    if vim.fn.filereadable(cwd .. "/yarn.lock") == 1 then
        local yarn = vim.fn.exepath("yarn")
        if yarn ~= "" then
            return yarn, "yarn"
        end
    end

    -- default: npm
    local npm = vim.fn.exepath("npm")
    return npm ~= "" and npm or "npm", "npm"
end

--- Build install/update command
---@param exe string
---@param pm_type string
---@param name string
---@param version string
---@param section string
---@return string[]
local function build_add_cmd(exe, pm_type, name, version, section)
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
        table.insert(cmd, pkg_spec)
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
        table.insert(cmd, pkg_spec)
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
        table.insert(cmd, pkg_spec)
    end

    return cmd
end

--- Build remove command
---@param exe string
---@param pm_type string
---@param name string
---@return string[]
local function build_remove_cmd(exe, pm_type, name)
    if pm_type == "yarn" then
        return { exe, "remove", name }
    end
    if pm_type == "pnpm" then
        return { exe, "remove", name }
    end
    return { exe, "uninstall", name } -- npm
end

-- ============================================================================
-- Public API
-- ============================================================================

---@param opts? {bufnr?: integer, cursor_line?: integer}
---@return string|nil
function M.get_package_at_cursor(opts)
    opts = opts or {}
    local bufnr = opts.bufnr or api.nvim_get_current_buf()
    if not api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local cursor_line = opts.cursor_line
    if cursor_line == nil then
        cursor_line = api.nvim_win_get_cursor(0)[1] - 1
    end

    local line = api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1]
    if not line then
        return nil
    end

    -- JSON: "  "pkg": "version""
    return line:match('^%s*"([^"]+)"%s*:')
end

---@param name string
---@param callback fun(data: VersionData|nil)
function M.fetch_versions_async(name, callback)
    if not name or name == "" then
        callback(nil)
        return
    end

    local manifest_data = require("lvim-dependencies.core.init").get_manifest("npm")
    local registry_base = (config.npm and config.npm.api and config.npm.api.registry_base)
        or (manifest_data and manifest_data.registry and manifest_data.registry.base_url)
        or "https://registry.npmjs.org"

    local timeout = (config.npm and config.npm.api and config.npm.api.timeout) or 10
    -- Encode scoped packages: @babel/core → @babel%2Fcore
    -- Without this, npm treats /@babel/core as scope @babel + path /core
    local encoded = name:match("^@") and name:gsub("/", "%%2F", 1) or name
    local url = registry_base .. "/" .. encoded

    vim.system({ "curl", "-fsS", "--max-time", tostring(timeout), url }, { text = true }, function(res)
        vim.schedule(function()
            if not res or res.code ~= 0 or not res.stdout then
                callback({ versions = {}, current = nil })
                return
            end

            local ok, data = pcall(vim.json.decode, res.stdout)
            if not ok or type(data) ~= "table" then
                callback({ versions = {}, current = nil })
                return
            end

            local versions = {}
            if data.versions then
                local inc_pre = config.npm and config.npm.version and config.npm.version.include_prerelease
                for ver in pairs(data.versions) do
                    -- Semver prerelease: any version with "-" after patch number
                    -- e.g. "7.21.4-esm", "1.0.0-alpha.1", "2.0.0-rc.3"
                    local is_pre = ver:match("%d+%.%d+%.%d+%-") ~= nil
                    if not is_pre or inc_pre then
                        versions[#versions + 1] = ver
                    end
                end
            end

            compare_versions.sort_desc(versions)

            local max = (config.npm and config.npm.version and config.npm.version.max_versions) or 50
            if #versions > max then
                local limited = {}
                for i = 1, max do
                    limited[i] = versions[i]
                end
                versions = limited
            end

            -- Get current installed version from lock file
            local installed = require("lvim-dependencies.managers.npm.data.installed")
            installed.get_package_installed(name, function(_, current)
                callback({ versions = versions, current = current })
            end)
        end)
    end)
end

--- Find 0-based line number of a package in a buffer
---@param bufnr integer
---@param name string
---@return integer|nil
local function find_package_line(bufnr, name)
    if not bufnr or bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local pattern = string.format('^%%s*"%s"%%s*:', vim.pesc(name))
    for i, line in ipairs(lines) do
        if line:match(pattern) then
            return i - 1
        end
    end
    return nil
end

--- Extract a meaningful error message from a vim.system result
---@param res table
---@return string
local function extract_error(res)
    local output = (res.stderr and res.stderr ~= "" and res.stderr)
        or (res.stdout and res.stdout ~= "" and res.stdout)
        or ""
    if output ~= "" then
        for _, line in ipairs(vim.split(output, "\n")) do
            if line:match("^npm ERR!") or line:match("^yarn error") or line:match("^error") then
                return line
            end
        end
        local last = ""
        for _, line in ipairs(vim.split(output, "\n")) do
            if line:match("%S") then
                last = line
            end
        end
        if last ~= "" then
            return last
        end
    end
    return res.code and string.format("exit code %d", res.code) or "unknown error"
end

---@param name string
---@param opts UpdateOptions
---@param callback InstallerCallback
function M.update_async(name, opts, callback)
    if not name then
        callback({ success = false, message = "package name required", packages = {} })
        return
    end
    opts = opts or {}
    local version = opts.version
    if not version then
        callback({ success = false, message = "version required", packages = {} })
        return
    end

    local path = parser.find_package_json_path()
    if not path then
        callback({ success = false, message = "package.json not found", packages = {} })
        return
    end

    local exe, pm_type = detect_package_manager()
    if not exe or exe == "" then
        callback({ success = false, message = "no package manager found", packages = {} })
        return
    end

    -- Determine section for this package
    local all_deps = parser.get_dependencies()
    local pkg_raw = all_deps[name]
    local section = type(pkg_raw) == "table" and pkg_raw.section or "dependencies"

    local cmd = build_add_cmd(exe, pm_type, name, version, section)
    local cwd = vim.fn.fnamemodify(path, ":h")
    local bufnr = vim.fn.bufnr(path)

    -- Show working state in virtual text before the command runs
    local lnum0 = find_package_line(bufnr, name)
    if lnum0 and bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
        vt.display_loading_for_package(bufnr, "npm", { name = name, line = lnum0 }, "working")
    end

    debug(string.format("npm: running %s", table.concat(cmd, " ")), vim.log.levels.INFO)

    local function refresh_vt()
        if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
            return
        end
        local package_loader = require("lvim-dependencies.core.package_loader")
        package_loader.load_package_data_async("npm", name, function(package_data)
            if api.nvim_buf_is_valid(bufnr) then
                vt.update_package(bufnr, package_data)
            end
        end, { initial = false })
    end

    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            if res and res.code == 0 then
                parser.clear_cache()
                clear_package_caches(name)
                if bufnr ~= -1 then
                    refresh_buffer_state(bufnr)
                end
                trigger_package_updated()
                refresh_vt()
                callback({
                    success = true,
                    message = string.format("updated %s@%s", name, version),
                    packages = { name },
                })
            else
                local err = extract_error(res)
                refresh_vt()
                callback({ success = false, message = err, packages = {}, no_retry = true })
            end
        end)
    end)
end

---@param name string
---@param opts DeleteOptions
---@param callback InstallerCallback
function M.delete(name, opts, callback)
    opts = opts or {}
    local path = parser.find_package_json_path()
    if not path then
        callback({ success = false, message = "package.json not found", packages = {} })
        return
    end

    local ui = require("lvim-dependencies.ui")
    ui.select(
        "Confirm Delete",
        string.format("Package: %s", name),
        "This will remove the package and update lock files.",
        { "Yes, delete", "No, cancel" },
        function(confirmed, idx)
            if not confirmed or idx ~= 1 then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end

            local exe, pm_type = detect_package_manager()
            local cmd = build_remove_cmd(exe, pm_type, name)
            local cwd = vim.fn.fnamemodify(path, ":h")
            local bufnr = vim.fn.bufnr(path)

            vim.system(cmd, { cwd = cwd, text = true }, function(res)
                vim.schedule(function()
                    if res and res.code == 0 then
                        parser.clear_cache()
                        clear_package_caches(name)
                        if bufnr ~= -1 then
                            vt.remove_package(bufnr, name)
                            refresh_buffer_state(bufnr)
                        end
                        trigger_package_updated()
                        callback({ success = true, message = "removed successfully", packages = { name } })
                    else
                        local err = res and res.stderr and res.stderr:match("([^\n]+)") or "unknown error"
                        callback({ success = false, message = err, packages = {} })
                    end
                end)
            end)
        end,
        { default_index = 2 }
    )
end

return M
