local M = {
	performance = {
		-- package cache TTL in milliseconds
		cache_ttl_ms = 10 * 60 * 1000, -- 10 minutes

		-- concurrency control (used by check_manifests)
		base_concurrency = 6,
		max_concurrency = 12,

		-- deferred full-render latency (ms) for virtual_text
		deferred_full_render_ms = 30,

		-- whether to prioritize visible deps first
		prioritize_visible = true,
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
	ui = {
		highlight = {
			outdated = "#b65252",
			up_to_date = "#4a6494",
			invalid = "#a26666",
			constraint_newer = "#ff7e22",
			separator = "#3a784f",
		},
		virtual_text = {
			enabled = false,
			prefix = "| ",
			show_status_icon = true,
			icon_when_up_to_date = " ",
			icon_when_outdated = " ",
			icon_when_invalid = " ",
			icon_when_constraint_newer = " ",
			loading = "Loading...",
		},
	},
	virtual_text = {
		enabled = false,
		prefix = "| ",
		highlight = "",
		icon_when_up_to_date = " ",
		icon_when_outdated = " ",
		icon_when_invalid = " ",
		icon_when_constraint_newer = "s ",
		show_status_icon = true,
		loading = "Loading...",
	},
	keymaps = {
		update_package = "<leader>du",
		show_info = "<leader>di",
		open_docs = "<leader>dd",
	},
}

return M
