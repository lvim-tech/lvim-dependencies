local api = vim.api
local fn = vim.fn
local os_time = os.time

local const = require("lvim-dependencies.const")

local M = {
	is_in_project = false,
	project_root = nil,
	current_manifest = nil,
	js = {
		has_old_yarn = false,
		package_manager = nil,
	},
	dependencies = {},
	buffers = {},
	namespace = { id = nil },
	is_updating = false, -- Flag to prevent parsing during package updates
}

-- Initialize dependencies structure from const
local function init_dependencies()
	for _, manifest_key in pairs(const.MANIFEST_KEYS) do
		if not M.dependencies[manifest_key] then
			M.dependencies[manifest_key] = {
				installed = {},
				outdated = {},
				invalid = {},
				last_updated = nil,
			}
		end
	end
end

-- Initialize on load
init_dependencies()

-- Helper: ensure a manifest container exists and returns it
local function ensure_manifest_table(manifest_key)
	if not manifest_key then
		return nil
	end
	local deps = M.dependencies[manifest_key]
	if not deps then
		deps = { installed = {}, outdated = {}, invalid = {}, last_updated = nil }
		M.dependencies[manifest_key] = deps
	end
	return deps
end

-- namespace helpers
function M.namespace.create()
	M.namespace = M.namespace or {}
	if not M.namespace.id then
		M.namespace.id = api.nvim_create_namespace("lvim_dependencies")
	end
	return M.namespace.id
end

function M.namespace.get_id()
	return (M.namespace and M.namespace.id) or nil
end

function M.get_manifest_key_from_filename(filename)
	return const.MANIFEST_KEYS[filename]
end

-- Update flag helpers
function M.set_updating(value)
	M.is_updating = value
end

function M.get_updating()
	return M.is_updating
end

-- buffer helpers (safe, no-throw)
function M.save_buffer(bufnr, manifest_key, path, lines)
	bufnr = bufnr or fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	local b = M.buffers[bufnr]
	b.id = bufnr
	b.manifest = manifest_key
	b.path = path or api.nvim_buf_get_name(bufnr)
	b.lines = lines or api.nvim_buf_get_lines(bufnr, 0, -1, false)
	b.is_loaded = true
	b.is_virtual_text_displayed = false
	b.last_run = b.last_run or { time = nil }
end

function M.update_buffer_lines(bufnr, lines)
	bufnr = bufnr or fn.bufnr()
	if not M.buffers[bufnr] then
		return
	end
	M.buffers[bufnr].lines = lines
end

function M.get_buffer(bufnr)
	bufnr = bufnr or fn.bufnr()
	return M.buffers[bufnr]
end

function M.ensure_manifest(manifest_key)
	if not manifest_key then
		return
	end
	ensure_manifest_table(manifest_key)
end

function M.set_installed(manifest_key, tbl)
	if not manifest_key then
		return
	end
	local deps = ensure_manifest_table(manifest_key)
	deps.installed = tbl or {}
	deps.last_updated = os_time()
end

function M.set_outdated(manifest_key, tbl)
	if not manifest_key then
		return
	end
	local deps = ensure_manifest_table(manifest_key)
	deps.outdated = tbl or {}
end

function M.set_invalid(manifest_key, tbl)
	if not manifest_key then
		return
	end
	local deps = ensure_manifest_table(manifest_key)
	deps.invalid = tbl or {}
end

function M.set_dependencies(manifest_key, tbl)
	if not manifest_key or not tbl then
		return
	end
	if type(tbl) == "table" and (tbl.installed or tbl.lines) then
		M.set_installed(manifest_key, tbl.installed or {})
		M.set_outdated(manifest_key, tbl.outdated or {})
		M.set_invalid(manifest_key, tbl.invalid or {})
		if tbl.lines then
			M.update_buffer_lines(fn.bufnr(), tbl.lines)
		end
	else
		M.set_installed(manifest_key, tbl)
	end
end

function M.add_installed_dependency(manifest_key, name, current_version, scope)
	if not manifest_key or not name then
		return
	end

	local deps = ensure_manifest_table(manifest_key)
	if not deps then
		return
	end

	deps.installed = deps.installed or {}
	local installed = deps.installed

	local entry = installed[name]

	if not entry then
		entry = { current = current_version or nil, scopes = {} }
		installed[name] = entry
	else
		if type(entry) ~= "table" then
			entry = { current = entry, scopes = {} }
			installed[name] = entry
		end
		if current_version and (not entry.current or entry.current == "") then
			entry.current = current_version
		end
	end

	if scope and scope ~= "" then
		entry.scopes = entry.scopes or {}
		entry.scopes[scope] = true
	end

	deps.last_updated = os_time()
end

function M.remove_installed_dependency(manifest_key, name)
	if not manifest_key or not name then
		return
	end
	M.ensure_manifest(manifest_key)
	local deps = M.dependencies[manifest_key]
	if not deps then
		return
	end
	local installed = deps.installed
	if not installed then
		return
	end

	installed[name] = nil
	deps.last_updated = os_time()
end

function M.get_installed_version(manifest_key, name)
	local deps = M.get_dependencies(manifest_key)
	if deps and deps.installed and deps.installed[name] then
		local entry = deps.installed[name]
		if type(entry) == "table" and entry.current then
			return entry.current
		end
		if type(entry) == "string" then
			return entry
		end
	end
	return nil
end

function M.get_installed_scopes(manifest_key, name)
	local deps = M.get_dependencies(manifest_key)
	if deps and deps.installed and deps.installed[name] then
		local entry = deps.installed[name]
		if type(entry) == "table" and entry.scopes then
			local out = {}
			for s in pairs(entry.scopes) do
				out[#out + 1] = s
			end
			return out
		end
	end
	return {}
end

function M.has_scope(manifest_key, name, scope)
	local deps = M.get_dependencies(manifest_key)
	if not (deps and deps.installed and deps.installed[name]) then
		return false
	end
	local entry = deps.installed[name]
	if type(entry) == "table" and entry.scopes and entry.scopes[scope] then
		return true
	end
	return false
end

function M.get_dependencies(manifest_key)
	return M.dependencies[manifest_key] or { installed = {}, outdated = {}, invalid = {}, last_updated = nil }
end

function M.update_last_run(bufnr)
	bufnr = bufnr or fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	M.buffers[bufnr].last_run = M.buffers[bufnr].last_run or {}
	M.buffers[bufnr].last_run.time = os_time()
end

function M.should_skip_last_run(bufnr, window_seconds)
	bufnr = bufnr or fn.bufnr()
	local wnd = window_seconds or 3600
	if not M.buffers[bufnr] or not M.buffers[bufnr].last_run or not M.buffers[bufnr].last_run.time then
		return false
	end
	return os_time() < (M.buffers[bufnr].last_run.time or 0) + wnd
end

function M.clear_virtual_text(bufnr)
	bufnr = bufnr or fn.bufnr()
	if not M.namespace.id then
		return
	end
	pcall(api.nvim_buf_clear_namespace, bufnr, M.namespace.id, 0, -1)
	if M.buffers[bufnr] then
		M.buffers[bufnr].is_virtual_text_displayed = false
	end
end

function M.set_virtual_text_displayed(bufnr, val)
	bufnr = bufnr or fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	M.buffers[bufnr].is_virtual_text_displayed = val
end

function M.clear_manifest(manifest_key)
	if not manifest_key then
		return
	end
	M.dependencies[manifest_key] = { installed = {}, outdated = {}, invalid = {}, last_updated = nil }
end

return M
