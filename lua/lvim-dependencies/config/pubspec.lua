-- lvim-dependencies/config/pubspec.lua
--- Pubspec manager specific configuration
---@class PubspecConfig

return {
    --- Executable paths for pubspec commands
    executables = {
        --- Path to flutter executable (nil = search in PATH)
        flutter = nil,
        --- Path to dart executable (nil = search in PATH)
        dart = nil,
    },
    --- API settings for pub.dev
    api = {
        --- Timeout in seconds for HTTP requests to pub.dev (default: 10)
        timeout = 10,
        --- Override default registry URL (nil = use manifest default)
        --- Example: "https://custom-pub.dev/api"
        registry_base = nil,
        --- Custom endpoint template (%s will be replaced with package name)
        --- Example: "/packages/%s.json"
        endpoint = nil,
    },
    --- File operation settings
    file_ops = {
        --- Root directory to start searching for pubspec.yaml (nil = use current working directory)
        --- Example: "~/projects"
        root_dir = nil,
        --- Custom file patterns if using non-standard filenames
        --- Example: { "custom.yaml", "deps.yaml" }
        file_patterns = nil,
    },
    --- Version comparison settings
    version = {
        --- Whether to include pre-release versions (alpha, beta, rc) in suggestions
        include_prerelease = true,
        --- Sort order: "desc" (newest first) or "asc" (oldest first)
        sort_order = "desc",
        --- Maximum versions to show in selector (default: 50)
        max_versions = 50,
    },
    --- Dependency sections configuration
    sections = {
        --- Order of sections when creating new ones
        order = { "dependencies", "dev_dependencies", "dependency_overrides" },
        --- Default section for new packages
        default = "dependencies",
    },
    --- SDK packages that skip registry lookup
    --- Merge with manifest.sdk_packages (manifest takes precedence for built-in ones)
    sdk_packages = {
        --- Add custom SDK packages here
        --- Example: my_custom_sdk = true
        -- flutter is already defined in manifest
    },
    --- Virtual text customization (optional override of global settings)
    virtual_text = {
        --- Position override for pubspec files (nil = use global config.ui.virtual_text.position)
        position = nil,
        --- Priority override for pubspec files (nil = use manifest default 1000)
        priority = nil,
    },
    polling = {
        --- Maximum number of polling attempts (default: 30)
        max_attempts = 30,
        --- Interval between polling attempts in milliseconds (default: 200)
        interval_ms = 200,
        --- Delay before starting first poll in milliseconds (default: 500)
        start_delay_ms = 500,
    },
}
