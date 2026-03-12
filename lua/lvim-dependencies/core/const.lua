-- lvim-dependencies/core/const.lua
-- Centralized constants for the entire plugin

---@class Namespaces
local M = {
    -- ============================================================================
    -- Namespaces (fixed, technical)
    -- ============================================================================
    NAMESPACES = {
        VIRTUAL_TEXT = "lvim-deps-virt",
        DIAGNOSTICS = "lvim-deps-diagnostic",
        HOVER = "lvim-deps-hover",
        PENDING_ANCHOR = "lvim-deps-pending",
        HIGHLIGHT = "lvim-deps-highlight",
    },

    -- ============================================================================
    -- Events (fixed event names)
    -- ============================================================================
    EVENTS = {
        -- Buffer events
        BUFFER_OPENED = "opened",
        BUFFER_SAVED = "saved",
        BUFFER_MODIFIED = "modified",
        BUFFER_CLOSED = "closed",
        BUFFER_ENTERED = "entered",
        BUFFER_FILETYPE_CHANGED = "filetype_changed",

        -- Package events
        PACKAGE_LOADED = "package_loaded",
        PACKAGE_UPDATED = "package_updated",
        PACKAGE_REMOVED = "package_removed",
        PACKAGE_INSTALLED = "package_installed",

        -- Cache events
        CACHE_HIT = "cache_hit",
        CACHE_MISS = "cache_miss",
        CACHE_CLEARED = "cache_cleared",
        CACHE_EXPIRED = "cache_expired",
        CACHE_STATS_RESET = "cache_stats_reset",

        -- Debug
        DEBUG = "debug",
    },

    -- ============================================================================
    -- Core command names (fixed)
    -- ============================================================================
    COMMANDS = {
        HELP = "help",
        SHOW_REGISTRY = "show-registry",
        SHOW_MANAGER = "show-manager",
        CACHE = "cache",
        STATE = "state",
        METRICS = "metrics",
        INSTALL = "install",
        UPDATE = "update",
        UPDATE_DIRECT = "update-direct",
        DELETE = "delete",
        SHOW = "show",
        HIDE = "hide",
        TOGGLE = "toggle",
        CLEAR_DECLARED = "clear-declared",
        CLEAR_INSTALLED = "clear-installed",
        CLEAR_LATEST = "clear-latest",
        CLEAR_ALL = "clear-all-caches",
        CACHE_STATS = "cache-stats",
    },

    -- ============================================================================
    -- Cache types (fixed)
    -- ============================================================================
    CACHE_TYPES = {
        DECLARED = "declared",
        INSTALLED = "installed",
        LATEST = "latest",
        VIRTUAL_TEXT = "virtual_text",
        MANIFEST = "manifest",
    },

    -- ============================================================================
    -- Cache fields (used in CacheEntry structure)
    -- ============================================================================
    CACHE_FIELDS = {
        DATA = "data",
        METADATA = "metadata",
        TEMP = "temp",
        EXPIRY = "expiry",
        VERSION = "version",
        CREATED_AT = "created_at",
        ACCESS_COUNT = "access_count",
        LAST_ACCESS = "last_access",
    },

    -- ============================================================================
    -- Module types (fixed)
    -- ============================================================================
    MODULE_TYPES = {
        DECLARED = "declared",
        LATEST = "latest",
        INSTALLER = "installer",
        MANIFEST = "manifest",
        VIRTUAL_TEXT = "virtual_text",
    },

    -- ============================================================================
    -- Loader types (used with get_loader function)
    -- ============================================================================
    LOADER_TYPES = {
        DECLARED = "declared",
        LATEST = "latest",
    },

    -- ============================================================================
    -- Module cache constants
    -- ============================================================================
    MODULE_CACHE = {
        SUFFIX = "_module",
    },

    -- ============================================================================
    -- Manager module paths
    -- ============================================================================
    MANAGER_PATHS = {
        MANIFEST_PATTERN = "lua/lvim-dependencies/managers/*/manifest.lua",
        REGISTER_MODULE = "lvim-dependencies.managers.%s.register",
    },

    -- ============================================================================
    -- Installer methods and operations
    -- ============================================================================
    INSTALLER_METHODS = {
        INSTALL = "install",
        UPDATE = "update",
        DELETE = "delete",
        UPDATE_DIRECT = "update_direct",
        CHECK_OUTDATED = "check_outdated",
    },

    OPERATION_NAMES = {
        ["install"] = "Installing",
        ["update"] = "Updating",
        ["delete"] = "Deleting",
        ["update_direct"] = "Direct updating",
        ["check_outdated"] = "Checking outdated",
    },

    -- ============================================================================
    -- Metrics patterns and types
    -- ============================================================================
    METRICS = {
        LOG_LEVELS = {
            DEBUG = vim.log.levels.DEBUG,
            INFO = vim.log.levels.INFO,
            WARN = vim.log.levels.WARN,
            ERROR = vim.log.levels.ERROR,
        },

        ERROR_TYPES = {
            TIMEOUT = "timeout",
            NOT_FOUND = "not_found",
            NETWORK = "network",
            OTHER = "other",
        },

        CACHE_PATTERNS = {
            HIT = "HUB cache HIT",
            MISS = "HUB cache MISS",
            EXPIRY = "HUB cache EXPIRED",
        },

        OPERATION_PATTERNS = {
            LOADING_PACKAGE = "Loading package",
            BUFFER_SAVED = "Buffer saved",
            BUFFER_OPENED = "Buffer opened",
        },
    },

    -- ============================================================================
    -- Statistics types
    -- ============================================================================
    STATS_TYPES = {
        CACHE_HITS = "cache_hits",
        CACHE_MISSES = "cache_misses",
        CACHE_EXPIRY = "cache_expiry",
        CACHE_CLEARS = "cache_clears",
        LOAD_TIMES = "load_times",
        OPERATION_TIMES = "operation_times",
    },
}

return M
