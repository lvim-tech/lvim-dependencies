# lvim-dependencies

A powerful Neovim plugin for managing project dependencies across multiple package managers.
View outdated packages, update to specific versions, and manage dependencies directly from your manifest files.

## Features

- **Multiple package managers**: Support for npm, Cargo, Go modules, Composer, and pub (Dart/Flutter)
- **Real-time version checking**: See outdated packages with virtual text annotations
- **Interactive package management**: Update to specific versions, install new packages, or delete existing ones via popup menu
- **Lock file awareness**: Reads actual installed versions from lock files
- **Async operations**: Non-blocking network requests and package manager commands
- **Smart caching**: Intelligent caching to minimize API calls

## Supported Package Managers

| Package Manager | Manifest File   | Lock File                                          | Registry         |
| --------------- | --------------- | -------------------------------------------------- | ---------------- |
| npm/yarn/pnpm   | `package.json`  | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml` | npmjs.org        |
| Cargo           | `Cargo.toml`    | `Cargo.lock`                                       | crates.io        |
| Go modules      | `go.mod`        | `go.sum`                                           | proxy.golang.org |
| Composer        | `composer.json` | `composer.lock`                                    | packagist.org    |
| pub             | `pubspec.yaml`  | `pubspec.lock`                                     | pub.dartlang.org |

## Requirements

- Neovim >= 0.10.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `curl` (for API requests)
- Package managers installed for your projects (npm, cargo, go, composer, flutter/dart)

## Installation

### lazy.nvim

```lua
{
    "lvim-tech/lvim-dependencies",
    dependencies = {
        "nvim-lua/plenary.nvim",
    },
    config = function()
        require("lvim-dependencies").setup({
            -- your configuration here
        })
    end,
}
```

### packer.nvim

```lua
use {
    "lvim-tech/lvim-dependencies",
    requires = {
        "nvim-lua/plenary.nvim",
    },
    config = function()
        require("lvim-dependencies").setup({})
    end,
}
```

## Configuration

Default configuration:

```lua
require("lvim-dependencies").setup({
    -- Network settings
    network = {
        pubspec_uri = "https://pub.dartlang.org/api",
        crates_uri = "https://crates.io/api/v1/crates",
        package_uri = "https://registry.npmjs.org",
        composer_uri = "https://repo.packagist.org/p2",
        go_uri = "https://proxy.golang.org",
        per_request_timeout_ms = 10000,
        overall_watchdog_ms = 30000,
        publish_debounce_ms = 120,
        request_max_retries = 2,
        request_retry_base_ms = 200,
        request_retry_jitter_ms = 100,
        negative_cache_ttl_ms = 5 * 60 * 1000,
        host_failure_blackout_ms = 5 * 60 * 1000,
        respect_env_proxy = true,
    },

    -- Performance settings
    performance = {
        cache_ttl_ms = 10 * 60 * 1000,
        base_concurrency = 6,
        max_concurrency = 12,
        deferred_full_render_ms = 30,
        dynamic_throttle = {
            enabled = true,
            failure_threshold = 5,
            window_ms = 60 * 1000,
            reduce_to = 2,
            throttle_backoff_ms = 30 * 1000,
        },
    },

    -- Enable/disable specific package managers
    package = { enabled = true },
    crates = { enabled = true },
    pubspec = { enabled = true },
    composer = { enabled = true },
    go = { enabled = true },

    -- UI settings
    ui = {
        highlight = {
            groups = {
                normal = "LvimDepsNormal",
                border = "LvimDepsBorder",
                title = "LvimDepsTitle",
                sub_title = "LvimDepsSubTitle",
                subject = "LvimDepsSubject",
                line_active = "LvimDepsLineActive",
                line_inactive = "LvimDepsLineInactive",
                navigation = "LvimDepsNavigation",
                input = "LvimDepsInsert",
                outdated = "LvimDepsOutdatedVersion",
                up_to_date = "LvimDepsUpToDateVersion",
                invalid = "LvimDepsInvalidVersion",
                not_installed = "LvimDepsNotInstalled",
                real = "LvimDepsReal",
                constraint = "LvimDepsConstraint",
                separator = "LvimDepsSeparator",
                loading = "LvimDepsLoading",
            },
            colors = {
                bg = "#1a1f21",
                fg = "#646c62",
                outdated = "#ce5f57",
                up_to_date = "#3a6479",
                invalid = "#c53b3b",
                not_installed = "#bb755e",
                real = "#f0c776",
                constraint = "#2d695d",
                separator = "#486b4c",
                loading = "#556352",
            },
        },
        virtual_text = {
            prefix = "| ",
            show_status_icon = true,
            icon_when_up_to_date = " ",
            icon_when_outdated = " ",
            loading = "Loading...",
            resolved_version = "mismatch",
        },
        floating = {
			      border = { " ", " ", " ", " ", " ", " ", " ", " " },
            width = "auto",
            height = "auto",
            max_height = 0.8,
			      current = "➤",
        },
    },

    -- Notification settings
    notify = {
        enabled = true,
        title = "LvimDeps",
        timeout = 5000,
    },
})
```

## Usage

### Automatic

Simply open a manifest file (`package.json`, `Cargo.toml`, `go.mod`, `composer.json`, or `pubspec.yaml`) and the plugin will automatically:

1. Parse the dependencies
2. Read installed versions from lock files
3. Fetch latest versions from registries
4. Display virtual text annotations showing version status

### Commands

| Command                    | Description                                       |
| -------------------------- | ------------------------------------------------- |
| `:LvimDependenciesUpdate`  | Open version selector for dependency under cursor |
| `:LvimDependenciesDelete`  | Remove dependency under cursor                    |
| `:LvimDependenciesRefresh` | Refresh all dependency information                |

## Virtual Text Annotations

The plugin displays version information as virtual text at the end of each dependency line:

```
"lodash": "^4.17.19" | [4.17.19] 4.17.21
"express": "^4.18.2" | 4.18.2
"axios": "^1.5.0" | Loading...
```

- `[4.17.19]` - Installed version in brackets indicates mismatch between constraint and actual installed version
- `4.17.21` - Latest available version (shown in outdated color when newer than installed)
- `4.18.2` - Package is up to date (installed version equals latest version)
- `Loading...` - Fetching version information from registry

## Workflow

### Install Package

1. Run `:LvimDependenciesInstall`
2. Type package name in the search field
3. Select a version from the popup menu
4. The plugin will:
    - Add the package to the manifest file
    - Run the appropriate package manager command to install
    - Refresh the version display

### Update Package

1. Place cursor on a dependency line
2. Run `:LvimDependenciesUpdate`
3. Select a version from the popup menu
4. The plugin will:
    - Update the manifest file
    - Run the appropriate package manager command
    - Refresh the version display

### Delete Package

1. Place cursor on a dependency line
2. Run `:LvimDependenciesDelete`
3. The plugin will:
    - Remove the package from the manifest file
    - Run the appropriate package manager command to uninstall
    - Refresh the version display

## Highlight Groups

| Group                     | Description                    |
| ------------------------- | ------------------------------ |
| `LvimDepsNormal`          | Normal text in floating window |
| `LvimDepsBorder`          | Floating window border         |
| `LvimDepsTitle`           | Floating window title          |
| `LvimDepsSubTitle`        | Floating window subtitle       |
| `LvimDepsSubject`         | Subject text                   |
| `LvimDepsLineActive`      | Active/selected line           |
| `LvimDepsLineInactive`    | Inactive lines                 |
| `LvimDepsNavigation`      | Navigation hints               |
| `LvimDepsInsert`          | Input field                    |
| `LvimDepsOutdatedVersion` | Outdated version text          |
| `LvimDepsUpToDateVersion` | Up-to-date version text        |
| `LvimDepsInvalidVersion`  | Invalid version text           |
| `LvimDepsNotInstalled`    | Not installed packages         |
| `LvimDepsReal`            | Real/installed version         |
| `LvimDepsConstraint`      | Version constraint             |
| `LvimDepsSeparator`       | Separator between versions     |
| `LvimDepsLoading`         | Loading indicator              |

## API

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for async utilities
- [crates.nvim](https://github.com/saecki/crates.nvim) for inspiration
- [package-info.nvim](https://github.com/vuki656/package-info.nvim) for inspiration
- [pubspec-assist.nvim](https://github.com/lvim-tech/pubspec-assist.nvim) for inspiration
