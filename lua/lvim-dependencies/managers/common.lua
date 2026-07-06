-- lvim-dependencies.managers.common: shared helpers every manager builds on — type
-- detection, dependency-object construction, list processing and manifest validation.
-- Detection is memoised in a BOUNDED cache: the TTL alone is not enough (entries were
-- only checked on read, never evicted, so a large/varied config leaked memory), so the
-- cache also caps its size and evicts the oldest-accessed quarter once past the limit.
--
---@module "lvim-dependencies.managers.common"

local utils = require("lvim-dependencies.utils")
local debug = utils.debug

local M = {}

-- ============================================================================
-- Bounded detection cache
-- ============================================================================
local DETECTION_CACHE_TTL = 60000 ---@type integer  entry lifetime in ms (1 minute)
local DETECTION_CACHE_MAX = 500 ---@type integer  max entries before eviction kicks in

---@type table<string, {type_name: string, extracted: table, timestamp: integer, last_access: integer}>
local detection_cache = {}
local detection_cache_count = 0 ---@type integer  live entry count (kept in sync with the table)

--- Evict expired entries and, if still over the size limit, the oldest-accessed quarter.
---@return nil
local function evict_detection_cache()
    local now = vim.uv.now()
    local to_delete = {}

    for k, v in pairs(detection_cache) do
        if (now - v.timestamp) >= DETECTION_CACHE_TTL then
            to_delete[#to_delete + 1] = k
        end
    end

    for _, k in ipairs(to_delete) do
        detection_cache[k] = nil
        detection_cache_count = detection_cache_count - 1
    end

    -- If still over limit, evict oldest accessed
    if detection_cache_count > DETECTION_CACHE_MAX then
        local entries = {}
        for k, v in pairs(detection_cache) do
            entries[#entries + 1] = { key = k, last_access = v.last_access }
        end
        table.sort(entries, function(a, b)
            return a.last_access < b.last_access
        end)

        local to_remove = detection_cache_count - math.floor(DETECTION_CACHE_MAX * 0.75)
        for i = 1, to_remove do
            detection_cache[entries[i].key] = nil
            detection_cache_count = detection_cache_count - 1
        end
    end
end

--- Build a stable, STRUCTURAL cache key from a dependency value.
--- Recurses into nested tables — a bare `tostring(v)` on a table yields its ADDRESS, so two
--- structurally-identical deps produced permanent cache misses (different addresses) and, worse,
--- a reused address could produce a stale hit. Serialising the shape (sorted keys, recursed
--- values) makes the key depend only on content. Manifest values are acyclic (JSON/TOML/YAML).
---@param value any
---@return string
local function make_cache_key(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local items = {}
    for k, v in pairs(value) do
        items[#items + 1] = string.format("%s=%s", tostring(k), make_cache_key(v))
    end
    table.sort(items)
    return "table:{" .. table.concat(items, "|") .. "}"
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Attempt to detect dependency type using manifest definitions
---@param value any Value from configuration file
---@param dep_types table<string, DependencyTypeDef>
---@return string|nil type_name, table|nil extracted_data
function M.detect_dependency_type(value, dep_types)
    local cache_key = make_cache_key(value)
    local now = vim.uv.now()

    local cached = detection_cache[cache_key]
    if cached and (now - cached.timestamp) < DETECTION_CACHE_TTL then
        cached.last_access = now
        return cached.type_name, cached.extracted
    end

    local function store_result(type_name, extracted)
        if not cached then
            if detection_cache_count >= DETECTION_CACHE_MAX then
                evict_detection_cache()
            end
            detection_cache_count = detection_cache_count + 1
        end

        detection_cache[cache_key] = {
            type_name = type_name,
            extracted = extracted,
            timestamp = now,
            last_access = now,
        }
    end

    local seen = {}
    local function try_detect(type_name, type_def)
        seen[type_name] = true
        if type_def and type_def.detect then
            local ok, detected = pcall(type_def.detect, value)

            if ok and detected then
                local extracted = {}
                if type_def.extract then
                    pcall(type_def.extract, value, extracted)
                end

                store_result(type_name, extracted)
                return true, extracted
            elseif not ok then
                debug(string.format("Detector error for %s: %s", type_name, detected), vim.log.levels.WARN)
            end
        end
    end

    for _, type_name in ipairs(dep_types.detection_order or { "workspace", "git", "path", "sdk", "registry" }) do
        local detected, extracted = try_detect(type_name, dep_types[type_name])
        if detected then
            return type_name, extracted
        end
    end

    for type_name, type_def in pairs(dep_types) do
        if not seen[type_name] then
            local detected, extracted = try_detect(type_name, type_def)
            if detected then
                return type_name, extracted
            end
        end
    end

    return nil, nil
end

--- Create a base dependency object
---@param name string
---@param type_name string
---@param value any
---@param extracted table|nil
---@return table
function M.create_base_dependency(name, type_name, value, extracted)
    local dep = { name = name, type = type_name, raw = value }
    if extracted then
        for k, v in pairs(extracted) do
            dep[k] = v
        end
    end
    return dep
end

--- Process a list of dependencies
---@param raw_deps table<string, any>
---@param dep_types table<string, DependencyTypeDef>
---@param custom_process function|nil
---@return table<string, table>
function M.process_dependencies(raw_deps, dep_types, custom_process)
    local result = {}

    for name, value in pairs(raw_deps or {}) do
        if not name or name == "" then
            debug("Skipping dependency with empty name", vim.log.levels.WARN)
            goto continue
        end

        if custom_process then
            local dep = custom_process(name, value, dep_types)
            if dep then
                result[name] = dep
                goto continue
            end
        end

        local type_name, extracted = M.detect_dependency_type(value, dep_types)
        if type_name then
            result[name] = M.create_base_dependency(name, type_name, value, extracted)
        else
            debug(string.format("Could not detect type for %s", name), vim.log.levels.DEBUG)
        end

        ::continue::
    end

    return result
end

--- Validate manifest structure
---@param manifest table
---@param required_fields string[]
---@return boolean
function M.validate_manifest(manifest, required_fields)
    if not manifest then
        return false
    end
    for _, field in ipairs(required_fields) do
        if manifest[field] == nil then
            return false
        end
    end
    return true
end

--- Clear the detection cache — a single entry when `cache_key` is given, otherwise all.
---@param cache_key? string
---@return nil
function M.clear_cache(cache_key)
    if cache_key then
        if detection_cache[cache_key] then
            detection_cache[cache_key] = nil
            detection_cache_count = detection_cache_count - 1
        end
        debug(string.format("Cleared detection cache for %s", cache_key), vim.log.levels.DEBUG)
    else
        detection_cache = {}
        detection_cache_count = 0
        debug("Cleared all detection cache", vim.log.levels.DEBUG)
    end
end

return M
