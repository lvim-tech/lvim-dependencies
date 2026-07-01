-- lvim-dependencies.managers.composer.utils.helpers: small shared lookups used across the
-- composer action layer — resolve the manifest, list the dependency sections, find which
-- section a package lives in (composer.json), and read a single installed version out of
-- composer.lock. Kept stateless (clear_cache is a no-op) so it can be required freely.
--
---@module "lvim-dependencies.managers.composer.utils.helpers"

local init = require("lvim-dependencies.core.init")
local utils = require("lvim-dependencies.utils")
local file_ops = require("lvim-dependencies.managers.composer.core.file_ops")
local json_ops = require("lvim-dependencies.managers.composer.core.json_ops")

local debug = utils.debug

---@class ComposerHelpers
local M = {}

---@return ComposerManifest|nil
function M.get_manifest()
    local m = init.get_manifest("composer")
    ---@cast m ComposerManifest|nil
    return m
end

--- The composer.json sections that hold dependencies.
---@return string[]
function M.get_dependency_sections()
    local manifest = M.get_manifest()
    return (manifest and manifest.dependency_sections) or { "require", "require-dev" }
end

--- Find which section a package belongs to in composer.json
---@param pkg_name string
---@return string|nil
function M.find_package_section(pkg_name)
    local path = file_ops.find_composer_json_path()
    if not path then
        return nil
    end

    local content = file_ops.read_content(path)
    if not content then
        return nil
    end

    local data = json_ops.parse(content)
    if not data then
        return nil
    end

    for _, section in ipairs(M.get_dependency_sections()) do
        if data[section] and data[section][pkg_name] ~= nil then
            return section
        end
    end
    return nil
end

--- Read installed version from composer.lock for a single package
---@param pkg_name string
---@return string|nil
function M.read_current_from_lock(pkg_name)
    local lock_path = vim.fs.find("composer.lock", {
        upward = true,
        path = vim.fn.getcwd(),
        type = "file",
    })
    if not lock_path or not lock_path[1] then
        return nil
    end

    local f = io.open(lock_path[1], "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        return nil
    end

    local function search(arr)
        if type(arr) ~= "table" then
            return nil
        end
        for _, pkg in ipairs(arr) do
            if type(pkg) == "table" and pkg.name == pkg_name then
                return pkg.version and pkg.version:gsub("^v", "") or nil
            end
        end
        return nil
    end

    return search(data.packages) or search(data["packages-dev"])
end

function M.clear_cache()
    debug("composer helpers cache cleared (no-op)", vim.log.levels.DEBUG)
end

return M
