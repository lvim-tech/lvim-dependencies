-- lvim-dependencies.managers.composer.data.installed: reports the versions actually INSTALLED,
-- read from composer.lock (parsed once per mtime, then served to every declared package so a
-- project-wide open doesn't re-decode the whole lock N times). Composer stores "v"-prefixed
-- versions, which are normalised. Platform requirements
-- (php / ext-* / lib-* / composer-*) are never in the lock, so their composer.json constraint
-- is returned as the "installed" value instead.
--
---@module "lvim-dependencies.managers.composer.data.installed"

local utils = require("lvim-dependencies.utils")
local manifest = require("lvim-dependencies.managers.composer.manifest")
local parser = require("lvim-dependencies.managers.composer.parser")

local debug = utils.debug

---@class ComposerInstalled
local M = {}

--- Find composer.lock path relative to composer.json
---@return string|nil
local function find_lock_file()
    local found = vim.fs.find("composer.lock", {
        upward = true,
        path = vim.fn.getcwd(),
        type = "file",
    })
    return found and found[1] or nil
end

--- Parsed composer.lock cache keyed by path + mtime + size. A project-wide open resolves each
--- declared package through get_package_installed separately; without this every one re-read and
--- re-json_decoded the whole lock. Parse once per signature and serve all packages from it.
---@type table<string, { sig: string, data: table|false }>
local lock_cache = {}

--- Read and parse composer.lock (cached by path + mtime + size).
---@return table|nil
local function read_lock()
    local path = find_lock_file()
    if not path then
        return nil
    end

    local stat = vim.uv.fs_stat(path)
    local sig = string.format("%d:%d", stat and stat.mtime and stat.mtime.sec or 0, stat and stat.size or 0)
    local cached = lock_cache[path]
    if cached and cached.sig == sig then
        return cached.data or nil
    end

    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        return nil
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        debug("composer: failed to parse composer.lock", vim.log.levels.WARN)
        lock_cache[path] = { sig = sig, data = false }
        return nil
    end
    lock_cache[path] = { sig = sig, data = data }
    return data
end

--- Build name → version map from lock file packages array
---@param packages table[]
---@param result table<string, string>
local function collect_packages(packages, result)
    if type(packages) ~= "table" then
        return
    end
    for _, pkg in ipairs(packages) do
        if type(pkg) == "table" and type(pkg.name) == "string" and type(pkg.version) == "string" then
            -- Composer versions may have "v" prefix: "v1.2.3" → "1.2.3"
            local ver = pkg.version:gsub("^v", "")
            result[pkg.name] = ver
        end
    end
end

--- Platform packages are not in composer.lock — return their constraint as "installed"
---@param name string
---@return boolean
local function is_platform_package(name)
    return not manifest.is_package_actionable(name)
end

--- Get installed version for a single package
---@param package_name string
---@param callback fun(err: string|nil, version: string|nil)
function M.get_package_installed(package_name, callback)
    -- Platform packages are not tracked in composer.lock
    -- Return their constraint from composer.json as the "installed" value
    if is_platform_package(package_name) then
        local all = parser.get_dependencies()
        local pkg = all[package_name]
        local constraint = pkg and pkg.version or nil
        callback(nil, constraint)
        return
    end

    local data = read_lock()
    if not data then
        callback(nil, nil)
        return
    end

    local versions = {}
    collect_packages(data.packages, versions)
    collect_packages(data["packages-dev"], versions)

    local ver = versions[package_name]
    if ver then
        debug(string.format("composer installed: %s = %s", package_name, ver), vim.log.levels.INFO)
        callback(nil, ver)
    else
        debug(string.format("composer: %s not found in composer.lock", package_name), vim.log.levels.DEBUG)
        callback(nil, nil)
    end
end

--- Bulk installed lookup
---@param declared_packages? table
---@return table<string, string|nil>
function M.get_data(declared_packages)
    if not declared_packages then
        return {}
    end

    local data = read_lock()
    if not data then
        return {}
    end

    local versions = {}
    collect_packages(data.packages, versions)
    collect_packages(data["packages-dev"], versions)

    local result = {}
    for name in pairs(declared_packages) do
        result[name] = versions[name]
    end
    return result
end

function M.clear_cache()
    lock_cache = {}
    debug("composer: installed lock cache cleared", vim.log.levels.DEBUG)
end

return M
