-- Централизиран state модул, пригоден за multiple manifest types
-- Постави този файл като: lua/lvim-dependencies/state.lua

local M = {
	-- Проектна / глобална информация
	is_in_project = false,
	project_root = nil,
	current_manifest = nil, -- "package" | "crates" | "pubspec" (логична ключова стойност)

	-- JS-specific info (може да остане празно за другите)
	js = {
		has_old_yarn = false,
		package_manager = nil,
	},

	-- Dependencies per manifest key
	dependencies = {
		package = { installed = {}, outdated = {}, invalid = {} },
		crates = { installed = {}, outdated = {}, invalid = {} },
		pubspec = { installed = {}, outdated = {}, invalid = {} },
	},

	-- Буферна информация: map bufnr -> мета
	buffers = {},

	-- Namespace за виртуален текст (global)
	namespace = { id = nil },

	-- Map filename -> manifest key helper (използва се от autocommands/parsers)
	filename_to_key = {
		["package.json"] = "package",
		["Cargo.toml"] = "crates",
		["pubspec.yaml"] = "pubspec",
	},
}

-- Създава namespace (повиква се веднъж при инициализация)
function M.namespace.create()
	if not M.namespace.id then
		M.namespace.id = vim.api.nvim_create_namespace("lvim_dependencies")
	end
end

-- Връща manifest key за дадено filename (напр. "package.json" -> "package")
function M.get_manifest_key_from_filename(filename)
	return M.filename_to_key[filename]
end

-- Запазва/инициализира запис за буфер
-- bufnr: number | nil (по подразбиране текущ буфер)
-- manifest_key: "package"|"crates"|"pubspec"
-- path: optional буферен path
-- lines: optional lines table
function M.save_buffer(bufnr, manifest_key, path, lines)
	bufnr = bufnr or vim.fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	local b = M.buffers[bufnr]
	b.id = bufnr
	b.manifest = manifest_key
	b.path = path or vim.api.nvim_buf_get_name(bufnr)
	b.lines = lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	b.is_loaded = true
	b.is_virtual_text_displayed = false
	b.last_run = b.last_run or { time = nil }
end

-- Обновява lines за даден буфер (напр. след парсване)
function M.update_buffer_lines(bufnr, lines)
	bufnr = bufnr or vim.fn.bufnr()
	if not M.buffers[bufnr] then
		return
	end
	M.buffers[bufnr].lines = lines
end

-- Връща buffer meta за даден bufnr
function M.get_buffer(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	return M.buffers[bufnr]
end

-- Set/replace dependencies tables за manifest_key
function M.set_installed(manifest_key, tbl)
	M.dependencies[manifest_key] = M.dependencies[manifest_key] or { installed = {}, outdated = {}, invalid = {} }
	M.dependencies[manifest_key].installed = tbl or {}
end
function M.set_outdated(manifest_key, tbl)
	M.dependencies[manifest_key] = M.dependencies[manifest_key] or { installed = {}, outdated = {}, invalid = {} }
	M.dependencies[manifest_key].outdated = tbl or {}
end
function M.set_invalid(manifest_key, tbl)
	M.dependencies[manifest_key] = M.dependencies[manifest_key] or { installed = {}, outdated = {}, invalid = {} }
	M.dependencies[manifest_key].invalid = tbl or {}
end

-- Get dependencies object for manifest_key
function M.get_dependencies(manifest_key)
	return M.dependencies[manifest_key] or { installed = {}, outdated = {}, invalid = {} }
end

-- last_run helpers (per buffer)
function M.update_last_run(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	M.buffers[bufnr].last_run = M.buffers[bufnr].last_run or {}
	M.buffers[bufnr].last_run.time = os.time()
end

-- should_skip_last_run(bufnr, window_seconds)
function M.should_skip_last_run(bufnr, window_seconds)
	bufnr = bufnr or vim.fn.bufnr()
	local wnd = window_seconds or 3600
	if not M.buffers[bufnr] or not M.buffers[bufnr].last_run or not M.buffers[bufnr].last_run.time then
		return false
	end
	return os.time() < (M.buffers[bufnr].last_run.time or 0) + wnd
end

-- Clear virtual text for буфер (използвай namespace.id)
function M.clear_virtual_text(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	if not M.namespace.id then
		return
	end
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.namespace.id, 0, -1)
	if M.buffers[bufnr] then
		M.buffers[bufnr].is_virtual_text_displayed = false
	end
end

-- Set virtual_text displayed flag
function M.set_virtual_text_displayed(bufnr, val)
	bufnr = bufnr or vim.fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	M.buffers[bufnr].is_virtual_text_displayed = val
end

-- Utility: безопасно получаване на инсталирана зависимост (или nil)
function M.get_installed_version(manifest_key, name)
	local deps = M.get_dependencies(manifest_key)
	if deps and deps.installed and deps.installed[name] then
		return deps.installed[name].current or deps.installed[name]
	end
	return nil
end

-- Convenience: ensure structures exist
function M.ensure_manifest(manifest_key)
	if not M.dependencies[manifest_key] then
		M.dependencies[manifest_key] = { installed = {}, outdated = {}, invalid = {} }
	end
end

return M
