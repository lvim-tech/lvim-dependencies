-- lvim-dependencies/config/cache.lua
--- Cache configuration settings
---@class CacheConfig

return {
    --- Time-to-live settings for different cache types (in seconds)
    ttl = {
        installed = 300, -- 5 minutes - how long to keep installed package info
        latest = 1800, -- 30 minutes - how long to keep latest version info
        manifest = 3600, -- 1 hour - how long to keep manifest data
        declared = nil, -- No expiry - declared packages don't expire automatically
    },
    -- Cache cleanup settings
    cleanup = {
        interval = 3600000, -- 1 hour (in milliseconds) - how often to run cleanup
        threshold = 0.8, -- 80% of max capacity - when to trigger cleanup
        max_entries = 1000, -- Maximum entries per manager before cleanup
    },
    --- Cache statistics collection
    stats = {
        collect = true, -- Whether to collect cache statistics
        warn_threshold = 500, -- Warn when cache exceeds this many entries
    },
    managers_cache_ttl = 5000, -- 5 seconds
    manifest_type_cache_ttl = 5000, -- 5 seconds
}
