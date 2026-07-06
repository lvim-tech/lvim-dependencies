-- lvim-dependencies.core.metrics: in-memory instrumentation for the plugin. Records
-- cache hits/misses/expiries, per-package load timings (via a start_measure token that
-- end_measure consumes, so out-of-order concurrent measurements are attributed correctly),
-- operation timelines and error tallies, then renders them as a markdown report (with
-- sparklines) into a float.
-- Numeric-keyed tables (e.g. by_level keyed on vim.log.levels) are stringified before
-- JSON save because vim.json.encode rejects sparse arrays.
--
---@module "lvim-dependencies.core.metrics"

local events = require("lvim-dependencies.core.events")
local levels = require("lvim-dependencies.utils.levels")
local notify = require("lvim-dependencies.utils").notify
local float = require("lvim-dependencies.ui")
local const = require("lvim-dependencies.core.const")
local config = require("lvim-dependencies.config")

-- ============================================================================
-- Constants
-- ============================================================================
local MAX_EXAMPLES = config.metrics.max_examples or 3
local MAX_TOP_MESSAGES = config.metrics.max_top_messages or 5
local MAX_SLOWEST_PACKAGES = config.metrics.max_slowest_packages or 5
local DEFAULT_REFRESH_INTERVAL = config.metrics.default_refresh_interval or 2

local LOG_LEVELS = const.METRICS.LOG_LEVELS
local ERROR_TYPES = const.METRICS.ERROR_TYPES
local OPERATION_PATTERNS = const.METRICS.OPERATION_PATTERNS

-- Local references for performance
local os_time = os.time
local os_difftime = os.difftime
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local table_concat = table.concat
local string_format = string.format
local vim_schedule = vim.schedule_wrap

---@class ExampleEntry
---@field messages string[]
---@field timestamp integer

---@class PackagePerfEntry
---@field count integer
---@field total number
---@field last_access integer

---@class ByPackagePerf
---@field latest table<string, PackagePerfEntry>
---@field installed table<string, PackagePerfEntry>

---@class MeasureToken
---@field name string
---@field start integer nanosecond hrtime at start

local M = {
    stats = nil, -- will be initialized in setup
}

-- ============================================================================
-- Stats creation
-- ============================================================================

--- Create a fresh stats structure
---@return MetricsStats
local function create_stats()
    return {
        cache = {
            hits = 0,
            misses = 0,
            expiries = 0,
            clears = 0,
            by_manager = {},
        },
        session = {
            hits = 0,
            misses = 0,
            files_opened = 0,
            start_time = os_time(),
        },
        by_level = {
            [LOG_LEVELS.DEBUG] = 0,
            [LOG_LEVELS.INFO] = 0,
            [LOG_LEVELS.WARN] = 0,
            [LOG_LEVELS.ERROR] = 0,
        },
        msg_types = {},
        msg_examples = {},
        performance = {
            load_times = {},
            ---@type ByPackagePerf
            by_package = {
                latest = {}, -- HTTP fetch times (slow, network-bound)
                installed = {}, -- Lock file read times (fast, disk-bound)
            },
            slowest = { name = "", time = 0 },
        },
        errors = {
            total = 0,
            by_manager = {},
            by_type = {},
        },
        operations = {
            total_loads = 0,
            total_saves = 0,
            total_opens = 0,
        },
        buffers = {
            active = 0,
            with_virtual_text = 0,
        },
        timestamps = {
            start = os_time(),
            last_reset = os_time(),
        },
        timeline = {
            operations = {},
            max_entries = 100,
        },
        trends = {
            hourly = {},
            daily = {},
        },
    }
end

-- ============================================================================
-- CENTRALIZED cache event recording
-- ============================================================================

--- Record a cache hit or miss — the single source of truth for cache stats.
---@param manager_type string
---@param hit boolean
function M.record_cache_event(manager_type, hit)
    if not M.stats then
        return
    end
    if not config.cache.stats.collect then
        return
    end

    local cache_stats = M.stats.cache
    local session_stats = M.stats.session
    -- nil guards for lua-ls (create_stats always sets these, but annotate defensively)
    if not cache_stats or not session_stats then
        return
    end

    local field = hit and "hits" or "misses"

    cache_stats[field] = (cache_stats[field] or 0) + 1
    session_stats[field] = (session_stats[field] or 0) + 1

    if manager_type then
        local by_manager = cache_stats.by_manager
        if not by_manager then
            return
        end
        local mgr = by_manager[manager_type]
        if not mgr then
            mgr = { hits = 0, misses = 0 }
            by_manager[manager_type] = mgr
        end
        mgr[field] = mgr[field] + 1
    end
end

--- Record a cache expiry event
---@param manager_type string
function M.record_cache_expiry(manager_type)
    if not M.stats then
        return
    end
    M.stats.cache.expiries = (M.stats.cache.expiries or 0) + 1
    M.record_cache_event(manager_type, false)
end

--- Record a cache clear event
function M.record_cache_clear()
    if not M.stats then
        return
    end
    M.stats.cache.clears = (M.stats.cache.clears or 0) + 1
end

--- Record an error
---@param manager_type? string
---@param error_type? string
function M.record_error(manager_type, error_type)
    if not M.stats then
        return
    end
    local errors = M.stats.errors
    errors.total = errors.total + 1

    if manager_type then
        errors.by_manager[manager_type] = (errors.by_manager[manager_type] or 0) + 1
    end

    local et = error_type or ERROR_TYPES.OTHER
    errors.by_type[et] = (errors.by_type[et] or 0) + 1
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function hit_ratio(hits, misses)
    local total = hits + misses
    return total == 0 and 0 or math_floor((hits / total) * 10000) / 100
end

local function get_message_type(msg)
    local words = {}
    for word in msg:gmatch("%S+") do
        table.insert(words, word)
        if #words >= 3 then
            break
        end
    end
    return #words >= 3 and table_concat(words, " ") .. "..." or msg:sub(1, 30) .. (#msg > 30 and "..." or "")
end

local function store_example(msg_type, msg)
    ---@type ExampleEntry|nil
    local examples = M.stats.msg_examples[msg_type]
    local now = os_time()

    if not examples then
        M.stats.msg_examples[msg_type] = { messages = { msg }, timestamp = now }
    elseif #examples.messages < MAX_EXAMPLES then
        examples.messages[#examples.messages + 1] = msg
    elseif now - examples.timestamp > 3600 then
        examples.messages = { msg }
        examples.timestamp = now
    end
end

local function generate_sparkline(values, max_width)
    max_width = max_width or 30
    if #values == 0 then
        return ""
    end

    local max = 0
    for _, v in ipairs(values) do
        max = math_max(max, v)
    end
    if max == 0 then
        return ""
    end

    local chars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    local result = {}

    for i = 1, math_min(max_width, #values) do
        local idx = #values - max_width + i
        if idx >= 1 then
            local normalized = values[idx] / max
            local char_idx = math_floor(normalized * (#chars - 1)) + 1
            result[#result + 1] = chars[char_idx]
        end
    end

    return table_concat(result)
end

--- Record performance measurement from a debug message containing "Xms".
--- NOTE: Authoritative per-package timing comes from start_measure/end_measure.
--- This only adds to the general load_times sparkline.
---@param msg string
local function record_performance(msg)
    local duration = tonumber(msg:match("(%d+)ms"))
    if not duration then
        return
    end

    local times = M.stats.performance.load_times
    times[#times + 1] = duration
    if #times > 1000 then
        table.remove(times, 1)
    end

    M.record_operation("debug_msg", duration)
end

--- Record error from debug message
---@param msg string
local function record_error_from_msg(msg)
    local manager = msg:match("([%w_]+)[:/]") or msg:match("for (%w+)")
    local error_type = msg:match("timeout") and ERROR_TYPES.TIMEOUT
        or msg:match("not found") and ERROR_TYPES.NOT_FOUND
        or msg:match("network") and ERROR_TYPES.NETWORK
        or ERROR_TYPES.OTHER
    M.record_error(manager, error_type)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Handle debug messages (called by event bus)
---@param msg string
---@param level string|integer
function M.handle_debug(msg, level)
    if not M.stats then
        return
    end

    local level_num = type(level) == "string" and levels.to_level_number(level) or level
    M.stats.by_level[level_num] = (M.stats.by_level[level_num] or 0) + 1

    local msg_type = get_message_type(msg)
    M.stats.msg_types[msg_type] = (M.stats.msg_types[msg_type] or 0) + 1
    store_example(msg_type, msg)

    -- NOTE: Cache HIT/MISS/EXPIRED are already recorded directly by hub modules
    -- via metrics.record_cache_event(). We do NOT double-count them here.
    -- We only parse messages for performance timing and operation counts.
    if msg:find("(%d+)ms") then
        record_performance(msg)
    elseif msg:find(OPERATION_PATTERNS.LOADING_PACKAGE) then
        M.stats.operations.total_loads = M.stats.operations.total_loads + 1
    elseif msg:find(OPERATION_PATTERNS.BUFFER_SAVED) then
        M.stats.operations.total_saves = M.stats.operations.total_saves + 1
    elseif msg:find(OPERATION_PATTERNS.BUFFER_OPENED) then
        M.stats.operations.total_opens = M.stats.operations.total_opens + 1
        M.stats.session.files_opened = M.stats.session.files_opened + 1
    end

    if level_num >= LOG_LEVELS.ERROR then
        record_error_from_msg(msg)
    end
end

--- Start measuring an operation.
--- Returns a token that must be handed back to end_measure. Concurrent/nested
--- measurements each carry their own token, so a lookup that finishes out of order
--- (10 in flight at once) is always attributed to the RIGHT operation — there is no
--- shared LIFO stack to corrupt, and an early return simply drops the token (no leak).
---@param name string
---@return MeasureToken
function M.start_measure(name)
    return {
        name = name,
        start = vim.uv.hrtime(),
    }
end

--- End measuring and record duration.
---@param token? MeasureToken
---@return number
function M.end_measure(token)
    if not token then
        return 0
    end

    local duration = (vim.uv.hrtime() - token.start) / 1e6

    if not M.stats then
        return duration
    end

    local times = M.stats.performance.load_times
    times[#times + 1] = duration
    if #times > 1000 then
        table.remove(times, 1)
    end

    local name = token.name
    if name then
        -- Route to the correct by_package sub-table:
        --   "latest:lookup:<pkg>"    → by_package.latest    (HTTP, slow)
        --   "installed:lookup:<pkg>" → by_package.installed (lock file, fast)
        --   everything else          → skip
        local category = name:match("^(latest):lookup:") or name:match("^(installed):lookup:")
        local pkg = category and name:match("^[^:]+:lookup:(.+)$") or nil

        if category and pkg and pkg ~= "" then
            ---@type ByPackagePerf
            local by_pkg = M.stats.performance.by_package
            local bucket = by_pkg[category]
            if bucket then
                ---@type PackagePerfEntry
                local entry = bucket[pkg]
                if not entry then
                    entry = { count = 0, total = 0, last_access = os_time() }
                    bucket[pkg] = entry
                end
                entry.count = entry.count + 1
                entry.total = entry.total + duration
                entry.last_access = os_time()

                if duration > M.stats.performance.slowest.time then
                    M.stats.performance.slowest = { name = pkg, time = duration, category = category }
                end
            end
        end

        M.record_operation(name, duration)
    end

    return duration
end

--- Record operation timeline
---@param name string
---@param duration number
function M.record_operation(name, duration)
    if not M.stats then
        return
    end
    local timeline = M.stats.timeline
    if not timeline then
        timeline = { operations = {}, max_entries = 100 }
        M.stats.timeline = timeline
    end

    timeline.operations[#timeline.operations + 1] = {
        name = name,
        duration = duration,
        timestamp = os_time(),
    }

    if #timeline.operations > timeline.max_entries then
        table.remove(timeline.operations, 1)
    end

    local hour = math_floor(os_time() / 3600)
    M.stats.trends.hourly[hour] = (M.stats.trends.hourly[hour] or 0) + 1

    local day = math_floor(os_time() / 86400)
    M.stats.trends.daily[day] = (M.stats.trends.daily[day] or 0) + 1
end

--- Update buffer statistics
---@param active integer
---@param with_vt integer
function M.update_buffers(active, with_vt)
    if not M.stats then
        M.stats = create_stats()
    end
    M.stats.buffers.active = active
    M.stats.buffers.with_virtual_text = with_vt
end

--- Reset all statistics
function M.reset()
    if not M.stats then
        M.stats = create_stats()
    end
    local original_start = M.stats.timestamps.start
    M.stats = create_stats()
    M.stats.timestamps.start = original_start
    M.stats.timestamps.last_reset = os_time()
end

--- Get cache hit ratio
---@return number
function M.get_cache_ratio()
    return hit_ratio(M.stats.cache.hits, M.stats.cache.misses)
end

--- Get session cache hit ratio
---@return number
function M.get_session_cache_ratio()
    return hit_ratio(M.stats.session.hits, M.stats.session.misses)
end

--- Get average load time
---@return number
function M.get_avg_load_time()
    local times = M.stats.performance.load_times
    if #times == 0 then
        return 0
    end
    local sum = 0
    for i = 1, #times do
        sum = sum + times[i]
    end
    return math_floor((sum / #times) * 100) / 100
end

--- Get error rate
---@return number
function M.get_error_rate()
    local total_ops = M.stats.operations.total_loads
    return total_ops == 0 and 0 or math_floor((M.stats.errors.total / total_ops) * 10000) / 100
end

--- Get top message types
---@param n? integer
---@return {type: string, count: integer}[]
function M.get_top_message_types(n)
    n = n or MAX_TOP_MESSAGES
    local sorted = {}
    for msg_type, count in pairs(M.stats.msg_types) do
        sorted[#sorted + 1] = { type = msg_type, count = count }
    end
    table.sort(sorted, function(a, b)
        return a.count > b.count
    end)
    local result = {}
    for i = 1, math_min(n, #sorted) do
        result[i] = sorted[i]
    end
    return result
end

--- Get trending packages — only real package names from latest lookups,
--- sorted by recency-weighted access count.
---@param limit integer
---@return string[]
function M.get_trending_packages(limit)
    limit = limit or 10
    local now = os_time()
    local trending = {}
    -- Trending is based on latest lookups (most meaningful for "what are you working on")
    ---@type ByPackagePerf
    local by_package = M.stats.performance.by_package
    for pkg, data in pairs(by_package.latest or {}) do
        local recency = data.last_access and (now - data.last_access) or 3600
        local score = data.count * (1000 / math_max(recency, 1))
        trending[#trending + 1] = { name = pkg, score = score }
    end
    table.sort(trending, function(a, b)
        return a.score > b.score
    end)
    local result = {}
    for i = 1, math_min(limit, #trending) do
        result[i] = trending[i].name
    end
    return result
end

-- ============================================================================
-- Save / Load
-- ============================================================================

--- Prepare stats for JSON encoding:
--- vim.json.encode fails on sparse arrays (e.g. by_level uses vim.log.levels as keys: 0,1,2,4).
--- Convert all numeric-keyed tables to string-keyed objects recursively.
---@param val any
---@return any
local function prepare_for_json(val)
    if type(val) ~= "table" then
        return val
    end

    -- Check if table is a dense array starting from 1
    local n = #val
    local count = 0
    for _ in pairs(val) do
        count = count + 1
    end

    if n > 0 and n == count then
        -- Dense array — recurse values only
        local result = {}
        for i, v in ipairs(val) do
            result[i] = prepare_for_json(v)
        end
        return result
    else
        -- Object or sparse array — convert all keys to strings
        local result = {}
        for k, v in pairs(val) do
            result[tostring(k)] = prepare_for_json(v)
        end
        return result
    end
end

--- Rebuild a live stats table from JSON-decoded data. Undoes prepare_for_json's string-key
--- coercion where the live schema uses numeric keys (by_level is keyed on vim.log.levels),
--- and merges onto a fresh create_stats() skeleton so any field absent from the file keeps
--- its default shape instead of leaving a hole the report/handlers would crash on.
---@param data table
---@return MetricsStats
local function restore_from_json(data)
    local stats = create_stats()
    for section, value in pairs(data) do
        if type(value) == "table" and type(stats[section]) == "table" then
            for k, v in pairs(value) do
                stats[section][k] = v
            end
        else
            stats[section] = value
        end
    end

    -- by_level is keyed on vim.log.levels (0,1,2,4); JSON encode turned those into "0".."4".
    if type(data.by_level) == "table" then
        local restored = {
            [LOG_LEVELS.DEBUG] = 0,
            [LOG_LEVELS.INFO] = 0,
            [LOG_LEVELS.WARN] = 0,
            [LOG_LEVELS.ERROR] = 0,
        }
        for k, v in pairs(data.by_level) do
            restored[tonumber(k) or k] = v
        end
        stats.by_level = restored
    end

    return stats
end

---@param filepath? string
function M.save(filepath)
    filepath = filepath or vim.fn.stdpath("data") .. "/lvim-dependencies-metrics.json"

    local ok, encoded = pcall(vim.json.encode, prepare_for_json(M.stats))
    if not ok or not encoded then
        notify(string_format(" Failed to encode metrics: %s", tostring(encoded)), vim.log.levels.ERROR)
        return
    end

    local file, err = io.open(filepath, "w")
    if not file then
        notify(string_format(" Failed to open file: %s", tostring(err)), vim.log.levels.ERROR)
        return
    end

    local write_ok, write_err = pcall(function()
        file:write(encoded)
        file:close()
    end)

    if write_ok then
        notify(string_format(" Metrics saved to %s", filepath), vim.log.levels.INFO)
    else
        notify(string_format(" Failed to write metrics: %s", tostring(write_err)), vim.log.levels.ERROR)
    end
end

---@param filepath? string
function M.load(filepath)
    filepath = filepath or vim.fn.stdpath("data") .. "/lvim-dependencies-metrics.json"

    local f = io.open(filepath, "r")
    if not f then
        notify(string_format("No metrics file found at %s", filepath), vim.log.levels.WARN)
        return
    end

    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        notify(" Metrics file is empty", vim.log.levels.ERROR)
        return
    end

    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        M.stats = restore_from_json(data)
        notify(string_format(" Metrics loaded from %s", filepath), vim.log.levels.INFO)
    else
        notify(string_format(" Failed to parse metrics: %s", tostring(data)), vim.log.levels.ERROR)
    end
end

-- ============================================================================
-- Display
-- ============================================================================

local function update_float_content(buf, win, content)
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    local lines = vim.split(content, "\n")
    local cursor = vim.api.nvim_win_get_cursor(win)
    pcall(function()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        if cursor[1] <= #lines then
            vim.api.nvim_win_set_cursor(win, cursor)
        end
    end)
    return true
end

local function format_session_duration()
    local duration = os_difftime(os_time(), M.stats.session.start_time)
    return string_format("%dm %ds", math_floor(duration / 60), duration % 60)
end

--- Render the full metrics report as a markdown string.
---@return string
function M.report()
    local lines = {}
    local add = function(...)
        for i = 1, select("#", ...) do
            lines[#lines + 1] = select(i, ...)
        end
    end

    add("# Dependencies Metrics", "")
    add("## Session Statistics", "")
    add(string_format("- **Duration:** %s", format_session_duration()))
    add(string_format("- **Files opened:** %d", M.stats.session.files_opened))
    add(
        string_format(
            "- **Cache:** %d hits, %d misses (%d%%)",
            M.stats.session.hits,
            M.stats.session.misses,
            M.get_session_cache_ratio()
        )
    )
    add("")

    add("## Total Statistics", "")
    add(
        string_format(
            "- **Cache:** %d hits, %d misses (%.1f%%)",
            M.stats.cache.hits,
            M.stats.cache.misses,
            M.get_cache_ratio()
        )
    )
    add("")

    local cache_by_manager = M.stats.cache.by_manager
    if next(cache_by_manager) then
        add("### Cache by Manager", "")
        add("| Manager | Hits/Misses | Ratio |")
        add("|---------|-------------|-------|")
        for manager, mgr_stats in pairs(cache_by_manager) do
            local total = mgr_stats.hits + mgr_stats.misses
            local ratio = total > 0 and math_floor((mgr_stats.hits / total) * 100) or 0
            add(string_format("| %s | %d/%d | %d%% |", manager, mgr_stats.hits, mgr_stats.misses, ratio))
        end
        add("")
    end

    add("## Message Statistics", "")
    for _, level_name in ipairs({ "DEBUG", "INFO", "WARN", "ERROR" }) do
        local level_val = vim.log.levels[level_name]
        add(string_format("- **%s:** %d", level_name, M.stats.by_level[level_val] or 0))
    end
    add("")

    local top_msgs = M.get_top_message_types(MAX_TOP_MESSAGES)
    if #top_msgs > 0 then
        add(string_format("### Top %d Message Types", MAX_TOP_MESSAGES), "")
        add("| # | Type | Count |")
        add("|---|------|-------|")
        for i, item in ipairs(top_msgs) do
            local display = #item.type > 50 and item.type:sub(1, 47) .. "..." or item.type
            add(string_format("| %d | %s | %d |", i, display, item.count))
        end
        add("")
        local top_examples = M.stats.msg_examples[top_msgs[1].type]
        if top_examples and top_examples.messages then
            add("### Examples (Top Type)", "")
            for i, example in ipairs(top_examples.messages) do
                add(string_format("%d. `%s`", i, example))
            end
            add("")
        end
    end

    if #M.stats.performance.load_times > 0 then
        add("## Performance", "")
        add(string_format("- **Average load time:** %.2f ms", M.get_avg_load_time()))
        if M.stats.performance.slowest.time > 0 then
            add(
                string_format(
                    "- **Slowest package:** `%s` (%.2f ms)",
                    M.stats.performance.slowest.name,
                    M.stats.performance.slowest.time
                )
            )
        end
        local recent = {}
        for i = math_max(1, #M.stats.performance.load_times - 50), #M.stats.performance.load_times do
            recent[#recent + 1] = M.stats.performance.load_times[i]
        end
        if #recent > 0 then
            add(string_format("- **Recent trend:** %s", generate_sparkline(recent, 30)))
        end
        add("")

        ---@type ByPackagePerf
        local by_package = M.stats.performance.by_package

        -- Slowest latest lookups (network fetches)
        local slowest_latest = {}
        for pkg, data in pairs(by_package.latest or {}) do
            if data.count > 0 then
                slowest_latest[#slowest_latest + 1] = {
                    name = pkg,
                    avg = data.total / data.count,
                    count = data.count,
                }
            end
        end
        table.sort(slowest_latest, function(a, b)
            return a.avg > b.avg
        end)
        if #slowest_latest > 0 then
            add(string_format("### Top %d Slowest — Latest Fetch (network)", MAX_SLOWEST_PACKAGES), "")
            add("| # | Package | Avg (ms) | Calls |")
            add("|---|---------|----------|-------|")
            for i = 1, math_min(MAX_SLOWEST_PACKAGES, #slowest_latest) do
                local p = slowest_latest[i]
                add(string_format("| %d | `%s` | %.2f | %d |", i, p.name, p.avg, p.count))
            end
            add("")
        end

        -- Slowest installed lookups (lock file reads)
        local slowest_installed = {}
        for pkg, data in pairs(by_package.installed or {}) do
            if data.count > 0 then
                slowest_installed[#slowest_installed + 1] = {
                    name = pkg,
                    avg = data.total / data.count,
                    count = data.count,
                }
            end
        end
        table.sort(slowest_installed, function(a, b)
            return a.avg > b.avg
        end)
        if #slowest_installed > 0 then
            add(string_format("### Top %d Slowest — Installed Lookup (lock file)", MAX_SLOWEST_PACKAGES), "")
            add("| # | Package | Avg (ms) | Calls |")
            add("|---|---------|----------|-------|")
            for i = 1, math_min(MAX_SLOWEST_PACKAGES, #slowest_installed) do
                local p = slowest_installed[i]
                add(string_format("| %d | `%s` | %.2f | %d |", i, p.name, p.avg, p.count))
            end
            add("")
        end
    end

    local trending = M.get_trending_packages(5)
    if #trending > 0 then
        add("### Trending Packages", "")
        for i, pkg in ipairs(trending) do
            add(string_format("%d. `%s`", i, pkg))
        end
        add("")
    end

    if M.stats.errors.total > 0 then
        add("## Errors", "")
        add(string_format("- **Total:** %d", M.stats.errors.total))
        add(string_format("- **Rate:** %.1f%%", M.get_error_rate()))
        add("")
        if next(M.stats.errors.by_type) then
            add("### By Type", "")
            for err_type, count in pairs(M.stats.errors.by_type) do
                add(string_format("- **%s:** %d", err_type, count))
            end
            add("")
        end
    end

    add("## Buffers & Operations", "")
    add(string_format("- **Active buffers:** %d", M.stats.buffers.active))
    add(string_format("- **Buffers with VT:** %d", M.stats.buffers.with_virtual_text))
    add(string_format("- **Total loads:** %d", M.stats.operations.total_loads))
    add(string_format("- **Total saves:** %d", M.stats.operations.total_saves))
    add(string_format("- **Total opens:** %d", M.stats.operations.total_opens))

    return table_concat(lines, "\n")
end

local function stop_timer(timer)
    if timer then
        pcall(function()
            timer:stop()
            timer:close()
        end)
    end
end

--- Open the report in a float with reload/copy/reset/save/load keymaps.
---@return integer? buf, integer? win
function M.show()
    local content = M.report()
    local buf, win = float.open(content, " Dependencies Metrics ")

    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.keymap.set("n", "r", function()
            float.close(win)
            M.show()
        end, { buffer = buf, silent = true, nowait = true })
        vim.keymap.set("n", "y", function()
            vim.fn.setreg("+", M.report())
            notify("Metrics copied to clipboard", vim.log.levels.INFO)
        end, { buffer = buf, silent = true, nowait = true })
        vim.keymap.set("n", "R", function()
            M.reset()
            float.close(win)
            M.show()
            notify("Metrics reset", vim.log.levels.INFO)
        end, { buffer = buf, silent = true, nowait = true })
        vim.keymap.set("n", "s", function()
            M.save()
        end, { buffer = buf, silent = true, nowait = true })
        vim.keymap.set("n", "l", function()
            M.load()
            float.close(win)
            M.show()
        end, { buffer = buf, silent = true, nowait = true })
    end

    return buf, win
end

--- Open the report in a float that auto-refreshes on a timer.
---@param refresh_interval? number Seconds between refreshes
---@return integer? buf, integer? win
function M.show_live(refresh_interval)
    refresh_interval = refresh_interval or DEFAULT_REFRESH_INTERVAL
    local content = M.report()
    local buf, win = float.open(content, " Dependencies Metrics (live) ")

    if not buf or not vim.api.nvim_buf_is_valid(buf) or not win or not vim.api.nvim_win_is_valid(win) then
        return buf, win
    end

    local timer = vim.uv.new_timer()
    if not timer then
        return buf, win
    end

    local interval_ms = refresh_interval * 1000
    timer:start(
        interval_ms,
        interval_ms,
        vim_schedule(function()
            if not update_float_content(buf, win, M.report()) then
                stop_timer(timer)
            end
        end)
    )

    local function close_live()
        stop_timer(timer)
        float.close(win)
    end

    vim.keymap.set("n", "q", close_live, { buffer = buf, silent = true, nowait = true })
    vim.keymap.set("n", "<ESC>", close_live, { buffer = buf, silent = true, nowait = true })
    vim.keymap.set("n", "r", function()
        update_float_content(buf, win, M.report())
    end, { buffer = buf, silent = true, nowait = true })
    vim.keymap.set("n", "s", function()
        M.save()
    end, { buffer = buf, silent = true, nowait = true })

    return buf, win
end

-- ============================================================================
-- Setup
-- ============================================================================

---@type uv.uv_timer_t|nil
local _auto_save_timer = nil

--- Initialize stats, subscribe to debug events, and start the auto-save timer.
function M.setup()
    M.stats = create_stats()
    if not config.metrics.enabled then
        return
    end
    events.on(const.EVENTS.DEBUG, M.handle_debug)

    local auto_save_interval = config.metrics.auto_save_interval or 3600000

    if _auto_save_timer then
        pcall(function()
            _auto_save_timer:stop()
            _auto_save_timer:close()
        end)
    end

    _auto_save_timer = vim.uv.new_timer()
    if _auto_save_timer then
        _auto_save_timer:start(
            auto_save_interval,
            auto_save_interval,
            vim.schedule_wrap(function()
                M.save()
            end)
        )
    end
end

return M
