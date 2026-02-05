local M = {
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
    package = {
        enabled = true,
    },
    crates = {
        enabled = true,
    },
    pubspec = {
        enabled = true,
    },
    composer = {
        enabled = true,
    },
    go = {
        enabled = true,
    },
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
    notify = {
        enabled = true,
        title = "LvimDeps",
        timeout = 5000,
    },
}

return M
