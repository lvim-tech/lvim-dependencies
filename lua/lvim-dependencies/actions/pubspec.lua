local utils = require("lvim-dependencies.utils")
local inspect = vim.inspect
local L = vim.log.levels

local M = {}

local function urlencode(str)
	if not str then
		return ""
	end
	str = tostring(str)
	return (str:gsub("[^%w%-._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function find_pubspec_path()
	local cwd = vim.fn.getcwd()
	while true do
		local candidate = cwd .. "/pubspec.yaml"
		if vim.fn.filereadable(candidate) == 1 then
			return candidate
		end
		local parent = vim.fn.fnamemodify(cwd, ":h")
		if parent == cwd or parent == "" then
			break
		end
		cwd = parent
	end
	return nil
end

local function read_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return nil
	end
	return lines
end

local function write_lines(path, lines)
	local ok, err = pcall(vim.fn.writefile, lines, path)
	if not ok then
		return false, tostring(err)
	end
	return true
end

-- Helper: find section start index for "dependencies" or "dev_dependencies"
local function find_section_index(lines, section_name)
	for i, ln in ipairs(lines) do
		if ln:match("^%s*" .. vim.pesc(section_name) .. "%s*:") then
			return i
		end
	end
	return nil
end

-- Helper: determine section end index (first following non-indented top-level line or EOF)
local function find_section_end(lines, section_idx)
	local section_end = #lines
	for i = section_idx + 1, #lines do
		local ln = lines[i]
		if ln:match("^%S") then
			section_end = i - 1
			break
		end
	end
	return section_end
end

-- Replace package entry (scalar or block) inside given section.
-- Returns new_lines (table) and true on success. If package not found, returns nil,false.
local function replace_package_in_section(lines, section_idx, section_end, pkg_name, new_line)
	for i = section_idx + 1, section_end do
		local ln = lines[i]
		-- match start of an entry: optional indent, name:
		local m_name = ln:match("^%s*([%w%-%_%.]+)%s*:")
		if m_name and tostring(m_name) == tostring(pkg_name) then
			-- found package start
			local pkg_indent = ln:match("^(%s*)") or ""
			local pkg_indent_len = #pkg_indent
			-- Determine block end: include subsequent lines that are more indented than package line
			local block_end = i
			for j = i + 1, section_end do
				local next_ln = lines[j]
				if not next_ln then
					break
				end
				-- empty line or top-level (non-space) ends block
				if next_ln:match("^%S") then
					break
				end
				local next_indent = next_ln:match("^(%s*)") or ""
				if #next_indent > pkg_indent_len then
					block_end = j
				else
					break
				end
			end

			-- Build new lines: lines[1..i-1] + { new_line } + lines[block_end+1 .. end]
			local out = {}
			for k = 1, i - 1 do
				out[#out + 1] = lines[k]
			end
			out[#out + 1] = new_line
			for k = block_end + 1, #lines do
				out[#out + 1] = lines[k]
			end
			return out, true
		end
	end
	return nil, false
end

-- Insert package scalar line under section (at section_idx+1)
local function insert_package_in_section(lines, section_idx, pkg_name, new_line)
	local out = {}
	for k = 1, section_idx do
		out[#out + 1] = lines[k]
	end
	out[#out + 1] = new_line
	for k = section_idx + 1, #lines do
		out[#out + 1] = lines[k]
	end
	return out, true
end

-- Semver-ish helpers used to sort versions descending
local function version_parts(v)
	if not v then return nil end
	v = tostring(v)
	-- remove quotes and surrounding whitespace/comments
	v = v:gsub('["\',]', ""):gsub("^%s*", ""):gsub("%s*$", "")
	-- strip common operators ^ ~ >= <= = < >
	v = v:gsub("^[%s%~%^><=]+", "")
	-- extract main numeric part (x.y.z or x.y or x)
	local main = v:match("^(%d+%.%d+%.%d+)") or v:match("^(%d+%.%d+)") or v:match("^(%d+)")
	if not main then return nil end
	local major, minor, patch = main:match("^(%d+)%.(%d+)%.(%d+)")
	if major and minor and patch then
		return { tonumber(major), tonumber(minor), tonumber(patch) }
	end
	local maj_min = main:match("^(%d+)%.(%d+)")
	if maj_min then
		local ma, mi = maj_min:match("^(%d+)%.(%d+)")
		return { tonumber(ma), tonumber(mi), 0 }
	end
	local single = main:match("^(%d+)")
	if single then
		return { tonumber(single), 0, 0 }
	end
	return nil
end

local function compare_version_parts(a, b)
	-- nil means unparseable/lowest
	if not a and not b then return 0 end
	if not a then return -1 end
	if not b then return 1 end
	for i = 1, 3 do
		local ai = a[i] or 0
		local bi = b[i] or 0
		if ai > bi then return 1 end
		if ai < bi then return -1 end
	end
	return 0
end

-- Synchronous fetch (keeps compatibility)
function M.fetch_versions(name, opts)
	if not name or name == "" then
		return nil
	end
	local current = nil
	local ok_state, state = pcall(require, "lvim-dependencies.state")
	if ok_state and type(state.get_installed_version) == "function" then
		current = state.get_installed_version("pubspec", name)
	end

	local pkg = urlencode(name)
	local url = ("https://pub.dev/api/packages/%s"):format(pkg)

	local ok_http, body = pcall(function()
		return vim.fn.system({ "curl", "-fsS", "--max-time", "10", url })
	end)
	if not ok_http or not body or body == "" then
		return nil
	end

	local ok_json, parsed = pcall(vim.fn.json_decode, body)
	if not ok_json or type(parsed) ~= "table" then
		return nil
	end

	local raw_versions = parsed.versions
	if not raw_versions or type(raw_versions) ~= "table" then
		return nil
	end

	-- collect versions (unique)
	local seen, uniq = {}, {}
	for _, v in ipairs(raw_versions) do
		local ver = nil
		if type(v) == "table" and v.version then ver = tostring(v.version) end
		if type(v) == "string" then ver = tostring(v) end
		if ver and not seen[ver] then
			seen[ver] = true
			uniq[#uniq + 1] = ver
		end
	end

	-- sort uniq by semver desc (highest first). Entries unparseable go to bottom in original order.
	table.sort(uniq, function(a, b)
		local pa = version_parts(a)
		local pb = version_parts(b)
		local cmp = compare_version_parts(pa, pb)
		if cmp == 0 then
			-- preserve original lexical order for equals (or fallback to string compare)
			return a > b
		end
		return cmp == 1 -- a > b means a should come before b (desc)
	end)

	return { versions = uniq, current = current }
end

-- Async helper to run pub get and handle success/rollback
local function run_pub_get_with_rollback(path, old_lines, name, version, scope)
	-- decide command
	local has_flutter = false
	local lines = read_lines(path)
	if lines then
		for _, l in ipairs(lines) do
			if l:match("^%s*flutter%s*:") then
				has_flutter = true
				break
			end
		end
	end

	local cmd
	if has_flutter and vim.fn.executable("flutter") == 1 then
		cmd = { "flutter", "pub", "get" }
	elseif vim.fn.executable("dart") == 1 then
		cmd = { "dart", "pub", "get" }
	else
		utils.notify_safe("pubspec: neither flutter nor dart CLI available to run pub get", L.ERROR, {})
		-- restore to be safe
		if old_lines then
			pcall(write_lines, path, old_lines)
		end
		return
	end

	local out, err = {}, {}
	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data, _)
			if data then
				for _, ln in ipairs(data) do
					out[#out + 1] = ln
				end
			end
		end,
		on_stderr = function(_, data, _)
			if data then
				for _, ln in ipairs(data) do
					err[#err + 1] = ln
				end
			end
		end,
		on_exit = function(_, code, _)
			vim.schedule(function()
				if code == 0 then
					utils.notify_safe("pubspec: pub get finished successfully", L.INFO, {})
					-- update in-memory state if available
					local ok_state, state = pcall(require, "lvim-dependencies.state")
					if ok_state and type(state.add_installed_dependency) == "function" then
						pcall(state.add_installed_dependency, "pubspec", name, version, scope)
					end
					-- emit user event so UI can refresh
					pcall(function()
						vim.g.lvim_deps_last_updated = name .. "@" .. tostring(version)
						vim.api.nvim_exec("doautocmd User LvimDepsPackageUpdated", false)
					end)
				else
					-- rollback: restore old file
					local msg = table.concat(err, "\n")
					if msg == "" then
						msg = "pub get exited with code " .. tostring(code)
					end
					local okw, werr = pcall(write_lines, path, old_lines)
					if not okw then
						utils.notify_safe(
							("pubspec: pub get failed: %s\nAlso failed to restore pubspec.yaml: %s"):format(
								msg,
								tostring(werr)
							),
							L.ERROR,
							{}
						)
					else
						utils.notify_safe(
							("pubspec: pub get failed; restored pubspec.yaml. Error: %s"):format(msg),
							L.ERROR,
							{}
						)
					end
				end
			end)
		end,
	})
end

-- Update signature: M.update(name, opts)
function M.update(name, opts)
	if not name or name == "" then
		return { ok = false, msg = "package name required" }
	end
	opts = opts or {}
	local version = opts.version
	if not version or version == "" then
		return { ok = false, msg = "version is required" }
	end

	local scope = opts.scope or "dependencies"
	if scope ~= "dependencies" and scope ~= "dev_dependencies" then
		scope = "dependencies"
	end

	local path = find_pubspec_path()
	if not path then
		return { ok = false, msg = "pubspec.yaml not found in project tree" }
	end

	local lines = read_lines(path)
	if not lines then
		return { ok = false, msg = "unable to read pubspec.yaml" }
	end

	-- keep a copy for rollback
	local old_lines = {}
	for i = 1, #lines do
		old_lines[i] = lines[i]
	end

	local section_idx = find_section_index(lines, scope)
	if not section_idx then
		-- create section at end
		lines[#lines + 1] = ""
		lines[#lines + 1] = scope .. ":"
		section_idx = #lines - 1
	end

	local section_end = find_section_end(lines, section_idx)
	local pkg_indent = "  " -- default 2 spaces inside dependencies
	-- prepare new scalar line (use package indent)
	-- determine indent from first dependency line if any
	local sample_ln = lines[section_idx + 1]
	if sample_ln then
		local s_indent = sample_ln:match("^(%s*)") or ""
		if #s_indent > 0 then
			pkg_indent = s_indent
		end
	end
	local new_line = string.format("%s%s: %s", pkg_indent, name, tostring(version))

	-- try replace existing entry (scalar or block)
	local new_lines, replaced = replace_package_in_section(lines, section_idx, section_end, name, new_line)
	if not replaced then
		-- insert new scalar line under section
		new_lines, _ = insert_package_in_section(lines, section_idx, name, new_line)
	end

	-- (Optional) keep previous sorting behaviour for section entries unchanged here,
	-- or add section sorting logic if you want file-level ordering.
	-- For now we keep insertion/replacement, file sorting optional.

	-- write the modified file
	local okw, werr = write_lines(path, new_lines)
	if not okw then
		return { ok = false, msg = "failed to write pubspec.yaml: " .. tostring(werr) }
	end

	-- start pub get async and handle rollback on failure
	run_pub_get_with_rollback(path, old_lines, name, version, scope)

	utils.notify_safe(("pubspec: set %s -> %s and started pub get"):format(name, tostring(version)), L.INFO, {})

	return { ok = true, msg = "started" }
end

function M.add(name, opts)
	utils.notify_safe(("pubspec.add called: name=%s opts=%s"):format(tostring(name), inspect(opts or {})), L.INFO, {})
end
function M.delete(name, opts)
	utils.notify_safe(
		("pubspec.delete called: name=%s opts=%s"):format(tostring(name), inspect(opts or {})),
		L.INFO,
		{}
	)
	return { ok = true }
end
function M.install(opts)
	local path = find_pubspec_path()
	if not path then
		return { ok = false, msg = "pubspec.yaml not found" }
	end
	run_pub_get_with_rollback(path, read_lines(path), "<bulk-install>", nil, "dependencies")
	return { ok = true, msg = "started" }
end
function M.check_outdated(opts)
	utils.notify_safe(("pubspec.check_outdated called: opts=%s"):format(inspect(opts or {})), L.INFO, {})
	return { ok = true }
end

return M
