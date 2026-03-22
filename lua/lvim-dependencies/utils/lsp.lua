-- lvim-dependencies/utils/lsp.lua
-- Shared utilities for LSP modules (hover, actions)

-- lvim-dependencies/utils/lsp.lua
-- Shared utilities for LSP modules (hover, actions)

---@class PackageMetadata
---@field homepage? string
---@field repository? string
---@field documentation? string
---@field description? string
---@field license? string
---@field author? string
---@field [string] any

local M = {}

--- Escape Lua pattern special characters
---@param s string
---@return string
function M.escape_lua_pattern(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

--- Generic capture patterns for dependency detection
M.generic_patterns = {
    "^%s*['\"]?([%w%-%._]+)['\"]?%s*[:=]%s*", -- YAML/JSON/TOML key
    "^%s*([%w%-%._]+)%s*==%s*", -- pip ==
    "^%s*([%w%-%._]+)%s*%~=%s*", -- pip ~=
    "^%s*([%w%-%._]+)%s*[><=!]%s*", -- pip version comparisons
    "^%s*([%w%-%._]+)%s*%[", -- name[extras]
    "^%s*([%w%-%._]+)%s+@%s+", -- name @ url
    "^%s*([%w%-%._]+)%s+[%d%p]", -- fallback: name <sep> version/char
}

--- Parse dependencies from cache for a manifest type
---@param manifest_type string
---@param cache table The cache module (passed from caller)
---@return table
function M.parse_dependencies(manifest_type, cache)
    local cache_data = cache.get()
    if not cache_data then
        return {}
    end

    local result = {}

    -- Get declared data from cache
    local declared_data = {}
    if cache_data.declared and cache_data.declared[manifest_type] and cache_data.declared[manifest_type].data then
        declared_data = cache_data.declared[manifest_type].data
    end

    for name, decl in pairs(declared_data) do
        local installed = nil
        local latest = nil

        -- Read installed version from cache (hub stores {version=...}, extract string)
        if
            cache_data.installed
            and cache_data.installed[manifest_type]
            and cache_data.installed[manifest_type].data
        then
            local raw = cache_data.installed[manifest_type].data[name]
            installed = type(raw) == "table" and raw.version or raw
        end

        -- Read latest version from cache (keep full object so .version is accessible)
        if cache_data.latest and cache_data.latest[manifest_type] and cache_data.latest[manifest_type].data then
            latest = cache_data.latest[manifest_type].data[name]
        end

        result[name] = { name = name, installed = installed, latest = latest, decl = decl }
    end
    return result
end

--- Get metadata from cache
---@param manifest_type string
---@param package_name string
---@param dep table
---@param cache table The cache module (passed from caller)
---@return PackageMetadata|nil
function M.get_metadata_from_cache(manifest_type, package_name, dep, cache)
    local cache_data = cache.get()
    if not cache_data then
        return nil
    end

    -- Check canonical metadata map
    if cache_data.latest and cache_data.latest[manifest_type] and cache_data.latest[manifest_type].metadata then
        local md = cache_data.latest[manifest_type].metadata[package_name]
        if md and type(md) == "table" then
            return md
        end
    end

    -- Check if latest data has metadata field
    if cache_data.latest and cache_data.latest[manifest_type] and cache_data.latest[manifest_type].data then
        local pkg_entry = cache_data.latest[manifest_type].data[package_name]
        if pkg_entry and type(pkg_entry) == "table" then
            if pkg_entry.metadata and type(pkg_entry.metadata) == "table" then
                return pkg_entry.metadata
            end
            -- Build metadata from direct fields if present
            local md = {}
            if pkg_entry.homepage then
                md.homepage = pkg_entry.homepage
            end
            if pkg_entry.repository then
                md.repository = pkg_entry.repository
            end
            if pkg_entry.documentation then
                md.documentation = pkg_entry.documentation
            end
            if next(md) then
                return md
            end
        end
    end

    -- Check if dep.latest has metadata
    if dep and dep.latest and type(dep.latest) == "table" then
        local d = dep.latest
        if d.metadata and type(d.metadata) == "table" then
            return d.metadata
        end
        local md = {}
        if d.homepage then
            md.homepage = d.homepage
        end
        if d.repository then
            md.repository = d.repository
        end
        if d.documentation then
            md.documentation = d.documentation
        end
        if next(md) then
            return md
        end
    end

    return nil
end

--- Find dependency at cursor using various heuristics
---@param bufnr integer
---@param manifest_type string
---@param deps table
---@param cursor_line integer
---@param init table The init module (passed from caller)
---@return string|nil
---@return table|nil
function M.find_dependency_at_cursor(bufnr, manifest_type, deps, cursor_line, init)
    local line_content = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1] or ""

    -- Try virtual text helper first
    local vt = (init and type(init.get_virtual_text) == "function") and init.get_virtual_text(manifest_type) or nil
    if vt and vt.find_package_line then
        for name, _ in pairs(deps) do
            local ok, line = pcall(vt.find_package_line, vt, bufnr, name)
            if ok and line == cursor_line then
                return name, deps[name]
            end
        end
    end

    -- Try manifest-level helper if available
    local manifest = nil
    if init and type(init.get_manifest) == "function" then
        local ok, m = pcall(init.get_manifest, manifest_type)
        if ok and m then
            manifest = m
        end
    end
    if not manifest and init and type(init.get_loader) == "function" then
        local ok, loader = pcall(init.get_loader, manifest_type, "declared")
        if ok and loader and type(loader.manifest) == "table" then
            manifest = loader.manifest
        end
    end
    if not manifest then
        local ok, m = pcall(require, ("lvim-dependencies.managers.%s.manifest"):format(manifest_type))
        if ok and m then
            manifest = m
        end
    end

    if manifest and type(manifest.find_package_from_line) == "function" then
        local ok, name = pcall(manifest.find_package_from_line, line_content)
        if ok and name and deps[name] then
            return name, deps[name]
        end
    end

    -- Use generic patterns
    for _, pat in ipairs(M.generic_patterns) do
        local cap = line_content:match(pat)
        if cap and deps[cap] then
            return cap, deps[cap]
        end
    end

    -- Last resort: word-boundary match
    for name, dep in pairs(deps) do
        local esc = M.escape_lua_pattern(name)
        if line_content:match("%f[%w]" .. esc .. "%f[%W]") then
            return name, dep
        end
    end

    return nil, nil
end

return M
