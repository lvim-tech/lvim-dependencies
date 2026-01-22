local M = {}

function M.file_exists(path)
	if type(path) ~= "string" or path == "" then
		return false
	end
	-- use luv stat which is faster and avoids opening files
	local stat = vim.loop.fs_stat(path)
	return stat ~= nil
end

function M.read_file(path)
	if not M.file_exists(path) then
		return nil, "file not found"
	end
	local fh, err = io.open(path, "r")
	if not fh then
		return nil, err
	end
	local content = fh:read("*a")
	fh:close()
	return content
end

local function normalize_dir(p)
	if not p or p == "" then
		return p
	end

	if p == "." then
		return vim.fn.getcwd()
	end

	-- strip trailing slash/backslash
	if #p > 1 then
		local last = p:sub(-1)
		if last == "/" or last == "\\" then
			return p:sub(1, -2)
		end
	end
	return p
end

function M.find_file_upwards(pattern, start_dir)
	if type(pattern) ~= "string" or pattern == "" then
		return nil
	end

	local dir = start_dir or vim.fn.getcwd()
	dir = normalize_dir(dir)

	while dir and dir ~= "" do
		local candidate = dir .. "/" .. pattern
		if M.file_exists(candidate) then
			return candidate
		end

		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end

	return nil
end

function M.find_any_file_upwards(files, start_dir)
	if type(files) ~= "table" then
		return nil
	end
	for _, fname in ipairs(files) do
		local found = M.find_file_upwards(fname, start_dir)
		if found then
			return found, fname
		end
	end
	return nil
end

function M.is_executable(name)
	if type(name) ~= "string" or name == "" then
		return false
	end
	return vim.fn.executable(name) == 1
end

function M.find_executable_in_path(name)
	if not M.is_executable(name) then
		return nil
	end

	local p = vim.fn.exepath(name)
	if p == "" then
		return nil
	end
	return p
end

function M.get_buffer_dir(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return vim.fn.getcwd()
	end
	return vim.fn.fnamemodify(name, ":h")
end

return M
