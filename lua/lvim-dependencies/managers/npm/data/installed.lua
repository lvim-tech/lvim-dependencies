-- lvim-dependencies.managers.npm.data.installed: reads the resolved installed version of a
-- package from whichever lock file is present. Each package manager stores versions differently,
-- so there is a dedicated reader per lock file — package-lock.json (v1/v2/v3), yarn.lock (v1
-- header blocks), pnpm-lock.yaml (v5/v6 packages section + v9 importers section, stripping the
-- peer-dependency suffix). Lock files are tried in the priority order of the active manager.
--
---@module "lvim-dependencies.managers.npm.data.installed"

local utils = require("lvim-dependencies.utils")

local debug = utils.debug

---@class NpmInstalled
local M = {}

-- ============================================================================
-- Lock file readers
-- ============================================================================

--- Search upward from cwd for a lock file by name.
---@param lock_file string
---@return string|nil
local function find_lock_file(lock_file)
    local found = vim.fs.find(lock_file, {
        upward = true,
        path = vim.fn.getcwd(),
        type = "file",
    })
    return found and found[1] or nil
end

---@param path string
---@return string|nil
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

---@class NpmLockCacheEntry
---@field sig string path + mtime + size signature the cache is keyed on
---@field content string|nil raw file content (read once)
---@field decoded table|false|nil decoded JSON (lazy; false once a decode has failed)

--- Parsed-lock cache keyed by absolute path. A project-wide open resolves EVERY package's
--- installed version on the first paint; without this each package re-read + re-json_decoded
--- the whole (multi-MB) lock synchronously on the UI thread. We read+decode each lock once
--- per (mtime,size) signature and serve all packages — per-package and bulk — from it.
---@type table<string, NpmLockCacheEntry>
local lock_cache = {}

--- Load a lock file, cached by path + mtime + size so it is read at most once per change.
---@param lock_file string
---@return NpmLockCacheEntry|nil
local function load_lock(lock_file)
    local path = find_lock_file(lock_file)
    if not path then
        return nil
    end
    local stat = vim.uv.fs_stat(path)
    local sig = string.format("%d:%d", stat and stat.mtime and stat.mtime.sec or 0, stat and stat.size or 0)
    local entry = lock_cache[path]
    if not entry or entry.sig ~= sig then
        entry = { sig = sig, content = read_file(path), decoded = nil }
        lock_cache[path] = entry
    end
    return entry
end

--- Decoded JSON for a cached lock entry (memoised; false after a failed decode).
---@param entry NpmLockCacheEntry
---@return table|nil
local function decoded_json(entry)
    if entry.decoded == nil then
        if not entry.content then
            entry.decoded = false
        else
            local ok, data = pcall(vim.json.decode, entry.content)
            entry.decoded = (ok and type(data) == "table") and data or false
        end
    end
    return entry.decoded or nil
end

--- Read installed version from package-lock.json (npm)
---@param pkg_name string
---@return string|nil
local function read_from_npm_lock(pkg_name)
    local entry = load_lock("package-lock.json")
    if not entry then
        return nil
    end

    local data = decoded_json(entry)
    if not data then
        return nil
    end

    -- lockfileVersion 2/3: packages["node_modules/pkg"].version
    if data.packages then
        local key = "node_modules/" .. pkg_name
        if data.packages[key] and data.packages[key].version then
            return data.packages[key].version
        end
        -- scoped packages: node_modules/@scope/pkg
        if data.packages["node_modules/" .. pkg_name] then
            return data.packages["node_modules/" .. pkg_name].version
        end
    end

    -- lockfileVersion 1: dependencies.pkg.version
    if data.dependencies and data.dependencies[pkg_name] then
        return data.dependencies[pkg_name].version
    end

    return nil
end

--- Read installed version from yarn.lock (yarn classic v1)
--- Format: "pkg@^1.0.0":\n  version "1.2.3"
---@param pkg_name string
---@return string|nil
local function read_from_yarn_lock(pkg_name)
    local entry = load_lock("yarn.lock")
    local content = entry and entry.content
    if not content then
        return nil
    end

    local escaped = vim.pesc(pkg_name)
    -- Match: "pkg@range", "pkg@range, pkg@range2": (header line)
    -- Then next non-empty line: "  version "x.y.z""
    local in_block = false
    for line in content:gmatch("[^\n]+") do
        if not in_block then
            -- Header: starts with "pkg@" or quoted "@scope/pkg@"
            if line:match('^"?' .. escaped .. "@") or line:match('^"?' .. escaped .. '"?@') then
                in_block = true
            end
        else
            local ver = line:match('^%s+version%s+"([^"]+)"')
            if ver then
                return ver
            end
            -- New block started — reset
            if not line:match("^%s") and line ~= "" then
                in_block = false
            end
        end
    end

    return nil
end

--- Read installed version from pnpm-lock.yaml.
---
--- Supports lockfile formats:
---   v9 (pnpm 9+): importers section with "version: 7.29.0" or
---                 "version: 7.18.6(@babel/core@7.29.0)"
---   v6 (pnpm 7-8): packages section "/pkg@1.2.3:" or "/@scope/pkg@1.2.3:"
---   v5 (pnpm 6-):  packages section "/pkg/1.2.3:"
---
---@param pkg_name string
---@return string|nil
local function read_from_pnpm_lock(pkg_name)
    local entry = load_lock("pnpm-lock.yaml")
    local content = entry and entry.content
    if not content then
        return nil
    end

    -- Build the YAML key pattern.
    -- Scoped packages like @babel/core are quoted in YAML: "'@babel/core':"
    -- Non-scoped packages are unquoted: "lodash:"
    local key_pattern
    if pkg_name:match("^@") then
        -- Match: '  '@babel/core':' (with surrounding quotes and indent)
        key_pattern = "%s+'?" .. vim.pesc(pkg_name) .. "'?%s*:"
    else
        key_pattern = "%s+" .. vim.pesc(pkg_name) .. "%s*:"
    end

    -- Strategy 1: parse importers section (lockfile v9, pnpm 9+)
    -- Structure:
    --   importers:
    --     .:
    --       dependencies:      (or devDependencies, etc.)
    --         '@babel/core':
    --           specifier: 7.29.0
    --           version: 7.29.0
    --
    -- We look for the package key then grab the next "version:" line — but ONLY inside the top-level
    -- `importers:` section. The `snapshots:` section lists every package's transitive deps INLINE as
    -- `name: version` (e.g. `      ms: 2.1.2`), whose key matches the same unanchored pattern; a section-blind
    -- scan could bind to one of those (a transitive dep reused as a direct name, or a workspace where the
    -- direct entry lives in another importer) and return the wrong version. Track section state: a top-level
    -- header (column-0, ending in `:`) flips us in/out of `importers`; matching stops the moment it ends.
    local in_importers = false
    local in_pkg = false
    for line in content:gmatch("[^\n]+") do
        if line:match("^%S.*:%s*$") then
            -- A top-level section header (`importers:`, `packages:`, `snapshots:`, `settings:` …).
            in_importers = line:match("^importers:") ~= nil
            in_pkg = false
        elseif in_importers then
            if not in_pkg then
                if line:match(key_pattern) then
                    in_pkg = true
                end
            else
                -- "        version: 7.29.0" or "        version: 7.18.6(@babel/core@7.29.0)"
                local ver = line:match("^%s+version:%s+(.+)$")
                if ver then
                    -- Strip peer dependency suffix: "7.18.6(@babel/core@7.29.0)" → "7.18.6"
                    ver = ver:match("^([^%(]+)") or ver
                    ver = ver:match("^%s*(.-)%s*$") -- trim
                    if ver ~= "" then
                        return ver
                    end
                end
                -- If we hit another key at the same or lower indent level, stop
                if line:match("^%s+specifier:") then
                    -- still in our block, skip
                elseif line:match("^%s+[%w]") and not line:match("^%s+version:") then
                    in_pkg = false
                end
            end
        end
    end

    -- Strategy 2: packages section (lockfile v5-v6, pnpm 6-8)
    -- Format: "/@babel/core@7.29.0:" or "/@babel/core/7.29.0:"
    local escaped = vim.pesc(pkg_name)

    -- v6: /@scope/pkg@version:  or  /pkg@version:
    local ver = content:match("/" .. escaped .. "@([%d][^%(:\n]+):")
    if ver then
        return ver:match("^%s*(.-)%s*$")
    end

    -- v5: /@scope/pkg/version:  or  /pkg/version:
    ver = content:match("/" .. escaped .. "/([%d][^:%()\n]+):")
    if ver then
        return ver:match("^%s*(.-)%s*$")
    end

    return nil
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Determine lock file priority based on which package manager is active.
--- Mirrors the detect_package_manager() logic: pnpm > yarn > npm.
---@return string[]
local function detect_lock_file_order()
    local cwd = vim.fn.getcwd()
    if vim.fn.filereadable(cwd .. "/pnpm-lock.yaml") == 1 then
        return { "pnpm-lock.yaml", "yarn.lock", "package-lock.json" }
    end
    if vim.fn.filereadable(cwd .. "/yarn.lock") == 1 then
        return { "yarn.lock", "package-lock.json", "pnpm-lock.yaml" }
    end
    return { "package-lock.json", "yarn.lock", "pnpm-lock.yaml" }
end

--- Get installed version for a package.
--- Tries lock files in priority order matching the active package manager.
---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
function M.get_package_installed(package_name, callback)
    local lock_files = detect_lock_file_order()

    local readers = {
        ["package-lock.json"] = read_from_npm_lock,
        ["yarn.lock"] = read_from_yarn_lock,
        ["pnpm-lock.yaml"] = read_from_pnpm_lock,
    }

    for _, lock_file in ipairs(lock_files) do
        local reader = readers[lock_file]
        if reader then
            local version = reader(package_name)
            if version then
                debug(
                    string.format("npm installed: %s = %s (from %s)", package_name, version, lock_file),
                    vim.log.levels.INFO
                )
                callback(nil, version)
                return
            end
        end
    end

    debug(string.format("npm: %s not found in any lock file", package_name), vim.log.levels.INFO)
    callback(nil, nil)
end

--- Bulk installed lookup
---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end
    local readers_ordered = detect_lock_file_order()
    local readers = {
        ["package-lock.json"] = read_from_npm_lock,
        ["yarn.lock"] = read_from_yarn_lock,
        ["pnpm-lock.yaml"] = read_from_pnpm_lock,
    }
    local result = {}
    for name in pairs(declared_packages) do
        for _, lock_file in ipairs(readers_ordered) do
            local version = readers[lock_file](name)
            if version then
                result[name] = version
                break
            end
        end
    end
    return result
end

--- Delegates to hub/installed
function M.clear_cache()
    lock_cache = {}
    local hub = require("lvim-dependencies.core.hub.installed")
    hub.clear_cache("npm")
    debug("npm installed cache cleared (via hub)", vim.log.levels.INFO)
end

return M
