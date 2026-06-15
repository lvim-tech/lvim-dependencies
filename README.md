# lvim-dependencies

A powerful Neovim plugin for managing project dependencies across multiple package managers.
View outdated packages, update to specific versions, and manage dependencies directly from your manifest files — with virtual text annotations, interactive popups, LSP hover/actions, and full async support.

<img width="2011" height="1374" alt="screenshot_2026-02-04_23-40-40" src="https://github.com/user-attachments/assets/39e84f11-ce75-4b11-ae82-00dda23aeffa" />

---

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-dependencies/blob/main/LICENSE)

## Features

- **5 package managers**: npm/yarn/pnpm, Cargo, Go modules, Composer, pub (Dart/Flutter)
- **3-component virtual text**: Declared → Installed | Latest, each with its own highlight
- **Interactive version picker**: Select any available version from a floating popup
- **LSP integration**: Hover documentation and code actions via any LSP client
- **Install / Update / Delete**: Full lifecycle management via `:LvimDeps` commands or LSP code actions
- **Async & non-blocking**: All network requests and package manager commands run in the background
- **Smart multi-layer cache**: Declared, Installed, Latest, and Virtual Text caches with configurable TTL
- **Dynamic throttle**: Automatically reduces concurrency after repeated registry failures
- **Retry logic with jitter**: Configurable retries for flaky registries
- **Negative cache**: Skips re-fetching known-missing packages within a configurable window
- **Working indicator**: Shows a spinner on the dependency line while an operation is in progress
- **Cargo feature management**: Interactive UI for managing Cargo crate features

---

## Supported Package Managers

| Manager       | Manifest file   | Lock / sum file                                    | Registry              |
| ------------- | --------------- | -------------------------------------------------- | --------------------- |
| npm/yarn/pnpm | `package.json`  | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml` | registry.npmjs.org    |
| Cargo         | `Cargo.toml`    | `Cargo.lock`                                       | crates.io             |
| Go modules    | `go.mod`        | `go.sum`                                           | proxy.golang.org      |
| Composer      | `composer.json` | `composer.lock`                                    | repo.packagist.org    |
| pub           | `pubspec.yaml`  | `pubspec.lock`                                     | pub.dartlang.org      |

---

## Requirements

- Neovim >= 0.10.0
- `curl` (for HTTP requests to package registries)
- The package managers you actually use (`npm`, `cargo`, `go`, `composer`, `flutter`/`dart`)

---

## Installation

### lazy.nvim

```lua
{
    "lvim-tech/lvim-dependencies",
    config = function()
        require("lvim-dependencies").setup({
            -- see Configuration section below
        })
    end,
}
```

### packer.nvim

```lua
use {
    "lvim-tech/lvim-dependencies",
    config = function()
        require("lvim-dependencies").setup({})
    end,
}
```

---

## Quick Start

1. Open any manifest file (`package.json`, `Cargo.toml`, `go.mod`, `composer.json`, `pubspec.yaml`)
2. Virtual text appears automatically next to each dependency showing its full version status
3. Place the cursor on a dependency and run `:LvimDeps update` to open the version picker
4. Run `:LvimDeps install` to add a new package
5. Run `:LvimDeps delete` to remove the package under the cursor

---

## Virtual Text

The plugin renders three version components at the end of every dependency line:

```
"lodash": "^4.17.19"    ➤➤➤ ^4.17.19 → 4.17.19 |  4.17.21
"express": "^4.18.2"    ➤➤➤ ^4.18.2 → 4.18.2 |  4.18.2
"axios": "^1.5.0"       ➤➤➤ Loading...
"chalk": "^5.0.0"       ➤➤➤ Working...
```

| Component     | Description                                                | Highlight group              |
| ------------- | ---------------------------------------------------------- | ---------------------------- |
| **Declared**  | Version constraint as written in the manifest (`^1.0.0`)   | `LvimDepsDeclaredVersion`    |
| `→`           | Transition separator                                       | `LvimDepsSeparator`          |
| **Installed** | Actual version present on disk / in lock file              | `LvimDepsInstalledVersion`   |
| `\|`          | Divider separator                                          | `LvimDepsSeparator`          |
| **Latest**    | Latest version from the registry                           | `LvimDepsUpToDateVersion` or `LvimDepsOutdatedVersion` |
| `Loading...`  | Fetching data from the registry                            | `LvimDepsLoading`            |
| `Working...`  | An install/update/delete operation is in progress          | `LvimDepsWorking`            |

The Latest version icon changes based on status:
- ` 4.18.2` — package is up to date (installed == latest)
- ` 4.17.21` — update available (installed < latest)

For non-registry dependency types (git, path, workspace), the Latest component is omitted and replaced with type-specific information.

---

## Commands

All commands go through `:LvimDeps <subcommand>`. Tab-completion is available for all subcommands.

### Package operations

These require an open manifest file in the current buffer.

| Subcommand                         | Description                                                         |
| ---------------------------------- | ------------------------------------------------------------------- |
| `install`                          | Search for and install a new package                                |
| `update [package]`                 | Open version picker for the package under cursor (or named package) |
| `update-direct <package> <version>`| Update directly to a specific version without the picker            |
| `delete [package]`                 | Remove the package under cursor with a confirmation dialog          |

### Virtual text

| Subcommand | Description                             |
| ---------- | --------------------------------------- |
| `show`     | Show virtual text in the current buffer |
| `hide`     | Hide virtual text                       |
| `toggle`   | Toggle virtual text on/off              |

### Cache management

| Subcommand          | Description                                        |
| ------------------- | -------------------------------------------------- |
| `cache [type]`      | Inspect cache (`all`, `declared`, `installed`, `latest`, `manifest`, `virtual-text`) |
| `clear-declared`    | Clear the declared-versions cache                  |
| `clear-installed`   | Clear the installed-versions cache                 |
| `clear-latest`      | Clear the latest-versions cache                    |
| `clear-all-caches`  | Clear all caches for the current manager           |

### Diagnostics

| Subcommand              | Description                                         |
| ----------------------- | --------------------------------------------------- |
| `help [subcommand]`     | Show help (or detailed help for a specific command) |
| `show-registry`         | List all registered managers and their file patterns|
| `show-manager [name]`   | Detailed info for one manager                       |
| `state`                 | Show internal buffer state                          |
| `metrics`               | Show performance and network metrics                |

**Suggested keybindings:**

```lua
vim.keymap.set("n", "<leader>du", "<cmd>LvimDeps update<cr>",  { desc = "Update dependency" })
vim.keymap.set("n", "<leader>di", "<cmd>LvimDeps install<cr>", { desc = "Install dependency" })
vim.keymap.set("n", "<leader>dd", "<cmd>LvimDeps delete<cr>",  { desc = "Delete dependency" })
vim.keymap.set("n", "<leader>dr", "<cmd>LvimDeps toggle<cr>",  { desc = "Toggle dependency virtual text" })
```

---

## LSP Integration

The plugin registers hover providers and code action providers for each manager. No additional LSP server setup is required — it hooks directly into Neovim's built-in LSP infrastructure.

### Hover (`K` by default)

Hovering over a dependency line opens a floating Markdown window showing:

- Package name and dependency type (`registry`, `git`, `path`, `workspace`)
- Declared version constraint
- Installed version
- Latest available version (with outdated/up-to-date indicator)
- Metadata: description, repository URL, documentation URL, homepage, license, keywords

### Code Actions (`<leader>ca` or equivalent)

| Action                      | Description                                          |
| --------------------------- | ---------------------------------------------------- |
| `Update <package>`          | Open version picker and update to selected version   |
| `Delete <package>`          | Remove package with confirmation dialog              |
| `Open repository`           | Open the package repository URL in the browser       |
| `Open documentation`        | Open the package documentation URL in the browser    |
| `Open homepage`             | Open the package homepage URL in the browser         |
| `Manage features` *(Cargo)* | Open the interactive Cargo features management UI    |

---

## Configuration

Pass any subset of the options below to `setup()` — only the keys you provide are overridden.

```lua
require("lvim-dependencies").setup({

    -- -----------------------------------------------------------------------
    -- Notifications
    -- -----------------------------------------------------------------------
    notify = {
        enabled   = true,
        min_level = vim.log.levels.INFO,
        title     = "Lvim Dependencies",
        timeout   = 10000,
    },

    -- -----------------------------------------------------------------------
    -- Debug logging (written to a state file)
    -- -----------------------------------------------------------------------
    debug = {
        enabled   = true,
        min_level = vim.log.levels.DEBUG,
        -- file = <state dir>/debug.log
    },

    -- -----------------------------------------------------------------------
    -- Highlight colors
    -- Used to derive all LvimDeps* highlight groups (see Highlight Groups).
    -- -----------------------------------------------------------------------
    highlight = {
        colors = {
            bg            = "#1a1f21",
            fg            = "#646c62",
            separator     = "#486b4c",
            declared      = "#bb755e",
            installed     = "#f0c776",
            loading       = "#6e8068",
            working       = "#6e8068",
            error         = "#ce5f57",   -- also used for outdated versions
            success       = "#3a6479",   -- also used for up-to-date versions
            title         = "#7954c6",
            sub_title     = "#7954c6",
            subject       = "#f0c776",
            info          = "#545ec6",
            navigation    = "#6e8068",
            line_active   = "#4b809b",
            line_inactive = "#43728a",
            input         = "#43728a",
        },
    },

    -- -----------------------------------------------------------------------
    -- UI
    -- -----------------------------------------------------------------------
    ui = {
        virtual_text = {
            -- Position relative to the line. nil defaults to "eol".
            -- Valid values: "eol" | "overlay" | "right_align" | "inline"
            position = nil,
            status = {
                enabled = { default = true },
            },
            icons = {
                separators = {
                    prefix     = "➤➤➤",  -- shown before the entire VT block
                    transition = "→",     -- between declared and installed
                    divider    = "|",     -- between installed and latest
                },
                up_to_date = "",        -- prefix icon on latest when up to date
                outdated   = "",        -- prefix icon on latest when update available
                loading    = "Loading...",
                working    = "Working... ",
                error      = "?",
            },
        },
        popup = {
            border     = { " ", " ", " ", " ", " ", " ", " ", " " },
            width      = "auto",
            height     = "auto",
            max_height = 0.8,
            current    = "➤",   -- marker for the currently installed version
            max_items  = 20,
        },
        float = {
            border     = { " ", " ", " ", " ", " ", " ", " ", " " },
            width      = "auto",
            height     = "auto",
            max_height = 0.8,
        },
    },

    -- -----------------------------------------------------------------------
    -- LSP integration
    -- -----------------------------------------------------------------------
    lsp = {
        enabled = true,
        -- Called when the plugin attaches its LSP client to a buffer.
        -- Default binds K → hover, ga → code_action.
        on_attach = function(_, bufnr)
            vim.keymap.set("n", "K", function()
                vim.lsp.buf.hover()
            end, { buffer = bufnr, desc = "Lvim Dependencies: Show hover" })
            vim.keymap.set("n", "ga", function()
                vim.lsp.buf.code_action()
            end, { buffer = bufnr, desc = "Lvim Dependencies: Code actions" })
        end,
        actions = true,   -- enable code actions
        hover   = true,   -- enable hover
    },

    -- -----------------------------------------------------------------------
    -- Cache
    -- -----------------------------------------------------------------------
    cache = {
        ttl = {
            installed = 300,    -- seconds — installed package info
            latest    = 1800,   -- seconds — latest version from registry
            manifest  = 3600,   -- seconds — parsed manifest data
            declared  = nil,    -- nil = no expiry
        },
        cleanup = {
            interval    = 3600000,  -- ms — how often cleanup runs
            threshold   = 0.8,      -- trigger when 80% of max_entries is reached
            max_entries = 1000,     -- per-manager entry limit before cleanup
        },
        stats = {
            collect        = true,
            warn_threshold = 500,
        },
        managers_cache_ttl      = 5000,  -- ms
        manifest_type_cache_ttl = 5000,  -- ms
    },

    -- -----------------------------------------------------------------------
    -- Async
    -- -----------------------------------------------------------------------
    async = {
        defaults = {
            concurrency     = 10,
            timeout         = 5000,
            retry_count     = 3,
            retry_delay     = 1000,
            max_retry_delay = 5000,
        },
        package_loader = {
            concurrency = 10,
            retry_count = 3,
            retry_delay = 1000,
        },
        operator = {
            retry_count = 2,
            retry_delay = 2000,
        },
        file_operations = {
            read_timeout = 3000,
        },
        debounce = {
            save = 200,
            move = 50,
        },
        throttle = {
            default_limit = 100,
        },
    },

    -- -----------------------------------------------------------------------
    -- npm / yarn / pnpm  (key: npm)
    -- -----------------------------------------------------------------------
    npm = {
        executables = {
            npm  = nil,   -- nil = auto-detect from PATH
            yarn = nil,
            pnpm = nil,
        },
        -- nil = auto-detect from lock file (pnpm-lock.yaml → pnpm, yarn.lock → yarn, else npm)
        preferred_manager = nil,
        api = {
            timeout       = 10,   -- seconds
            registry_base = nil,  -- nil = "https://registry.npmjs.org"
            endpoint      = nil,  -- nil = "/%s/latest"
        },
        file_ops = {
            root_dir = nil,
        },
        version = {
            include_prerelease = false,
            sort_order         = "desc",
            max_versions       = 50,
        },
        sections = {
            order   = { "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" },
            default = "dependencies",
        },
        virtual_text = {
            position = nil,   -- overrides global ui.virtual_text.position for package.json
            priority = nil,
        },
        polling = {
            max_attempts   = 30,
            interval_ms    = 200,
            start_delay_ms = 500,
        },
    },

    -- -----------------------------------------------------------------------
    -- Cargo  (key: cargo)
    -- -----------------------------------------------------------------------
    cargo = {
        executables = {
            cargo = nil,
            rustc = nil,
        },
        api = {
            timeout       = 10,
            registry_base = nil,  -- nil = "https://crates.io/api/v1"
            endpoint      = nil,
        },
        file_ops = {
            root_dir = nil,
        },
        version = {
            include_prerelease = false,
            sort_order         = "desc",
            max_versions       = 50,
        },
        display = {
            show_features         = true,   -- show enabled features in VT
            filter_default        = true,   -- hide the implicit "default" feature
            show_optional         = false,  -- show "[opt]" for optional deps
            show_default_features = false,  -- show "[no-default]" when default-features = false
            max_features_display  = 3,      -- truncate after this many features
            truncation_indicator  = "...",
        },
        virtual_text = {
            position = nil,
            priority = nil,
        },
        polling = {
            max_attempts   = 30,
            interval_ms    = 200,
            start_delay_ms = 500,
        },
    },

    -- -----------------------------------------------------------------------
    -- Go modules  (key: go)
    -- -----------------------------------------------------------------------
    go = {
        executables = {
            go = nil,
        },
        api = {
            timeout    = 10,
            proxy_base = nil,  -- nil = "https://proxy.golang.org"
        },
        file_ops = {
            root_dir = nil,
        },
        version = {
            include_prerelease = false,
            sort_order         = "desc",
            max_versions       = 50,
        },
        virtual_text = {
            position = nil,
            priority = nil,
        },
        polling = {
            max_attempts   = 30,
            interval_ms    = 200,
            start_delay_ms = 500,
        },
    },

    -- -----------------------------------------------------------------------
    -- Composer  (key: composer)
    -- -----------------------------------------------------------------------
    composer = {
        executables = {
            composer = nil,
        },
        api = {
            timeout       = 10,
            registry_base = nil,  -- nil = "https://repo.packagist.org/p2"
            endpoint      = nil,
        },
        file_ops = {
            root_dir = nil,
        },
        version = {
            include_prerelease = false,
            sort_order         = "desc",
            max_versions       = 50,
        },
        sections = {
            order   = { "require", "require-dev" },
            default = "require",
        },
        polling = {
            max_attempts   = 30,
            interval_ms    = 200,
            start_delay_ms = 500,
        },
    },

    -- -----------------------------------------------------------------------
    -- pub / Dart / Flutter  (key: pubspec)
    -- -----------------------------------------------------------------------
    pubspec = {
        executables = {
            flutter = nil,
            dart    = nil,
        },
        api = {
            timeout       = 10,
            registry_base = nil,  -- nil = "https://pub.dartlang.org/api"
            endpoint      = nil,
        },
        file_ops = {
            root_dir      = nil,
            file_patterns = nil,
        },
        version = {
            include_prerelease = true,   -- pub.dev includes stable+prerelease by default
            sort_order         = "desc",
            max_versions       = 50,
        },
        sections = {
            order   = { "dependencies", "dev_dependencies", "dependency_overrides" },
            default = "dependencies",
        },
        sdk_packages = {},   -- additional SDK package names to skip registry lookup
        virtual_text = {
            position = nil,
            priority = nil,
        },
        polling = {
            max_attempts   = 30,
            interval_ms    = 200,
            start_delay_ms = 500,
        },
    },
})
```

> **Go modules note:** `go.mod` is the source of truth for installed versions.
> `go.sum` is a checksum accumulator — the same package can appear dozens of times
> at different versions and is **not** used for version lookups.

> **Cargo:** also supports an interactive **features management UI** via the
> `Manage features` LSP code action on any `Cargo.toml` dependency.

---

## Highlight Groups

Override any group in your colorscheme to change the appearance.

### Virtual text

| Group                       | Used for                                              |
| --------------------------- | ----------------------------------------------------- |
| `LvimDepsDeclaredVersion`   | Version constraint from the manifest (`^1.0.0`)       |
| `LvimDepsInstalledVersion`  | Actual installed version                              |
| `LvimDepsUpToDateVersion`   | Latest version when package is up to date             |
| `LvimDepsOutdatedVersion`   | Latest version when an update is available            |
| `LvimDepsSeparator`         | `→`, `|`, and prefix separators                       |
| `LvimDepsLoading`           | `Loading...` text while fetching                      |
| `LvimDepsWorking`           | `Working...` text during install/update/delete        |

### Floating windows (popup, hover, float)

| Group                   | Used for                                |
| ----------------------- | --------------------------------------- |
| `LvimDepsNormal`        | Normal text                             |
| `LvimDepsBorder`        | Window border                           |
| `LvimDepsTitle`         | Window title                            |
| `LvimDepsSubTitle`      | Window subtitle                         |
| `LvimDepsSubject`       | Subject / label text                    |
| `LvimDepsInfo`          | Informational text                      |
| `LvimDepsCursorLine`    | Current line highlight                  |
| `LvimDepsLineActive`    | Selected line in picker                 |
| `LvimDepsLineInactive`  | Unselected lines in picker              |
| `LvimDepsNavigation`    | Navigation hints (`j/k`, `Enter`, etc.) |
| `LvimDepsInsert`        | Input / search field                    |

**Example overrides:**

```lua
vim.api.nvim_set_hl(0, "LvimDepsOutdatedVersion",  { fg = "#ff6b6b", bold = true })
vim.api.nvim_set_hl(0, "LvimDepsUpToDateVersion",  { fg = "#6bcb77" })
vim.api.nvim_set_hl(0, "LvimDepsDeclaredVersion",  { fg = "#e0a070" })
vim.api.nvim_set_hl(0, "LvimDepsInstalledVersion", { fg = "#f0d080" })
```

---

## Architecture Overview

```
lvim-dependencies/
├── core/
│   ├── registry.lua         — discovers and registers managers at startup (auto-glob)
│   ├── operator.lua         — dispatches install/update/delete operations
│   ├── operation.lua        — builds operation descriptors
│   ├── virtual_text.lua     — orchestrates VT rendering across all buffers
│   ├── cache.lua            — multi-layer cache (declared / installed / latest / VT)
│   ├── hub/
│   │   ├── declared.lua     — declared packages aggregator
│   │   ├── installed.lua    — installed versions aggregator
│   │   └── latest.lua       — latest versions aggregator
│   └── state.lua            — per-buffer lifecycle state machine
├── managers/
│   ├── npm/                 — package.json → registry.npmjs.org
│   ├── cargo/               — Cargo.toml → crates.io (+ features UI + LSP)
│   ├── go/                  — go.mod → proxy.golang.org
│   ├── composer/            — composer.json → packagist.org
│   └── pubspec/             — pubspec.yaml → pub.dartlang.org
│
│   Each manager contains:
│   ├── manifest.lua         — key, file_patterns, dependency_types, VT format helpers
│   ├── parser.lua           — parses the manifest file; content-hash caching
│   ├── compare_versions.lua — semver comparison and sorting
│   ├── data/
│   │   ├── declared.lua     — reads declared packages from parser
│   │   ├── installed.lua    — reads installed versions (lock file or manifest)
│   │   └── latest.lua       — fetches latest versions from registry (async, in-flight dedup)
│   ├── api/init.lua         — get_package_at_cursor, fetch_versions_async, update_async, delete
│   ├── handler.lua          — operation dispatcher (INSTALL / UPDATE / DELETE / CHECK_OUTDATED)
│   ├── virtual_text.lua     — find_package_in_line, format_package_chunks, get_loading_parts
│   ├── core/*_ops.lua       — full operation lifecycle:
│   │                          display_working → run CLI → seed_installed → refresh VT → checktime
│   └── register.lua         — entry point called by registry; loads handler + optional LSP extensions
├── lsp/                     — shared LSP hover + code actions infrastructure
├── ui/
│   ├── popup.lua            — interactive floating version picker
│   └── float.lua            — read-only floating window (help, registry info, hover)
└── hooks/
    ├── commands.lua         — :LvimDeps user command with tab completion
    └── autocommands.lua     — BufRead, BufWrite, BufEnter, TextChanged handlers
```

---

## License

BSD 3-Clause — see [LICENSE](LICENSE).

## Acknowledgments

- [crates.nvim](https://github.com/saecki/crates.nvim) — inspiration
- [package-info.nvim](https://github.com/vuki656/package-info.nvim) — inspiration
- [pubspec-assist.nvim](https://github.com/lvim-tech/pubspec-assist.nvim) — inspiration
