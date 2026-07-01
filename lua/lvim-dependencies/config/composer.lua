-- lvim-dependencies.config.composer: Composer/packagist.org manager settings — executable,
-- API endpoints, version selection, dependency sections and outdated polling. Merged over by
-- the user's opts, then read live by the composer manager.
---@module "lvim-dependencies.config.composer"

---@class ComposerConfig
return {
    --- Executable paths for composer commands
    executables = {
        --- Path to composer executable (nil = search in PATH)
        composer = nil,
    },
    --- API settings for packagist.org
    api = {
        --- Timeout in seconds for HTTP requests (default: 10)
        timeout = 10,
        --- Override default registry URL (nil = use https://packagist.org)
        --- Example: "https://packagist.example.com"
        registry_base = nil,
        --- Custom endpoint template (%s will be replaced with vendor/package)
        --- Default: "/packages/%s.json"
        endpoint = nil,
    },
    --- File operation settings
    file_ops = {
        --- Root directory to start searching for composer.json (nil = use cwd)
        root_dir = nil,
    },
    --- Version comparison settings
    version = {
        --- Whether to include pre-release versions (alpha, beta, rc, dev)
        include_prerelease = false,
        --- Sort order: "desc" (newest first) or "asc" (oldest first)
        sort_order = "desc",
        --- Maximum versions to show in selector (default: 50)
        max_versions = 50,
    },
    --- Dependency sections configuration
    sections = {
        --- Order of sections
        order = { "require", "require-dev" },
        --- Default section for new packages
        default = "require",
    },
    --- Polling settings
    polling = {
        max_attempts = 30,
        interval_ms = 200,
        start_delay_ms = 500,
    },
}
