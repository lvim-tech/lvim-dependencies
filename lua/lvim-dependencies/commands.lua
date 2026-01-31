local api = vim.api
local fn = vim.fn
local utils = require("lvim-dependencies.utils")
local floating = require("lvim-dependencies.ui.floating")
local validator = require("lvim-dependencies.validator")

local M = {}

local function detect_manifest_from_buf(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	local path = api.nvim_buf_get_name(bufnr) or ""
	local base = fn.fnamemodify(path, ":t")
	return validator.detect_manifest_from_filename(base)
end

local function leading_spaces(s)
	local m = s:match("^(%s*)")
	return #m
end

local function detect_dep_from_line(manifest_key, bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	local cursor = api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local lines = api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {}
	local line = (lines[1] or "")
	local trimmed = line:gsub("^%s+", "")

	if manifest_key == "pubspec" then
		local name = trimmed:match("^([%w_%-]+)%s*:")
		if not name then
			name = trimmed:match("^([%w_%-]+)%s*$")
			if not name then
				return nil, nil
			end
		end

		local cur_indent = leading_spaces(line)
		local search_row = row - 1
		while search_row >= 1 do
			local pline = api.nvim_buf_get_lines(bufnr, search_row - 1, search_row, false)[1] or ""
			local ptrim = pline:gsub("^%s+", "")
			if ptrim ~= "" then
				local p_indent = leading_spaces(pline)
				if p_indent < cur_indent then
					local parent = ptrim:match("^([%w_%-]+)%s*:%s*$")
					if
						parent
						and (
							parent == "dependencies"
							or parent == "dev_dependencies"
							or parent == "dependency_overrides"
						)
					then
						return name, parent
					end
					break
				end
			end
			search_row = search_row - 1
		end

		return nil, nil
	elseif manifest_key == "package" or manifest_key == "composer" then
		local name = trimmed:match('^"(.-)"') or trimmed:match("^'(.-)'")
		if not name then
			return nil, nil
		end

		local cur_indent = leading_spaces(line)
		local search_row = row - 1
		while search_row >= 1 do
			local pline = api.nvim_buf_get_lines(bufnr, search_row - 1, search_row, false)[1] or ""
			local ptrim = pline:gsub("^%s+", "")
			if ptrim ~= "" then
				local p_indent = leading_spaces(pline)
				if p_indent < cur_indent then
					if manifest_key == "package" then
						if ptrim:match([["dependencies"%s*:]]) then
							return name, "dependencies"
						end
						if ptrim:match([["devDependencies"%s*:]]) or ptrim:match([["dev_dependencies"%s*:]]) then
							return name, "devDependencies"
						end
					else
						if ptrim:match([["require"%s*:]]) then
							return name, "require"
						end
						if ptrim:match([["require%-dev"%s*:]]) or ptrim:match([["require_dev"%s*:]]) then
							return name, "require-dev"
						end
					end
					break
				end
			end
			search_row = search_row - 1
		end
		return nil, nil
	elseif manifest_key == "crates" then
		local name = line:match("^%s*([%w_%-]+)%s*=")
		if not name then
			return nil, nil
		end
		local search_row = row - 1
		while search_row >= 1 do
			local pline = api.nvim_buf_get_lines(bufnr, search_row - 1, search_row, false)[1] or ""
			local ptrim = pline:gsub("^%s+", ""):gsub("%s+$", "")
			if ptrim ~= "" then
				local section = ptrim:match("^%[(.-)%]$")
				if section then
					if
						section == "dependencies"
						or section == "dev-dependencies"
						or section == "build-dependencies"
					then
						return name, section
					end
					break
				end
			end
			search_row = search_row - 1
		end
		return nil, nil
	elseif manifest_key == "go" then
		local name = line:match("^%s*require%s+([^%s]+)") or line:match("^%s*([^%s]+)%s+v[%d%w%-%+%.]+")
		if name and name:match("%/") then
			return name, "require"
		end
		return nil, nil
	end

	return nil, nil
end

local function detect_inline_version(manifest_key, line)
	if not line or line == "" then
		return nil
	end

	if manifest_key == "package" or manifest_key == "composer" then
		local v = line:match(':%s*"(.-)"') or line:match(":%s*'(.-)'")
		if v and v ~= "" then
			return v
		end
		return nil
	end

	if manifest_key == "crates" then
		local v = line:match('=%s*"(.-)"') or line:match('=%s*{.-version%s*=%s*"(.-)".-}')
		if v and v ~= "" then
			return v
		end

		v = line:match("=%s*([^%s,]+)")
		if v and v ~= "" then
			return v
		end
		return nil
	end

	if manifest_key == "go" then
		local v = line:match("%s+v([%d%w%._%-%+]+)")
		if v and v ~= "" then
			return v
		end
		return nil
	end

	if manifest_key == "pubspec" then
		-- accept ranges and common operators (e.g. ^2.0.2, ~1.3.0, >=1.2.0)
		-- capture any non-space, non-comma sequence after ':'
		local v = line:match(":%s*([^%s,]+)")
		if v and v ~= "" then
			return v
		end
		return nil
	end
	return nil
end

local function completion_fn(_, cmd_line, _)
	local parts = vim.split(cmd_line, "%s+")

	if #parts >= 1 then
		table.remove(parts, 1)
	end

	local is_trailing_space = cmd_line:sub(-1) == " "
	local arg_index = #parts
	if is_trailing_space then
		arg_index = arg_index + 1
	end

	if arg_index == 1 then
		return validator.get_manifests()
	end
	if arg_index == 4 then
		return validator.get_scopes()
	end
	return {}
end

-- helper: get the "current" line for the given buffer.
-- Uses the buffer's last known cursor (mark ".") if available; falls back to api.nvim_get_current_line().
local function get_current_line_for_buf(bufnr)
	if not bufnr or not api.nvim_buf_is_valid(bufnr) then
		return api.nvim_get_current_line()
	end
	local m = api.nvim_buf_get_mark(bufnr, ".") or { 1, 0 }
	local row = (m[1] and m[1] > 0) and m[1] or 1
	return api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
end

-- helper: split "name@version" or "name:version" into name,version
local function split_name_version(name, version)
	if not name or name == "" then
		return name, version
	end
	-- try name@ver
	local n, v = name:match("^(.+)@(.+)$")
	if n and v and v ~= "" then
		return n, v
	end
	-- try name:ver
	n, v = name:match("^(.+):(.+)$")
	if n and v and v ~= "" then
		return n, v
	end
	-- if version already provided, keep it
	return name, version
end

M.install = function(manifest)
	if not manifest or manifest == "" then
		utils.notify_safe(
			"LvimDeps: manifest not detected; please run the command from a manifest buffer or pass the manifest",
			vim.log.levels.ERROR,
			{}
		)
		return
	end
	floating.install(manifest)
end

-- NOTE: signature: (manifest, name, version, scope)
M.update = function(manifest, name, version, scope)
	if not manifest or manifest == "" then
		utils.notify_safe(
			"LvimDeps: manifest not detected; please run the command from a manifest buffer or pass the manifest",
			vim.log.levels.ERROR,
			{}
		)
		return
	end

	local resolved_name = name
	local resolved_version = version
	local resolved_scope = scope

	if not resolved_name or resolved_name == "" then
		local detected_name, detected_scope = detect_dep_from_line(manifest)
		if not detected_name then
			utils.notify_safe(
				"LvimDeps: no package found on current line; specify package name as argument or place cursor on package line",
				vim.log.levels.ERROR,
				{}
			)
			return
		end
		resolved_name = detected_name
		resolved_scope = detected_scope

		local cur_line = get_current_line_for_buf() -- current buffer (command is buffer-local)
		resolved_version = resolved_version or detect_inline_version(manifest, cur_line)
	else
		-- if user passed "name@ver" as single arg, split it
		resolved_name, resolved_version = split_name_version(resolved_name, resolved_version)

		if not resolved_version or resolved_version == "" then
			local cur_line = get_current_line_for_buf()
			local inline_ver = detect_inline_version(manifest, cur_line)
			if inline_ver and inline_ver ~= "" then
				resolved_version = inline_ver
			end
		end

		if not resolved_scope or resolved_scope == "" then
			local detected_name, detected_scope = detect_dep_from_line(manifest)
			if detected_name == resolved_name and detected_scope then
				resolved_scope = detected_scope
			end
		end
	end

	floating.update(manifest, resolved_name, resolved_version, resolved_scope)
end

-- NOTE: signature: (manifest, name, version, scope)
M.delete = function(manifest, name, version, scope)
	if not manifest or manifest == "" then
		manifest = detect_manifest_from_buf()
	end

	local resolved_name = name
	local resolved_version = version
	local resolved_scope = scope

	if not resolved_name or resolved_name == "" then
		local detected_name, detected_scope = detect_dep_from_line(manifest)
		if not detected_name then
			utils.notify_safe(
				"LvimDeps: no package found on current line; specify package name as argument or place cursor on package line",
				vim.log.levels.ERROR,
				{}
			)
			return
		end
		resolved_name = detected_name
		resolved_scope = detected_scope
		local cur_line = get_current_line_for_buf()
		resolved_version = resolved_version or detect_inline_version(manifest, cur_line)
	else
		-- split name@version if user supplied that form
		resolved_name, resolved_version = split_name_version(resolved_name, resolved_version)

		if not resolved_scope or resolved_scope == "" then
			local detected_name, detected_scope = detect_dep_from_line(manifest)
			if detected_name == resolved_name and detected_scope then
				resolved_scope = detected_scope
			end
		end
		if not resolved_version or resolved_version == "" then
			local cur_line = get_current_line_for_buf()
			local inline_ver = detect_inline_version(manifest, cur_line)
			if inline_ver and inline_ver ~= "" then
				resolved_version = inline_ver
			end
		end
	end

	floating.delete(manifest, resolved_name, resolved_version, resolved_scope)
end

function M.create_buf_commands_for(bufnr, manifest)
	if not bufnr or not api.nvim_buf_is_valid(bufnr) then
		return
	end

	local ok, marker = pcall(api.nvim_buf_get_var, bufnr, "lvim_deps_cmds_created")
	if ok and marker then
		return
	end

	api.nvim_buf_create_user_command(bufnr, "LvimDepsInstall", function(opts)
		local manifest_arg, _, _, _ = validator.parse_args(opts.fargs)
		if not manifest_arg or manifest_arg == "" then
			manifest_arg = manifest or detect_manifest_from_buf(bufnr)
		end
		if not manifest_arg or manifest_arg == "" then
			utils.notify_safe("LvimDeps: manifest not detected; cannot run install", vim.log.levels.ERROR, {})
			return
		end
		M.install(manifest_arg)
	end, {
		nargs = "*",
		complete = completion_fn,
	})

	api.nvim_buf_create_user_command(bufnr, "LvimDepsUpdate", function(opts)
		local manifest_arg, name_arg, version_arg, scope_arg = validator.parse_args(opts.fargs)
		if not manifest_arg or manifest_arg == "" then
			manifest_arg = manifest or detect_manifest_from_buf(bufnr)
		end
		-- handle name@version form if user supplied it
		name_arg, version_arg = split_name_version(name_arg, version_arg)
		M.update(manifest_arg, name_arg, version_arg, scope_arg)
	end, {
		nargs = "*",
		complete = completion_fn,
	})

	api.nvim_buf_create_user_command(bufnr, "LvimDepsDelete", function(opts)
		local manifest_arg, name_arg, version_arg, scope_arg = validator.parse_args(opts.fargs)
		if not manifest_arg or manifest_arg == "" then
			manifest_arg = manifest or detect_manifest_from_buf(bufnr)
		end
		-- handle name@version form if user supplied it
		name_arg, version_arg = split_name_version(name_arg, version_arg)
		M.delete(manifest_arg, name_arg, version_arg, scope_arg)
	end, {
		nargs = "*",
		complete = completion_fn,
	})

	pcall(api.nvim_buf_set_var, bufnr, "lvim_deps_cmds_created", true)
end

M.init = function() end

return M
