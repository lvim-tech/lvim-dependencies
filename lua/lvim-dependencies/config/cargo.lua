-- lvim-dependencies/config/cargo.lua
--- Cargo manager specific configuration
---@class CargoConfig

return {
    --- Executable paths for cargo commands
    executables = {
        --- Path to cargo executable (nil = search in PATH)
        cargo = nil,
        --- Path to rustc executable (nil = search in PATH)
        rustc = nil,
    },
    --- API settings for crates.io
    api = {
        --- Timeout in seconds for HTTP requests to crates.io (default: 10)
        timeout = 10,
        --- Override default registry URL (nil = use manifest default)
        --- Example: "https://custom-registry.com/api/v1"
        registry_base = nil,
        --- Custom endpoint template (%s will be replaced with package name)
        --- Example: "/crates/%s"
        endpoint = nil,
    },
    --- File operation settings
    file_ops = {
        --- Root directory to start searching for Cargo.toml (nil = use current working directory)
        --- Example: "~/rust-projects"
        root_dir = nil,
        --- Custom file patterns if using non-standard filenames
        --- Example: { "Cargo.toml", "rust-project.toml" }
        file_patterns = nil,
    },
    --- Version comparison settings
    version = {
        --- Whether to include pre-release versions (alpha, beta, rc) in suggestions
        include_prerelease = false,
        --- Sort order: "desc" (newest first) or "asc" (oldest first)
        sort_order = "desc",
        --- Maximum versions to show in selector (default: 50)
        max_versions = 50,
    },
    --- Virtual text display settings
    display = {
        --- Whether to show features in virtual text (default: true)
        --- When false, only version information is shown
        show_features = true,
        -- Whether to filter out "default" feature from display (default: true)
        -- When true, the "default" feature is not shown in virtual text
        -- as it's usually just noise and doesn't provide additional information
        filter_default = true,
        --- Whether to show optional flag in virtual text (default: false)
        --- When true, shows "[opt]" for optional dependencies
        show_optional = false,
        --- Whether to show default-features flag in virtual text (default: false)
        --- When true, shows "[no-default]" when default-features = false
        show_default_features = false,
        --- Maximum number of features to show before truncating (default: 3)
        --- Set to 0 for no limit
        max_features_display = 3,
        --- Truncation indicator when features are truncated (default: "...")
        truncation_indicator = "...",
    },
    --- Virtual text customization (optional override of global settings)
    virtual_text = {
        --- Position override for Cargo.toml files (nil = use global config.ui.virtual_text.position)
        position = nil,
        --- Priority override for Cargo.toml files (nil = use manifest default 1000)
        priority = nil,
    },
    --- Polling settings for outdated checks
    polling = {
        --- Maximum number of polling attempts (default: 30)
        max_attempts = 30,
        --- Interval between polling attempts in milliseconds (default: 200)
        interval_ms = 200,
        --- Delay before starting first poll in milliseconds (default: 500)
        start_delay_ms = 500,
    },
}
