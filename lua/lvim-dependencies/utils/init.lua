local M = {}

-- Merge две таблици рекурсивно
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

-- Проверка дали файл съществува
M.file_exists = function(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- Прочитане на файл
M.read_file = function(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*all")
	f:close()
	return content
end

-- Намиране на файл във текущата директория или нагоре
M.find_file_upwards = function(pattern)
	local cwd = vim.fn.getcwd()
	local path = cwd

	while path ~= "/" do
		local file_path = path .. "/" .. pattern
		if M.file_exists(file_path) then
			return file_path
		end
		path = vim.fn.fnamemodify(path, ":h")
	end

	return nil
end

-- Извличане на ред и позиция на курсора
M.get_cursor_position = function()
	local cursor = vim.api.nvim_win_get_cursor(0)
	return cursor[1], cursor[2]
end

-- Notification helper
M.notify = function(message, level)
	vim.notify("[lvim-dependencies] " .. message, level or vim.log.levels.INFO)
end

--- Clean a version string from common operators and noise.
-- Examples:
--   "^1.2.3"    -> "1.2.3"
--   "~0.5.0"    -> "0.5.0"
--   ">=1.2.0 <2"-> "1.2.0"
--   "v2.0.1"    -> "2.0.1"
--   "git+ssh://..." -> nil
--   "file:../localpkg" -> nil
-- @param value string|nil
-- @return string|nil cleaned version or nil if none
function M.clean_version(value)
	if type(value) ~= "string" then
		return nil
	end

	-- trim
	local s = value:match("^%s*(.-)%s*$") or ""

	-- If it's a git/url/file/local reference -> treat as non-semver
	if
		s:match("^%s*git%+")
		or s:match("^%s*https?://")
		or s:match("^%s*file:")
		or s:match(".+/.+") and not s:match("^%d")
	then
		return nil
	end

	-- Remove leading operators and optional "v"
	-- common prefixes: ^ ~ >= <= > < = v
	s = s:gsub("^%s*[vV]", "")
	s = s:gsub("^%s*[%^~=<>]+%s*", "")

	-- For ranges like ">=1.2.0 <2.0.0" take the first semver-like token
	-- Match full semver-ish (major.minor.patch with optional prerelease/build)
	local semver = s:match("([0-9]+%.[0-9]+%.[0-9]+[-%w%.+]*)")
	if not semver then
		-- fallback: try major.minor
		semver = s:match("([0-9]+%.[0-9]+[-%w%.+]*)")
	end

	if semver then
		return semver
	end

	-- If nothing matched, return nil
	return nil
end

return M
