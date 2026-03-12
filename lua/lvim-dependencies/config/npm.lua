-- lvim-dependencies/config/npm.lua
--- npm/yarn/pnpm manager specific configuration
---@class NpmConfig
return {
    --- Executable paths for package manager commands
    --- Set explicitly if executables are not in PATH
    executables = {
        --- Path to npm executable (nil = search in PATH)
        npm = nil,
        --- Path to yarn executable (nil = search in PATH)
        yarn = nil,
        --- Path to pnpm executable (nil = search in PATH)
        pnpm = nil,
    },
    --- Package manager preference
    --- When nil, auto-detected from lock file presence in this order:
    ---   pnpm-lock.yaml → pnpm, yarn.lock → yarn, otherwise → npm
    --- Set explicitly to force a specific package manager:
    --- Example: "pnpm"
    preferred_manager = nil,
    --- API settings for npm registry
    api = {
        --- Timeout in seconds for HTTP requests (default: 10)
        timeout = 10,
        --- Override default registry URL (nil = use https://registry.npmjs.org)
        --- Example: "https://registry.company.com"
        --- Example: "https://verdaccio.myhost.com"
        registry_base = nil,
        --- Custom endpoint template (%s will be replaced with package name)
        --- Default: "/%s/latest"
        --- Example: "/%s" (fetches full metadata instead of just latest)
        endpoint = nil,
    },
    --- File operation settings
    file_ops = {
        --- Root directory to start searching for package.json (nil = use current working directory)
        --- Example: "~/projects/myapp"
        root_dir = nil,
    },
    --- Version comparison settings
    version = {
        --- Whether to include pre-release versions (alpha, beta, rc, next, canary)
        include_prerelease = false,
        --- Sort order: "desc" (newest first) or "asc" (oldest first)
        sort_order = "desc",
        --- Maximum versions to show in selector (default: 50)
        max_versions = 50,
    },
    --- Dependency sections configuration
    sections = {
        --- Order of sections when resolving which section a package belongs to
        order = {
            "dependencies",
            "devDependencies",
            "peerDependencies",
            "optionalDependencies",
        },
        --- Default section for new packages
        default = "dependencies",
    },
    --- Virtual text customization (optional override of global settings)
    virtual_text = {
        --- Position override for package.json files (nil = use global config.ui.virtual_text.position)
        position = nil,
        --- Priority override for package.json files (nil = use manifest default 1000)
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
