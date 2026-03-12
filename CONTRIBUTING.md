# Contributing to lvim-dependencies

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Adding a New Package Manager](#adding-a-new-package-manager)
- [File Structure Reference](#file-structure-reference)
- [API Contract](#api-contract)
- [Operation Lifecycle](#operation-lifecycle)
- [Type System](#type-system)
- [Conventions](#conventions)
- [Testing](#testing)

---

## Architecture Overview

```
lua/lvim-dependencies/
├── config/                   — per-section default configuration
│   ├── init.lua              — aggregates all config submodules
│   ├── highlight.lua         — highlight group names and default colors
│   ├── ui.lua                — virtual text icons, popup, float settings
│   ├── lsp.lua               — LSP on_attach, actions, hover toggles
│   ├── cache.lua             — TTL, cleanup, stats
│   ├── async.lua             — concurrency, retry, debounce, throttle
│   ├── message.lua           — notify, debug, metrics settings
│   ├── npm.lua / cargo.lua / go.lua / composer.lua / pubspec.lua
│   └── ...
├── core/
│   ├── registry.lua          — auto-discovers managers via manifest glob,
│   │                           calls register.lua for each
│   ├── operator.lua          — dispatches operations (install/update/delete)
│   ├── operation.lua         — builds operation descriptor tables
│   ├── virtual_text.lua      — orchestrates VT rendering across all buffers
│   ├── package_loader.lua    — loads declared/installed/latest data per buffer
│   ├── cache.lua             — multi-layer cache (declared/installed/latest/VT)
│   ├── state.lua             — per-buffer lifecycle state machine
│   ├── events.lua            — internal event bus
│   ├── metrics.lua           — performance and network metrics
│   ├── async_util.lua        — coroutine-based async helpers
│   ├── const.lua             — shared constants (COMMANDS, CACHE_TYPES, …)
│   ├── types.lua             — LuaLS type definitions shared by all managers
│   ├── init.lua              — core module loader / manifest accessor
│   ├── cli.lua               — :LvimDeps subcommand registry and built-ins
│   └── hub/
│       ├── declared.lua      — aggregates declared data from managers
│       ├── installed.lua     — aggregates installed data from managers
│       └── latest.lua        — aggregates latest data from managers
├── lsp/
│   ├── init.lua              — attaches LSP client to manifest buffers
│   ├── server.lua            — LSP server management
│   ├── hover.lua             — hover provider (delegates to manager)
│   └── action.lua            — code actions (update/delete/open links)
├── ui/
│   ├── popup.lua             — interactive floating version picker
│   └── float.lua             — read-only floating window
├── hooks/
│   ├── commands.lua          — :LvimDeps user command + tab completion
│   ├── autocommands.lua      — BufRead, BufWrite, BufEnter, TextChanged
│   └── help.lua              — help text generation
├── utils/
│   ├── init.lua              — re-exports: debug, notify, buffer, …
│   ├── notify.lua            — utils.notify wrapper over vim.notify
│   ├── debug.lua             — structured debug logging
│   ├── http.lua              — async HTTP via curl
│   ├── version.lua           — semver parser and comparator factory
│   ├── buffer.lua            — buffer helpers (fast-event safe)
│   ├── fs.lua / file_system.lua
│   ├── table.lua / string.lua / levels.lua / module.lua
│   └── ...
├── libs/
│   ├── json.lua / toml.lua / tinyyaml.lua
└── managers/
    ├── common.lua            — shared helpers (detect_dependency_type, …)
    └── <manager>/            — one folder per manager (npm, cargo, go, …)
```

### Key design principles

1. **Registry auto-discovery** — `core/registry.lua` globs `managers/*/manifest.lua` at startup, reads each manifest's `M.key`, then loads `managers/<key>/register.lua` and calls `M.register()`.
2. **Hub pattern** — `core/hub/{declared,installed,latest}.lua` call into `managers.<key>.data.<type>` dynamically, so the core never imports a specific manager directly.
3. **All notifications through `utils.notify`** — never call `vim.notify` directly anywhere in the plugin.
4. **Operation lifecycle** — every install/update/delete goes through `*_ops.lua` which handles the full sequence: working indicator → CLI command → seed installed version → refresh virtual text → checktime. Never run CLI commands directly from `api/init.lua`.
5. **Async** — network and file I/O are non-blocking. Use `utils.http` for HTTP and `vim.system()` for CLI. Callbacks run inside `vim.schedule()` when touching UI.

---

## Adding a New Package Manager

### Step 1: Create the folder

```
lua/lvim-dependencies/managers/<key>/
```

Replace `<key>` with a short lowercase identifier (e.g. `go`, `npm`, `cargo`).

### Step 2: Create a config file

`lua/lvim-dependencies/config/<key>.lua` — defaults for this manager.

```lua
-- lvim-dependencies/config/mymanager.lua
return {
    executables = {
        mybin = nil,          -- nil = auto-detect from PATH
    },
    api = {
        timeout       = 10,   -- seconds
        registry_base = nil,  -- nil = use manifest default
        endpoint      = nil,
    },
    file_ops = {
        root_dir = nil,
    },
    version = {
        include_prerelease = false,
        sort_order         = "desc",
        max_versions       = 50,
    },
    virtual_text = {
        position = nil,
        priority = nil,
    },
    polling = {
        max_attempts   = 30,
        interval_ms    = 200,
        start_delay_ms = 500,
    },
}
```

Then add it to `config/init.lua`:

```lua
local config_mymanager = require("lvim-dependencies.config.mymanager")
-- ...
M.mymanager = config_mymanager
-- and in get_all():
mymanager = M.mymanager,
```

### Step 3: Implement the required files

```
managers/<key>/
├── manifest.lua          — REQUIRED: manager identity, file patterns, dep types, VT format helpers
├── register.lua          — REQUIRED: entry point called by registry
├── handler.lua           — REQUIRED: operation dispatcher
├── parser.lua            — REQUIRED: parses the manifest file
├── compare_versions.lua  — REQUIRED: version comparison and sorting
├── virtual_text.lua      — REQUIRED: VT line finding and chunk formatting
├── api/
│   └── init.lua          — REQUIRED: get_package_at_cursor, fetch_versions_async,
│                                      update_async, delete
├── core/
│   └── <key>_ops.lua     — REQUIRED: full operation lifecycle
├── data/
│   ├── declared.lua      — REQUIRED: declared packages from parser
│   ├── installed.lua     — REQUIRED: installed versions
│   └── latest.lua        — REQUIRED: latest versions from registry
└── utils/
    ├── helpers.lua        — optional: URL encoding, shared utilities
    └── indicators.lua     — optional: loading/working VT indicators
```

---

## File Structure Reference

### manifest.lua

```lua
-- managers/mymanager/manifest.lua
---@include "core/types.lua"

local compare_version = require("lvim-dependencies.managers.mymanager.compare_versions")
local config = require("lvim-dependencies.config")

local icons  = config.ui.virtual_text.icons
local groups = config.highlight.groups

---@class MyManagerManifest: ManagerManifest
local M = {}

M.key           = "mymanager"
M.file_patterns = { "mymanifest.toml" }
M.lock_files    = { "mymanifest.lock" }

M.registry = {
    base_url       = "https://registry.example.com",
    list_endpoint  = "/%s/versions",   -- %s = encoded package name
    latest_endpoint= "/%s/latest",
}

M.api = { timeout = 10 }

M.virtual_text = { position = "eol", priority = 1000 }

-- dependency_types drive VT formatting and hover output for each dep kind
---@type table<string, DependencyTypeDef>
M.dependency_types = {
    registry = {
        type   = "registry",
        detect = function(v) return type(v) == "string" end,
        extract = function(v, dep) dep.declared = v end,
        format = function(dep)
            local vt = { { icons.separators.prefix .. " ", groups.separator } }
            if dep.declared then
                vt[#vt + 1] = { dep.declared, groups.declared }
            end
            if dep.installed then
                vt[#vt + 1] = { " " .. icons.separators.transition .. " ", groups.separator }
                vt[#vt + 1] = { dep.installed, groups.installed }
            end
            if dep.latest then
                local is_current = compare_version.compare(dep.latest, dep.installed or "") == 0
                local hl   = is_current and groups.up_to_date or groups.outdated
                local icon = is_current and icons.up_to_date or icons.outdated
                vt[#vt + 1] = { " " .. icons.separators.divider .. " ", groups.separator }
                vt[#vt + 1] = { icon .. " ", hl }
                vt[#vt + 1] = { dep.latest, hl }
            end
            return vt
        end,
        format_hover = function(dep, latest, metadata)
            local lines = {}
            if dep.declared  then lines[#lines+1] = string.format("**Declared:** `%s`", dep.declared)  end
            if dep.installed then lines[#lines+1] = string.format("**Installed:** `%s`", dep.installed) end
            if latest        then lines[#lines+1] = string.format("**Latest:** `%s`", latest)           end
            return lines
        end,
    },
}

return M
```

### register.lua

```lua
-- managers/mymanager/register.lua
local M = {}

function M.register()
    require("lvim-dependencies.managers.mymanager.handler")
end

-- Optional: expose LSP hover and actions
-- function M.register_lsp() ... end
-- function M.register_hover() ... end
-- function M.register_actions() ... end

return M
```

### handler.lua

```lua
-- managers/mymanager/handler.lua
---@include "core/types.lua"

local operator = require("lvim-dependencies.core.operator")
local actions  = require("lvim-dependencies.managers.mymanager.api")
local const    = require("lvim-dependencies.core.const")
local utils    = require("lvim-dependencies.utils")

local notify = utils.notify
local debug  = utils.debug

local ACTIONS = const.HANDLER_ACTIONS

local function complete_update_flow(name, opts, callback)
    actions.fetch_versions_async(name, function(data)
        if not data or #data.versions == 0 then
            notify("No versions found for " .. name, vim.log.levels.WARN)
            callback({ success = false, message = "No versions found", packages = {}, no_retry = true })
            return
        end

        local ui = require("lvim-dependencies.ui.popup")
        ui.select_version(name, data.versions, data.current, function(version)
            if not version then
                callback({ success = false, message = "cancelled", packages = {}, no_retry = true })
                return
            end
            actions.update_async(name, { version = version }, function(result)
                callback(result)
            end)
        end)
    end)
end

---@type OperationHandler
local handler = {
    [ACTIONS.INSTALL]      = function(op, callback) complete_update_flow(op.packages[1] or "", op.opts, callback) end,
    [ACTIONS.UPDATE]       = function(op, callback) complete_update_flow(op.packages[1] or "", op.opts, callback) end,
    [ACTIONS.UPDATE_DIRECT]= function(op, callback) actions.update_async(op.packages[1], op.opts, callback) end,
    [ACTIONS.DELETE]       = function(op, callback) actions.delete(op.packages[1], op.opts, callback) end,
    [ACTIONS.CHECK_OUTDATED]= function(op, callback) callback({ success = true, packages = {} }) end,
}

operator.register_handler("mymanager", handler)
```

### parser.lua

Parse the manifest file and return a table of `{ [package_name] = { version = "...", ... } }`.
Use content-hash caching to avoid re-parsing on every keystroke.

```lua
-- managers/mymanager/parser.lua
local utils = require("lvim-dependencies.utils")
local debug = utils.debug

local M = {}

local _cache = { hash = nil, data = nil }

local function hash(content) return #content .. ":" .. content:sub(1, 64) end

function M.get_dependencies()
    -- find and read the manifest file
    -- parse it (vim.json.decode / toml / tinyyaml)
    -- cache by content hash
    -- return table<string, { version: string, ... }>
end

function M.find_manifest_path()
    -- return the absolute path to the manifest file, or nil
end

function M.clear_cache()
    _cache = { hash = nil, data = nil }
end

return M
```

### compare_versions.lua

Use the shared `utils.version` factory:

```lua
-- managers/mymanager/compare_versions.lua
local version_utils = require("lvim-dependencies.utils.version")

local parser     = version_utils.create_parser("^v?", { numeric = true })
local comparator = version_utils.create_comparator(parser)

local M = {}

M.compare     = comparator.compare      -- (a, b) → -1 | 0 | 1
M.is_prerelease = comparator.is_prerelease  -- (v) → boolean
M.latest      = comparator.latest       -- (versions[]) → string|nil
M.sort        = comparator.sort         -- sorts in-place ascending
M.sort_desc   = comparator.sort_desc    -- sorts in-place descending

return M
```

### data/declared.lua

```lua
-- managers/mymanager/data/declared.lua
---@include "core/types.lua"

local parser = require("lvim-dependencies.managers.mymanager.parser")
local common = require("lvim-dependencies.managers.common")

local M = {}

---@param declared_packages? table
---@return table<string, any>
function M.get_data(declared_packages)
    local deps   = parser.get_dependencies()
    local result = {}
    for name, pkg in pairs(deps) do
        result[name] = common.detect_dependency_type("mymanager", pkg)
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.declared")
    hub.clear_cache("mymanager")
end

return M
```

### data/installed.lua

```lua
-- managers/mymanager/data/installed.lua
---@include "core/types.lua"

local parser = require("lvim-dependencies.managers.mymanager.parser")
local utils  = require("lvim-dependencies.utils")
local debug  = utils.debug

local M = {}

---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
function M.get_package_installed(package_name, callback)
    local deps = parser.get_dependencies()
    local pkg  = deps[package_name]
    if pkg and pkg.version then
        debug(string.format("mymanager installed: %s = %s", package_name, pkg.version), vim.log.levels.INFO)
        callback(nil, pkg.version)
        return
    end
    callback(nil, nil)
end

---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then return {} end
    local deps   = parser.get_dependencies()
    local result = {}
    for name in pairs(declared_packages) do
        local pkg = deps[name]
        result[name] = pkg and pkg.version or nil
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("mymanager")
end

return M
```

### data/latest.lua

```lua
-- managers/mymanager/data/latest.lua
---@include "core/types.lua"

local utils  = require("lvim-dependencies.utils")
local http   = require("lvim-dependencies.utils.http")
local init   = require("lvim-dependencies.core.init")
local config = require("lvim-dependencies.config")
local debug  = utils.debug

local M = {}

---@type table<string, function[]>
local in_flight = {}

local function get_manifest()
    local m = init.get_manifest("mymanager")
    ---@cast m MyManagerManifest|nil
    return m
end

local function notify_waiters(name, err, result)
    local waiting = in_flight[name] or {}
    in_flight[name] = nil
    for _, cb in ipairs(waiting) do
        vim.schedule(function() cb(err, result) end)
    end
end

local function build_metadata(module_path)
    -- construct documentation / repository URLs from module_path
    return { documentation = "https://example.com/" .. module_path }
end

---@param package_name string
---@param callback fun(err: string|nil, result: {version: string, metadata: table}|nil)
function M.get_package_latest(package_name, callback)
    local manifest_data = get_manifest()
    if not manifest_data then
        callback("No manifest data", nil); return
    end

    if in_flight[package_name] then
        table.insert(in_flight[package_name], callback); return
    end

    in_flight[package_name] = { callback }

    local registry = manifest_data.registry or {}
    local base     = (config.mymanager and config.mymanager.api and config.mymanager.api.registry_base)
        or registry.base_url
        or "https://registry.example.com"
    local timeout  = (config.mymanager and config.mymanager.api and config.mymanager.api.timeout) or 10
    local url      = base .. string.format(registry.latest_endpoint or "/%s/latest", package_name)

    http.get(url, function(output, err)
        if err or not output then
            notify_waiters(package_name, err or "fetch failed", nil); return
        end
        local ok, data = pcall(vim.json.decode, output)
        if not ok or not data or not data.version then
            notify_waiters(package_name, "parse failed", nil); return
        end
        notify_waiters(package_name, nil, {
            version  = data.version,
            metadata = build_metadata(package_name),
        })
    end, timeout)
end

---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then return {} end
    local hub    = require("lvim-dependencies.core.hub.latest")
    local cached = hub.get_data("mymanager")
    local result = {}
    for name in pairs(declared_packages) do
        local entry = cached[name]
        result[name] = entry and entry.version or nil
    end
    return result
end

function M.clear_cache()
    local hub = require("lvim-dependencies.core.hub.latest")
    hub.clear_cache("mymanager")
    in_flight = {}
end

return M
```

### core/mymanager_ops.lua

The operation lifecycle. **All** install/update/delete paths must go through here.

```lua
-- managers/mymanager/core/mymanager_ops.lua
local vt     = require("lvim-dependencies.core.virtual_text")
local utils  = require("lvim-dependencies.utils")
local notify = utils.notify
local debug  = utils.debug

local M = {}

---@param manifest_path string
---@param package_name string
---@param version string
---@param opts UpdateOptions
---@param callback InstallerCallback
function M.run_mymanager_update(manifest_path, package_name, version, opts, callback)
    local bufnr = vim.fn.bufnr(manifest_path)

    -- 1. Show "Working..." spinner
    vt.display_working(bufnr, package_name)

    -- 2. Run the CLI command
    local cwd = vim.fn.fnamemodify(manifest_path, ":h")
    local cmd = { "mytool", "add", package_name .. "@" .. version }

    vim.system(cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            if not res or res.code ~= 0 then
                local err = M.extract_error(res)
                vt.clear_working(bufnr, package_name)
                callback({ success = false, message = err, packages = {}, no_retry = true })
                return
            end

            -- 3. Seed installed version cache immediately (avoids a stale read)
            local hub_installed = require("lvim-dependencies.core.hub.installed")
            hub_installed.seed("mymanager", package_name, version)

            -- 4. Refresh virtual text
            vt.refresh_package(bufnr, package_name)

            -- 5. Signal Neovim to reload the buffer from disk
            if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
                vim.bo[bufnr].modified = false
                vim.api.nvim_buf_call(bufnr, function() vim.cmd("checktime") end)
            end

            callback({ success = true, message = "Updated " .. package_name, packages = { package_name } })
        end)
    end)
end

function M.extract_error(res)
    if not res then return "unknown error" end
    local stderr = res.stderr or ""
    for _, line in ipairs(vim.split(stderr, "\n")) do
        if line ~= "" then return line end
    end
    return "exit code " .. tostring(res.code)
end

return M
```

### api/init.lua

```lua
-- managers/mymanager/api/init.lua
---@include "core/types.lua"

local parser  = require("lvim-dependencies.managers.mymanager.parser")
local ops     = require("lvim-dependencies.managers.mymanager.core.mymanager_ops")
local utils   = require("lvim-dependencies.utils")
local notify  = utils.notify

local M = {}

---@param opts? {bufnr?: integer, cursor_line?: integer}
---@return string|nil
function M.get_package_at_cursor(opts)
    opts = opts or {}
    local bufnr       = opts.bufnr or vim.api.nvim_get_current_buf()
    local cursor_line = opts.cursor_line
    if cursor_line == nil then cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 end

    local line = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1]
    if not line then return nil end

    -- adapt the pattern to your manifest format
    return line:match('^%s*([%w%.%-%_/]+)%s*=')
end

---@param name string
---@param callback fun(data: VersionData|nil)
function M.fetch_versions_async(name, callback)
    if not name or name == "" then callback(nil); return end

    -- fetch from registry, sort, limit, return with current installed version
    local installed = require("lvim-dependencies.managers.mymanager.data.installed")
    installed.get_package_installed(name, function(_, current)
        -- ... fetch and sort versions ...
        callback({ versions = {}, current = current })
    end)
end

---@param name string
---@param opts UpdateOptions
---@param callback InstallerCallback
function M.update_async(name, opts, callback)
    if not name then
        callback({ success = false, message = "package name required", packages = {} }); return
    end
    local version = opts and opts.version
    if not version then
        callback({ success = false, message = "version required", packages = {} }); return
    end

    local path = parser.find_manifest_path()
    if not path then
        callback({ success = false, message = "manifest not found", packages = {} }); return
    end

    ops.run_mymanager_update(path, name, version, opts, callback)
end

---@param name string
---@param opts DeleteOptions
---@param callback InstallerCallback
function M.delete(name, opts, callback)
    -- confirm → run CLI → clear caches → refresh VT → callback
end

return M
```

### virtual_text.lua

```lua
-- managers/mymanager/virtual_text.lua
---@include "core/types.lua"

local api    = vim.api
local config = require("lvim-dependencies.config")
local init   = require("lvim-dependencies.core.init")

local icons  = config.ui.virtual_text.icons
local groups = config.highlight.groups

local M = {}

local function get_manifest()
    local m = init.get_manifest("mymanager")
    ---@cast m MyManagerManifest|nil
    return m
end

--- Find the package name on a single buffer line.
---@param line string
---@return string|nil
function M.find_package_in_line(line)
    return line:match('^%s*([%w%.%-%_/]+)%s*=')
end

---@param buf integer
---@param package_name string
---@return integer|nil  0-based line index
function M.find_package_line(buf, package_name)
    if vim.in_fast_event() or not api.nvim_buf_is_valid(buf) then return nil end
    local ok, lines = pcall(api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok then return nil end
    local pattern = "^%s*" .. vim.pesc(package_name) .. "%s*="
    for i, line in ipairs(lines) do
        if line:match(pattern) then return i - 1 end
    end
    return nil
end

---@return VirtualTextChunk[]
function M.get_loading_parts()
    return {
        { icons.separators.prefix .. " ", groups.separator },
        { icons.loading, groups.loading or "Comment" },
    }
end

---@return VirtualTextChunk[]
function M.get_working_parts()
    return {
        { icons.separators.prefix .. " ", groups.separator },
        { icons.working or icons.loading, groups.loading or "Comment" },
    }
end

---@param record PackageRecord
---@return VirtualTextChunk[]
function M.format_package_chunks(record)
    if not record then return { { "?", groups.error or "Comment" } } end

    if record.installed_err or record.latest_err then
        local err = record.installed_err or record.latest_err or "error"
        return {
            { icons.separators.prefix .. " ", groups.separator },
            { icons.error .. " " .. err, groups.error or "Error" },
        }
    end

    local manifest_data = get_manifest()
    local dep_types     = manifest_data and manifest_data.dependency_types or {}
    local dep_type      = dep_types[record.dep_type or "registry"]

    if dep_type and dep_type.format then
        local latest = record.latest and (type(record.latest) == "table" and record.latest.version or record.latest)
        local chunks = { { icons.separators.prefix .. " ", groups.separator } }
        local extra  = dep_type.format({
            name      = record.package,
            declared  = record.declared_version,
            installed = record.installed,
            latest    = latest,
        })
        if type(extra) == "table" then
            for _, chunk in ipairs(extra) do chunks[#chunks + 1] = chunk end
        end
        return chunks
    end

    return { { "?", groups.comment or "Comment" } }
end

---@param record PackageRecord
---@return string
function M.format_package_text(record)
    local chunks = M.format_package_chunks(record)
    local parts  = {}
    for _, chunk in ipairs(chunks) do parts[#parts + 1] = chunk[1] end
    return table.concat(parts, "")
end

return M
```

---

## API Contract

### What the core expects from each manager

| Module               | Required exports |
|----------------------|-----------------|
| `manifest.lua`       | `M.key`, `M.file_patterns`, `M.dependency_types` |
| `register.lua`       | `M.register()` — called once at startup |
| `data/declared.lua`  | `M.get_data(declared_packages?)` → `table<string, any>` |
| `data/installed.lua` | `M.get_package_installed(name, cb)`, `M.get_data(pkgs?)`, `M.clear_cache()` |
| `data/latest.lua`    | `M.get_package_latest(name, cb)`, `M.get_data(pkgs?)`, `M.clear_cache()` |
| `api/init.lua`       | `M.get_package_at_cursor(opts?)`, `M.fetch_versions_async(name, cb)`, `M.update_async(name, opts, cb)`, `M.delete(name, opts, cb)` |
| `virtual_text.lua`   | `M.find_package_in_line(line)`, `M.find_package_line(buf, name)`, `M.get_loading_parts()`, `M.get_working_parts()`, `M.format_package_chunks(record)` |

### Callback signatures

```lua
-- installed / latest
callback(err_or_nil, version_or_nil)

-- installer (InstallerResult)
callback({
    success  = true,          -- boolean
    message  = "...",         -- string|nil
    packages = { "pkg" },     -- string[]
    no_retry = true,          -- boolean|nil — prevents operator retry / re-showing picker
})
```

---

## Operation Lifecycle

Every install/update/delete **must** follow this sequence via `core/*_ops.lua`:

```
1. vt.display_working(bufnr, package_name)   — show "Working..." spinner
2. vim.system(cmd, ...)                       — run the CLI tool
3. hub_installed.seed(manager, name, version) — update installed cache immediately
4. vt.refresh_package(bufnr, package_name)    — re-render virtual text
5. vim.cmd("checktime") in buf context        — reload buffer from disk
6. callback(InstallerResult)
```

Never skip steps 1 or 3–5. If a step is skipped:
- Missing step 1 → "Working..." spinner never appears
- Missing step 3 → VT shows stale installed version after update
- Missing step 4 → VT doesn't update until the next buffer event
- Missing step 5 → Buffer content diverges from disk

---

## Type System

All shared types live in `core/types.lua`. Use `---@include "core/types.lua"` at the top of each manager file.

Add a manager-specific manifest type:

```lua
---@class MyManagerManifest: ManagerManifest
---@field registry? { base_url: string, list_endpoint: string, latest_endpoint: string }
---@field api?      { timeout: integer, registry_base: string|nil }
```

Key shared types:

| Type | Description |
|------|-------------|
| `ManagerManifest` | Base manifest interface |
| `InstallerResult` | Callback result for operations |
| `InstallerCallback` | `fun(result: InstallerResult)` |
| `UpdateOptions` | `{ version?: string, ... }` |
| `PackageRecord` | VT record with declared/installed/latest |
| `VirtualTextChunk` | `{ string, string }` — text + highlight group |
| `VersionData` | `{ versions: string[], current: string|nil }` |

---

## Conventions

- **Notifications**: always `utils.notify(msg, level)`, never `vim.notify`
- **Logging**: `utils.debug(msg, level)` for structured debug output
- **HTTP**: `utils.http.get(url, callback, timeout)` — curl-based async
- **Version parsing**: use `utils.version.create_parser` + `create_comparator`
- **gsub return value**: always discard the count — `(str:gsub(...))` not `str:gsub(...)`
- **Manifest caching**: use content-hash caching in `parser.lua`; clear cache in `parser.clear_cache()`
- **In-flight deduplication**: `data/latest.lua` must deduplicate concurrent requests for the same package name using an `in_flight` table

---

## Testing

### Manual checklist

Open a manifest file and verify:

1. **Virtual text loads** — `Loading...` appears then resolves to `declared → installed | latest`
2. **Working spinner** — `:LvimDeps update` shows `Working...` during the operation
3. **VT updates after update** — correct new version shown immediately, no stale value
4. **Version picker** — currently installed version is marked with `➤`
5. **Delete** — confirmation popup appears, package removed, VT cleared
6. **LSP hover** (`K`) — shows declared / installed / latest and metadata links
7. **LSP code actions** (`ga`) — shows Update, Delete, Open repository, Open documentation

### Debug commands

```vim
:LvimDeps cache              " inspect all cache layers
:LvimDeps state              " per-buffer state machine
:LvimDeps show-registry      " verify manager was registered
:LvimDeps show-manager <key> " dependency types and file patterns
:LvimDeps metrics            " network / performance stats
```

---

## Need Help?

- Open an issue on GitHub
- Look at a complete implementation: `managers/go/` or `managers/cargo/`
