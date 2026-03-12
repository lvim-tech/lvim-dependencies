-- lvim-dependencies/lsp/hover.lua
-- Universal hover functionality for all dependency managers

local utils = require("lvim-dependencies.utils")
local registry = require("lvim-dependencies.core.registry")
local cache = require("lvim-dependencies.core.cache")
local init = require("lvim-dependencies.core.init")

local utils_lsp = utils.lsp
local debug = utils.debug

local M = {}

local function is_enabled()
    local config = require("lvim-dependencies.config")
    return config.lsp and config.lsp.hover or false
end

--- Get manifest for type
local function get_manifest(manifest_type)
    if init and type(init.get_manifest) == "function" then
        local ok, manifest = pcall(init.get_manifest, manifest_type)
        if ok and manifest then
            return manifest
        end
    end
    if init and type(init.get_loader) == "function" then
        local ok, loader = pcall(init.get_loader, manifest_type, "declared")
        if ok and loader and type(loader.manifest) == "table" then
            return loader.manifest
        end
    end
    local ok, manifest = pcall(require, ("lvim-dependencies.managers.%s.manifest"):format(manifest_type))
    return ok and manifest or nil
end

--- Get manager-specific hover content
---@param manifest_type string
---@param params table
---@param bufnr integer
---@param dep_name string
---@param dep_data table
---@return table|nil
local function get_manager_hover(manifest_type, params, bufnr, dep_name, dep_data)
    -- First try the registry (if the manager registered a hover provider)
    local hover_handler = registry.get_hover_provider(manifest_type)
    if hover_handler then
        -- Pass params, bufnr, dep_name, dep_data (same signature as action.lua)
        local ok, result = pcall(hover_handler, params, bufnr, dep_name, dep_data)
        if ok and result then
            debug(string.format("Got hover from registry for %s", manifest_type), vim.log.levels.DEBUG)
            return result
        end
    end

    -- Second attempt: try to load the manager's lsp module directly
    local ok, manager_lsp = pcall(require, string.format("lvim-dependencies.managers.%s.lsp", manifest_type))
    if ok and manager_lsp and manager_lsp.get_hover then
        local ok2, result = pcall(manager_lsp.get_hover, params, bufnr, dep_name, dep_data)
        if ok2 and result then
            debug(string.format("Got hover from %s.lsp", manifest_type), vim.log.levels.DEBUG)
            return result
        end
    end

    return nil
end

--- Handle hover request
function M.handle(params, bufnr)
    debug("HOVER.HANDLE for buffer " .. tostring(bufnr), vim.log.levels.DEBUG)

    if not is_enabled() then
        debug("Hover disabled", vim.log.levels.DEBUG)
        return nil
    end

    local cursor_line = params.position.line
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local manifest_type = registry.determine_manifest_type(filename)

    if not manifest_type then
        debug("Not a manifest file", vim.log.levels.DEBUG)
        return nil
    end

    local manifest = get_manifest(manifest_type)
    if not manifest then
        debug("No manifest for " .. manifest_type, vim.log.levels.DEBUG)
        return nil
    end

    local deps = utils_lsp.parse_dependencies(manifest_type, cache)
    if not deps or vim.tbl_isempty(deps) then
        debug("No dependencies", vim.log.levels.DEBUG)
        return nil
    end

    local dep_name, dep_data = utils_lsp.find_dependency_at_cursor(bufnr, manifest_type, deps, cursor_line, init)
    if not dep_name or not dep_data then
        debug("No dependency at cursor", vim.log.levels.DEBUG)
        return nil
    end

    -- First: check for manager-specific hover
    local manager_hover = get_manager_hover(manifest_type, params, bufnr, dep_name, dep_data)
    if manager_hover then
        debug("Using manager-specific hover", vim.log.levels.DEBUG)
        return manager_hover
    end

    -- Second: fall back to the standard manifest hover
    debug("Using manifest hover", vim.log.levels.DEBUG)

    local metadata = utils_lsp.get_metadata_from_cache(manifest_type, dep_name, dep_data, cache)
    local dep_type = dep_data.decl and dep_data.decl.type or "unknown"
    local latest_version = dep_data.latest and dep_data.latest.version or nil

    if
        not manifest.dependency_types
        or not manifest.dependency_types[dep_type]
        or not manifest.dependency_types[dep_type].format_hover
    then
        debug("No format_hover for type: " .. dep_type, vim.log.levels.DEBUG)
        return nil
    end

    local type_lines = manifest.dependency_types[dep_type].format_hover(dep_data, latest_version, metadata)
    if not type_lines or type(type_lines) ~= "table" or #type_lines == 0 then
        debug("format_hover empty", vim.log.levels.DEBUG)
        return nil
    end

    local lines = { string.format("# %s", dep_name), "" }
    for _, line in ipairs(type_lines) do
        table.insert(lines, line)
    end

    debug("Hover lines: " .. #lines, vim.log.levels.DEBUG)
    return { contents = { kind = "markdown", value = table.concat(lines, "\n") } }
end

function M.attach(bufnr)
    if is_enabled() then
        debug("HOVER.ATTACH buffer " .. bufnr, vim.log.levels.DEBUG)
    end
end

function M.detach(bufnr)
    debug("HOVER.DETACH buffer " .. bufnr, vim.log.levels.DEBUG)
end

function M.setup()
    debug("HOVER.SETUP", vim.log.levels.DEBUG)
end

return M
