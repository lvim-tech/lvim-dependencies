local api = vim.api
local fn = vim.fn

local M = {}

local cache_dir = fn.stdpath("cache") or vim.fn.expand("~/.cache")
local log_path = cache_dir .. "/lvim_deps_debug.log"

local function append_log(s)
	local ok, f = pcall(io.open, log_path, "a")
	if not ok or not f then
		return
	end
	f:write(s)
	f:close()
end

-- Save originals (if already saved, keep them)
if not _G.__lvim_deps_orig_buf_set_lines then
	_G.__lvim_deps_orig_buf_set_lines = api.nvim_buf_set_lines
end
if not _G.__lvim_deps_orig_writefile then
	_G.__lvim_deps_orig_writefile = fn.writefile
end

local function make_header(kind, target)
	return string.format(
		"\n\n================ lvim-deps DEBUG [%s] %s @ %s ================\n",
		tostring(kind),
		tostring(target or ""),
		os.date("%Y-%m-%d %H:%M:%S")
	)
end

local function wrap_buf_set_lines()
	if _G.__lvim_deps_wrapped_buf_set_lines then return end
	local orig = _G.__lvim_deps_orig_buf_set_lines
	api.nvim_buf_set_lines = function(buf, start, finish, strict, lines)
		local name = "unknown"
		pcall(function() name = api.nvim_buf_get_name(buf) end)
		
		-- ONLY log if it's pubspec.yaml (filter noise)
		if name:match("pubspec%.yaml$") then
			local header = make_header("nvim_buf_set_lines", name)
			local body = string.format("buf=%s start=%s finish=%s strict=%s lines_count=%s\n",
				tostring(buf), tostring(start), tostring(finish), tostring(strict), tostring((lines and #lines) or 0))
			local stack = debug.traceback()
			append_log(header .. body .. stack .. "\n")
		end
		
		return orig(buf, start, finish, strict, lines)
	end
	_G.__lvim_deps_wrapped_buf_set_lines = true
end

local function wrap_writefile()
	if _G.__lvim_deps_wrapped_writefile then return end
	local orig = _G.__lvim_deps_orig_writefile
	fn.writefile = function(lines, path, ...)
		-- ONLY log if it's pubspec.yaml (filter noise)
		if path and tostring(path):match("pubspec%.yaml$") then
			local header = make_header("writefile", path)
			local body = string.format("path=%s lines_count=%s\n", tostring(path), tostring((lines and #lines) or 0))
			local stack = debug.traceback()
			append_log(header .. body .. stack .. "\n")
		end
		
		return orig(lines, path, ...)
	end
	_G.__lvim_deps_wrapped_writefile = true
end

function M.enable()
	wrap_buf_set_lines()
	wrap_writefile()
	-- Single quiet notification on enable
	vim.notify(("lvim-deps debug enabled (silent mode). Log: %s"):format(log_path), vim.log.levels.INFO)
end

function M.disable()
	if _G.__lvim_deps_wrapped_buf_set_lines and _G.__lvim_deps_orig_buf_set_lines then
		api.nvim_buf_set_lines = _G.__lvim_deps_orig_buf_set_lines
		_G.__lvim_deps_wrapped_buf_set_lines = nil
	end
	if _G.__lvim_deps_wrapped_writefile and _G.__lvim_deps_orig_writefile then
		fn.writefile = _G.__lvim_deps_orig_writefile
		_G.__lvim_deps_wrapped_writefile = nil
	end
	vim.notify("lvim-deps debug disabled", vim.log.levels.INFO)
end

-- auto-enable when required
M.enable()

-- helper to show log path
function M.log_path()
	return log_path
end

-- helper to clear log
function M.clear_log()
	pcall(io.open, log_path, "w"):close()
	vim.notify("lvim-deps debug log cleared", vim.log.levels.INFO)
end

return M
