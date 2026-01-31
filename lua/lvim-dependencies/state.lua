local M = {
	is_in_project = false,
	project_root = nil,
	current_manifest = nil,
	js = {
		has_old_yarn = false,
		package_manager = nil,
	},
	-- initialize all known manifests so callers never hit nil
	dependencies = {
		package = { installed = {}, outdated = {}, invalid = {}, last_updated = nil },
		crates = { installed = {}, outdated = {}, invalid = {}, last_updated = nil },
		pubspec = { installed = {}, outdated = {}, invalid = {}, last_updated = nil },
		composer = { installed = {}, outdated = {}, invalid = {}, last_updated = nil },
		go = { installed = {}, outdated = {}, invalid = {}, last_updated = nil },
	},
	buffers = {},
	namespace = { id = nil },
	filename_to_key = {
		["package.json"] = "package",
		["Cargo.toml"] = "crates",
		["pubspec.yaml"] = "pubspec",
		["pubspec.yml"] = "pubspec",
		["composer.json"] = "composer",
		["go.mod"] = "go",
	},
}

-- namespace helpers (keep simple API and maintain .id for existing callers)
function M.namespace.create()
	M.namespace = M.namespace or {}
	if not M.namespace.id then
		M.namespace.id = vim.api.nvim_create_namespace("lvim_dependencies")
	end
	return M.namespace.id
end

function M.namespace.get_id()
	return (M.namespace and M.namespace.id) or nil
end

function M.get_manifest_key_from_filename(filename)
	return M.filename_to_key and M.filename_to_key[filename] or nil
end

-- buffer helpers
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

function M.update_buffer_lines(bufnr, lines)
	bufnr = bufnr or vim.fn.bufnr()
	if not M.buffers[bufnr] then
		return
	end
	M.buffers[bufnr].lines = lines
end

function M.get_buffer(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	return M.buffers[bufnr]
end

-- ensure manifest container exists
function M.ensure_manifest(manifest_key)
	if not manifest_key then
		return
	end
	M.dependencies[manifest_key] = M.dependencies[manifest_key]
		or { installed = {}, outdated = {}, invalid = {}, last_updated = nil }
end

-- set full tables (used by parsers)
function M.set_installed(manifest_key, tbl)
	M.ensure_manifest(manifest_key)
	M.dependencies[manifest_key].installed = tbl or {}
	M.dependencies[manifest_key].last_updated = os.time()
end

function M.set_outdated(manifest_key, tbl)
	M.ensure_manifest(manifest_key)
	M.dependencies[manifest_key].outdated = tbl or {}
end

function M.set_invalid(manifest_key, tbl)
	M.ensure_manifest(manifest_key)
	M.dependencies[manifest_key].invalid = tbl or {}
end

-- helpers to manage individual installed entries and scopes
-- installed[name] is expected to be either a string (version) or a table { current = "...", scopes = { ["dependencies"]=true, ["devDependencies"]=true, ... } }
function M.add_installed_dependency(manifest_key, name, current_version, scope)
	if not manifest_key or not name then
		return
	end
	M.ensure_manifest(manifest_key)

	local installed = M.dependencies[manifest_key].installed
	local entry = installed[name]

	if not entry then
		installed[name] = { current = current_version or nil, scopes = {} }
		entry = installed[name]
	else
		-- normalize entry to table form
		if type(entry) ~= "table" then
			entry = { current = entry, scopes = {} }
			installed[name] = entry
		end
		if current_version and (not entry.current or entry.current == "") then
			entry.current = current_version
		end
	end

	-- record scope if provided
	if scope and scope ~= "" then
		entry.scopes = entry.scopes or {}
		entry.scopes[scope] = true
	end

	M.dependencies[manifest_key].last_updated = os.time()
end

function M.remove_installed_dependency(manifest_key, name)
	if not manifest_key or not name then
		return
	end
	M.ensure_manifest(manifest_key)
	M.dependencies[manifest_key].installed[name] = nil
	M.dependencies[manifest_key].last_updated = os.time()
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
			-- return list of scopes
			local out = {}
			for s, _ in pairs(entry.scopes) do
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

-- last-run and skip helpers (used by autocommands)
function M.update_last_run(bufnr)
	bufnr = bufnr or vim.fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	M.buffers[bufnr].last_run = M.buffers[bufnr].last_run or {}
	M.buffers[bufnr].last_run.time = os.time()
end

function M.should_skip_last_run(bufnr, window_seconds)
	bufnr = bufnr or vim.fn.bufnr()
	local wnd = window_seconds or 3600
	if not M.buffers[bufnr] or not M.buffers[bufnr].last_run or not M.buffers[bufnr].last_run.time then
		return false
	end
	return os.time() < (M.buffers[bufnr].last_run.time or 0) + wnd
end

-- virtual text helpers
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

function M.set_virtual_text_displayed(bufnr, val)
	bufnr = bufnr or vim.fn.bufnr()
	M.buffers[bufnr] = M.buffers[bufnr] or {}
	M.buffers[bufnr].is_virtual_text_displayed = val
end

-- convenience: clear manifest state (installed/outdated/invalid)
function M.clear_manifest(manifest_key)
	if not manifest_key then
		return
	end
	M.dependencies[manifest_key] = { installed = {}, outdated = {}, invalid = {}, last_updated = nil }
end

return M
