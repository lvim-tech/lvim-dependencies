-- lvim-dependencies.utils.table: table helpers — deep merge (in place and copy), plus
-- predicate/size/keys/values/filter/map/pairs and shallow equality. `merge` mutates and
-- returns base; `merge_new` first deep-copies t1 so the inputs are left untouched.
--
---@module "lvim-dependencies.utils.table"

local M = {}

--- Deep merge two tables recursively
--- Modifies the base table and returns it
---@param base table Base table to merge into
---@param override any Table with override values or any other value
---@return table|any Merged result (base table if override is table, otherwise override)
function M.merge(base, override)
    if type(override) ~= "table" then
        return override
    end

    if type(base) ~= "table" then
        base = {}
    end

    for key, value in pairs(override) do
        if type(value) == "table" and type(base[key]) == "table" then
            base[key] = M.merge(base[key], value)
        else
            base[key] = value
        end
    end

    return base
end

--- Create a new table by deeply merging two tables
--- Returns a new table without modifying the inputs
---@param t1 table First table
---@param t2 table Second table
---@return table Merged result (new table)
function M.merge_new(t1, t2)
    ---@type table
    local result = {}

    if type(t1) == "table" then
        for k, v in pairs(t1) do
            if type(v) == "table" then
                result[k] = vim.tbl_deep_extend("force", {}, v)
            else
                result[k] = v
            end
        end
    end

    return M.merge(result, t2)
end

--- Check if value is a non-empty table
---@param t any Value to check
---@return boolean
function M.is_nonempty_table(t)
    if type(t) ~= "table" then
        return false
    end

    return next(t) ~= nil
end

--- Check if table is empty
---@param t any Value to check
---@return boolean
function M.is_empty_table(t)
    if type(t) ~= "table" then
        return false
    end

    return next(t) == nil
end

--- Get table size (number of key-value pairs)
---@param t table Table to check
---@return integer
function M.size(t)
    if type(t) ~= "table" then
        return 0
    end

    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

--- Check if table has a specific key
---@param t table Table to check
---@param key any Key to look for
---@return boolean
function M.has_key(t, key)
    if type(t) ~= "table" then
        return false
    end

    return t[key] ~= nil
end

--- Get all keys of a table
---@param t table Table to get keys from
---@return any[] Array of keys
function M.keys(t)
    if type(t) ~= "table" then
        return {}
    end

    ---@type any[]
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    return keys
end

--- Get all values of a table
---@param t table Table to get values from
---@return any[] Array of values
function M.values(t)
    if type(t) ~= "table" then
        return {}
    end

    ---@type any[]
    local values = {}
    for _, v in pairs(t) do
        values[#values + 1] = v
    end
    return values
end

---@alias PredicateFunction fun(key: any, value: any): boolean

--- Filter table by predicate function
---@param t table Table to filter
---@param predicate PredicateFunction Predicate function
---@return table Filtered table
function M.filter(t, predicate)
    if type(t) ~= "table" then
        return {}
    end

    ---@type table
    local result = {}
    for k, v in pairs(t) do
        if predicate(k, v) then
            result[k] = v
        end
    end
    return result
end

---@alias TransformFunction fun(key: any, value: any): any

--- Map table values using transform function
---@param t table Table to transform
---@param transform TransformFunction Transform function
---@return table Transformed table
function M.map(t, transform)
    if type(t) ~= "table" then
        return {}
    end

    ---@type table
    local result = {}
    for k, v in pairs(t) do
        result[k] = transform(k, v)
    end
    return result
end

---@alias TablePair {key: any, value: any}

--- Convert table to array of key-value pairs
---@param t table Table to convert
---@return TablePair[] Array of key-value pairs
function M.to_pairs(t)
    if type(t) ~= "table" then
        return {}
    end

    ---@type TablePair[]
    local pairs_array = {}
    for k, v in pairs(t) do
        pairs_array[#pairs_array + 1] = { key = k, value = v }
    end
    return pairs_array
end

--- Create table from array of key-value pairs
---@param pairs_array TablePair[] Array of key-value pairs
---@return table Reconstructed table
function M.from_pairs(pairs_array)
    if type(pairs_array) ~= "table" then
        return {}
    end

    ---@type table
    local result = {}
    for _, pair in ipairs(pairs_array) do
        if pair.key ~= nil then
            result[pair.key] = pair.value
        end
    end
    return result
end

--- Check if two tables are equal (shallow comparison)
---@param a table First table
---@param b table Second table
---@return boolean
function M.equals(a, b)
    if a == b then
        return true
    end

    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end

    if vim.tbl_count(a) ~= vim.tbl_count(b) then
        return false
    end

    for k, v in pairs(a) do
        if b[k] ~= v then
            return false
        end
    end

    return true
end

return M
