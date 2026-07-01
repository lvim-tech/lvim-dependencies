-- lvim-dependencies.config.go: Go-modules/proxy.golang.org manager settings — executable,
-- API endpoints, version selection, virtual-text override and outdated polling. Merged over
-- by the user's opts, then read live by the go manager.
---@module "lvim-dependencies.config.go"

---@class GoConfig
return {
    --- Executable paths for go commands
    executables = {
        --- Path to go executable (nil = search in PATH)
        go = nil,
    },
    --- API settings for proxy.golang.org
    api = {
        --- Timeout in seconds for HTTP requests (default: 10)
        timeout = 10,
        --- Override default proxy URL (nil = use manifest default)
        --- Example: "https://goproxy.io"
        proxy_base = nil,
    },
    --- File operation settings
    file_ops = {
        --- Root directory to start searching for go.mod (nil = use current working directory)
        root_dir = nil,
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
    --- Virtual text customization (optional override of global settings)
    virtual_text = {
        --- Position override for go.mod files (nil = use global config.ui.virtual_text.position)
        position = nil,
        --- Priority override for go.mod files (nil = use manifest default 1000)
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
