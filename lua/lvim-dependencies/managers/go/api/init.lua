-- lvim-dependencies.managers.go.api: the public async action surface for the Go manager
-- (get-package-at-cursor, fetch-versions, update, delete). It fetches version lists from the
-- proxy (module paths are !-escaped for uppercase before the request), filters/limits them
-- per config, and delegates the actual mutating `go get` lifecycle to go_ops while keeping
-- the buffer/virtual-text caches coherent. The handler drives these; the returned table is
-- also what the operator dispatch ultimately calls into.
--
---@module "lvim-dependencies.managers.go.api"

local cache = require("lvim-dependencies.core.cache")
local vt = require("lvim-dependencies.core.virtual_text")
local hub_installed = require("lvim-dependencies.core.hub.installed")
local hub_latest = require("lvim-dependencies.core.hub.latest")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")
local utils = require("lvim-dependencies.utils")
local state = require("lvim-dependencies.core.state")
local init = require("lvim-dependencies.core.init")
local ui = require("lvim-dependencies.ui")

local parser = require("lvim-dependencies.managers.go.parser")
local compare_versions = require("lvim-dependencies.managers.go.compare_versions")
local go_ops = require("lvim-dependencies.managers.go.core.go_ops")
local data_installed = require("lvim-dependencies.managers.go.data.installed")
local data_latest = require("lvim-dependencies.managers.go.data.latest")

local debug = utils.debug
local api = vim.api

local CACHE_TYPE_INSTALLED = const.CACHE_TYPES.INSTALLED
local CACHE_TYPE_LATEST = const.CACHE_TYPES.LATEST

---@class GoActions
local M = {}

-- ============================================================================
-- Internal helpers
-- ============================================================================

--- Fire the User autocmd that tells the UI a package changed.
local function trigger_package_updated()
    api.nvim_exec_autocmds("User", { pattern = "LvimDepsPackageUpdated" })
end

--- Invalidate every cache layer (core, hub, go data, parser) for one module.
---@param name string
local function clear_package_caches(name)
    cache.clear("go", CACHE_TYPE_INSTALLED, name)
    cache.clear("go", CACHE_TYPE_LATEST, name)
    hub_installed.clear_cache("go", name)
    hub_latest.clear_cache("go", name)
    data_installed.clear_cache()
    data_latest.clear_cache()
    parser.clear_cache()
end

--- Mark a buffer unmodified and reload it from disk after go rewrote go.mod/go.sum.
---@param bufnr integer
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

--- Resolve the go binary: prefer the configured path, else fall back to $PATH.
---@return string|nil
local function get_executable()
    local configured = config.go and config.go.executables and config.go.executables.go
    if configured then
        local expanded = vim.fn.expand(configured)
        local path = vim.fn.exepath(expanded)
        if path and path ~= "" then
            return path
        end
    end
    local full_path = vim.fn.exepath("go")
    if full_path and full_path ~= "" then
        return full_path
    end
    if vim.fn.executable("go") == 1 then
        return "go"
    end
    return nil
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

    -- Inside require block: "\tgithub.com/pkg v1.0.0"
    local name = line:match("^%s+([%w%.%-%_/]+)%s+v[%w%.%-%+]+")
    if name then
        return name
    end
    -- Single-line: "require github.com/pkg v1.0.0"
    name = line:match("^require%s+([%w%.%-%_/]+)%s+v[%w%.%-%+]+")
    return name
end

---@param name string
---@param callback fun(data: VersionData|nil)
function M.fetch_versions_async(name, callback)
    if not name or name == "" then
        callback(nil)
        return
    end

    local manifest_data = init.get_manifest("go")
    local proxy_base = (config.go and config.go.api and config.go.api.proxy_base)
        or (manifest_data and manifest_data.registry and manifest_data.registry.base_url)
        or "https://proxy.golang.org"

    local timeout = (config.go and config.go.api and config.go.api.timeout) or 10

    -- Encode module path for proxy
    local encoded = (name:gsub("[A-Z]", function(c)
        return "!" .. c:lower()
    end))
    local url = proxy_base .. "/" .. encoded .. "/@v/list"

    vim.system({ "curl", "-fsS", "--max-time", tostring(timeout), url }, { text = true }, function(res)
        vim.schedule(function()
            if not res or res.code ~= 0 or not res.stdout then
                callback({ versions = {}, current = nil })
                return
            end

            local versions = {}
            local inc_pre = config.go and config.go.version and config.go.version.include_prerelease
            for line in res.stdout:gmatch("[^\n]+") do
                local ver = line:match("^%s*(v[%w%.%-%+]+)%s*$")
                if ver then
                    local is_pre = compare_versions.is_prerelease(ver)
                    if not is_pre or inc_pre then
                        versions[#versions + 1] = ver
                    end
                end
            end

            compare_versions.sort_desc(versions)

            local max = (config.go and config.go.version and config.go.version.max_versions) or 50
            if #versions > max then
                local limited = {}
                for i = 1, max do
                    limited[i] = versions[i]
                end
                versions = limited
            end

            -- Get current installed version from go.sum
            data_installed.get_package_installed(name, function(_, current)
                callback({ versions = versions, current = current })
            end)
        end)
    end)
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

    local path = parser.find_go_mod_path()
    if not path then
        callback({ success = false, message = "go.mod not found", packages = {} })
        return
    end

    -- Delegate to go_ops which handles the full lifecycle:
    -- Working indicator, seed_installed_version, VT refresh, checktime
    go_ops.run_go_update(path, name, version, opts, callback)
end

---@param name string
---@param opts DeleteOptions
---@param callback InstallerCallback
function M.delete(name, opts, callback)
    opts = opts or {}
    local path = parser.find_go_mod_path()
    if not path then
        callback({ success = false, message = "go.mod not found", packages = {} })
        return
    end

    ui.select(
        "Confirm Delete",
        string.format("Package: %s", name),
        "This will remove the module from go.mod and go.sum.",
        { "Yes, delete", "No, cancel" },
        function(confirmed, idx)
            if not confirmed or idx ~= 1 then
                callback({ success = false, message = "cancelled", packages = {} })
                return
            end

            local exe = get_executable()
            if not exe then
                callback({ success = false, message = "go not found", packages = {} })
                return
            end

            local cmd = { exe, "get", name .. "@none" }
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
                        local err = res and go_ops.extract_go_error(res) or "unknown error"
                        callback({ success = false, message = err, packages = {}, no_retry = true })
                    end
                end)
            end)
        end,
        { default_index = 2 }
    )
end

return M
