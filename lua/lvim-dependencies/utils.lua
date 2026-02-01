local config = require("lvim-dependencies.config")
local const = require("lvim-dependencies.const")

local M = {}

M.merge = function(base, override)
	if type(override) ~= "table" then
		return override
	end

	for k, v in pairs(override) do
		if type(v) == "table" and type(base[k]) == "table" then
			base[k] = M.merge(base[k], v)
		else
			base[k] = v
		end
	end

	return base
end

M.notify_safe = function(msg, level, opts)
	if config.notify then
		vim.schedule(function()
			pcall(vim.notify, msg, level, opts)
		end)
	end
end

M.get_buffer_dir = function(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return vim.fn.getcwd()
	end
	return vim.fn.fnamemodify(name, ":h")
end

M.trim = function(s)
	if not s then
		return s
	end
	return s:match("^%s*(.-)%s*$")
end

M.strip_quotes = function(s)
	if not s then
		return s
	end
	return s:gsub("^%s*[\"'](.-)[\"']%s*$", "%1")
end

M.is_top_level_line = function(line)
	if not line then
		return false
	end
	return line:match("^%S.*:$") ~= nil
end

M.normalize_entry_val = function(val)
	if type(val) == "string" then
		local s = M.strip_quotes(M.trim(val))
		return s, (s ~= "")
	elseif type(val) == "table" then
		if val.version and type(val.version) == "string" then
			local s = M.strip_quotes(M.trim(val.version))
			return s, (s ~= "")
		end
		if #val >= 1 and type(val[1]) == "string" then
			local s = M.strip_quotes(M.trim(val[1]))
			return s, (s ~= "")
		end
		return "", false
	else
		return "", false
	end
end

M.normalize_version_spec = function(v)
	if not v then
		return nil
	end
	v = tostring(v):gsub("^%s*", ""):gsub("%s*$", "")
	v = v:gsub("^[%s%~%^><=]+", "")
	local sem = v:match("(%d+%.%d+%.%d+)")
	if sem then
		return sem
	end
	sem = v:match("(%d+%.%d+)")
	if sem then
		return sem
	end
	local tok = v:match("(%d+)")
	return tok
end

M.clean_version = function(value)
	if type(value) ~= "string" then
		return nil
	end

	local s = value:match("^%s*(.-)%s*$") or ""

	if
		s:match("^%s*git%+")
		or s:match("^%s*https?://")
		or s:match("^%s*file:")
		or s:match(".+/.+") and not s:match("^%d")
	then
		return nil
	end

	s = s:gsub("^%s*[vV]", "")
	s = s:gsub("^%s*[%^~=<>]+%s*", "")

	local semver = s:match("([0-9]+%.[0-9]+%.[0-9]+[-%w%.+]*)")
	if not semver then
		semver = s:match("([0-9]+%.[0-9]+[-%w%.+]*)")
	end

	if semver then
		return semver
	end

	return nil
end

M.read_file = function(path)
	if not path or path == "" then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines then
		return nil
	end
	return table.concat(lines, "\n")
end

M.find_lock_for_manifest = function(bufnr, manifest_key)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local start_dir = M.get_buffer_dir(bufnr) or vim.fn.getcwd()
	if not start_dir or start_dir == "" then
		start_dir = vim.fn.getcwd()
	end

	local candidates = const.LOCK_CANDIDATES[manifest_key] or {}
	local cur = vim.fn.fnamemodify(start_dir, ":p")
	local seen = {}

	while cur and cur ~= "" and not seen[cur] do
		seen[cur] = true
		for _, name in ipairs(candidates) do
			local p = vim.fn.fnamemodify(cur .. "/" .. name, ":p")
			if vim.fn.filereadable(p) == 1 then
				return p
			end
		end
		local parent = vim.fn.fnamemodify(cur, ":h")
		if parent == cur then
			break
		end
		cur = parent
	end

	return nil
end

-- Check if package exists in lock file for given manifest type
M.is_package_in_lock = function(manifest, name)
	local lock_path = M.find_lock_for_manifest(nil, manifest)

	if not lock_path then
		return false
	end

	local ok, lines = pcall(vim.fn.readfile, lock_path)
	if not ok or type(lines) ~= "table" then
		return false
	end

	-- Escape special pattern characters in package name
	local escaped_name = vim.pesc(name)

	for _, line in ipairs(lines) do
		if manifest == "pubspec" then
			if line:match("^%s+" .. escaped_name .. "%s*:") then
				return true
			end
		elseif manifest == "crates" then
			if line:match('name%s*=%s*"' .. escaped_name .. '"') then
				return true
			end
		elseif manifest == "package" then
			if line:match('"' .. escaped_name .. '"') or line:match("'" .. escaped_name .. "'") then
				return true
			end
		elseif manifest == "composer" then
			if line:match('"' .. escaped_name .. '"') then
				return true
			end
		elseif manifest == "go" then
			if line:match(escaped_name) then
				return true
			end
		end
	end

	return false
end

return M
