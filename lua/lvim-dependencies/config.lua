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
				outdated = "LvimDepsOutdatedVersion",
				up_to_date = "LvimDepsUpToDateVersion",
				invalid = "LvimDepsInvalidVersion",
				constraint_newer = "LvimDepsConstraintNewer",
				separator = "LvimDepsSeparator",
				loading = "LvimDepsLoading",
			},
			colors = {
				bg = "#000000",
				fg = "#cccccc",
				outdated = "#b65252",
				up_to_date = "#4a6494",
				invalid = "#a26666",
				constraint_newer = "#ff7e22",
				separator = "#3a784f",
				loading = "#3a4178",
			},
		},
		virtual_text = {
			prefix = "| ",
			show_status_icon = true,
			icon_when_up_to_date = " ",
			icon_when_outdated = " ",
			icon_when_invalid = " ",
			icon_when_constraint_newer = " ",
			loading = "Loading...",
		},
		floating = {
			-- border = { "a", "b", "c", "d", "e", "f", "g", "h" },
			border = "double",
			width = "auto",
			height = "auto",
			max_height = 0.8,
		},
	},
	keymaps = {
		update_package = "<leader>du",
		show_info = "<leader>di",
		open_docs = "<leader>dd",
	},
	notify = true,
}

return M
