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
	if config.notify.enabled then
		vim.schedule(function()
			local default_opts = {
				title = config.notify.title,
				timeout = config.notify.timeout,
			}
			local final_opts = vim.tbl_extend("force", default_opts, opts or {})
			pcall(vim.notify, msg, level, final_opts)
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

-- ------------------------------------------------------------
-- File stat + cached reads (to avoid repeated disk IO)
-- ------------------------------------------------------------
local file_cache = {
	-- [path] = { mtime=..., size=..., content="..." }
}

M.fs_stat = function(path)
	if not path or path == "" then
		return nil
	end
	local ok, st = pcall(vim.loop.fs_stat, path)
	if not ok then
		return nil
	end
	return st
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

-- Cached read: returns content and stat tuple (mtime,size)
M.read_file_cached = function(path)
	if not path or path == "" then
		return nil, nil, nil
	end

	local st = M.fs_stat(path)
	if not st then
		file_cache[path] = nil
		return nil, nil, nil
	end

	local mtime = (st.mtime and st.mtime.sec) or 0
	local size = st.size or 0

	local cached = file_cache[path]
	if cached and cached.mtime == mtime and cached.size == size and type(cached.content) == "string" then
		return cached.content, mtime, size
	end

	local content = M.read_file(path)
	if not content then
		file_cache[path] = { mtime = mtime, size = size, content = "" }
		return "", mtime, size
	end

	file_cache[path] = { mtime = mtime, size = size, content = content }
	return content, mtime, size
end

M.clear_file_cache = function(path)
	if path then
		file_cache[path] = nil
	else
		file_cache = {}
	end
end

-- ------------------------------------------------------------
-- Lock file discovery
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- is_package_in_lock (used by UI actions: update/delete)
-- Reintroduced for compatibility + correctness.
-- IMPORTANT: UI rendering must NOT call this; only commands/actions.
-- ------------------------------------------------------------
local lock_presence_cache = {
	-- [lock_path.."::"..name] = { mtime=..., size=..., found=true/false }
}

M.is_package_in_lock = function(manifest, name, bufnr)
	if not manifest or manifest == "" or not name or name == "" then
		return false
	end

	local lock_path = M.find_lock_for_manifest(bufnr, manifest)
	if not lock_path then
		return false
	end

	-- Use stat-based cache per package per lock file
	local st = M.fs_stat(lock_path)
	local mtime = st and st.mtime and st.mtime.sec or 0
	local size = st and st.size or 0
	local cache_key = lock_path .. "::" .. name
	local cached = lock_presence_cache[cache_key]
	if cached and cached.mtime == mtime and cached.size == size then
		return cached.found
	end

	-- For package manifests, use the lock parser (pnpm/npm) for accuracy.
	-- This is safe because this function is only called from commands/UI actions, not render loops.
	if manifest == "package" then
		local ok_parser, parser = pcall(require, "lvim-dependencies.parsers.package")
		if ok_parser and parser and type(parser.parse_lock_file_path) == "function" then
			local ok_parse, lock_versions = pcall(parser.parse_lock_file_path, lock_path)
			local found = (ok_parse and type(lock_versions) == "table" and lock_versions[name] ~= nil) or false
			lock_presence_cache[cache_key] = { mtime = mtime, size = size, found = found }
			return found
		end
	end

	-- Fallback line-scan for other manifests (and package if parser missing)
	local ok, lines = pcall(vim.fn.readfile, lock_path)
	if not ok or type(lines) ~= "table" then
		lock_presence_cache[cache_key] = { mtime = mtime, size = size, found = false }
		return false
	end

	local escaped_name = vim.pesc(name)
	local found = false

	for _, line in ipairs(lines) do
		if manifest == "pubspec" then
			if line:match("^%s+" .. escaped_name .. "%s*:") then
				found = true
				break
			end
		elseif manifest == "crates" then
			if line:match('name%s*=%s*"' .. escaped_name .. '"') then
				found = true
				break
			end
		elseif manifest == "composer" then
			if line:match('"' .. escaped_name .. '"') then
				found = true
				break
			end
		elseif manifest == "go" then
			if line:match(escaped_name) then
				found = true
				break
			end
		elseif manifest == "package" then
			-- only if parser missing, very loose fallback
			if line:match('"' .. escaped_name .. '"') or line:match("'" .. escaped_name .. "'") then
				found = true
				break
			end
		end
	end

	lock_presence_cache[cache_key] = { mtime = mtime, size = size, found = found }
	return found
end

return M
