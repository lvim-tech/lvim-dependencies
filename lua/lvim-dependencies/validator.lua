local M = {}

local manifests = {
	package = {
		allowed = { "dependencies", "devDependencies", "optionalDependencies", "peerDependencies" },
		aliases = {
			dev = "devDependencies",
			dev_dependencies = "devDependencies",
			optional = "optionalDependencies",
			peer = "peerDependencies",
		},
	},
	crates = {
		allowed = { "dependencies", "dev-dependencies", "build-dependencies" },
		aliases = {
			dev = "dev-dependencies",
			dev_dependencies = "dev-dependencies",
			build = "build-dependencies",
		},
	},
	pubspec = {
		allowed = { "dependencies", "dev_dependencies", "dependency_overrides" },
		aliases = {
			dev = "dev_dependencies",
			overrides = "dependency_overrides",
		},
	},
	composer = {
		allowed = { "require", "require-dev" },
		aliases = {
			dev = "require-dev",
			require_dev = "require-dev",
		},
	},
	go = {
		allowed = { "require" },
		aliases = {
			require = "require",
		},
	},
}

local function normalize_key(s)
	return s:lower():gsub("[%s%_]+", ""):gsub("%-+", "")
end

local function uniq(tbl)
	local seen = {}
	local out = {}
	for _, v in ipairs(tbl) do
		if not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	return out
end

function M.get_manifests()
	local out = {}
	for k in pairs(manifests) do
		out[#out + 1] = k
	end
	table.sort(out)
	return out
end

function M.get_scopes()
	local out = {}
	for _, entry in pairs(manifests) do
		for _, a in ipairs(entry.allowed) do
			out[#out + 1] = a
		end
		if entry.aliases then
			for _, v in pairs(entry.aliases) do
				out[#out + 1] = v
			end
		end
	end
	return uniq(out)
end

function M.is_supported_manifest(manifest)
	return type(manifest) == "string" and manifests[manifest] ~= nil
end

function M.parse_args(fargs)
	-- Returns: manifest, name, version, scope
	if not fargs or #fargs == 0 then
		return nil, nil, nil, nil
	end

	local n = #fargs
	-- If first arg is a supported manifest, consume it as manifest.
	if M.is_supported_manifest(fargs[1]) then
		local manifest = fargs[1]
		if n == 1 then
			return manifest, nil, nil, nil
		elseif n == 2 then
			return manifest, fargs[2], nil, nil
		elseif n == 3 then
			return manifest, fargs[2], fargs[3], nil
		else
			return manifest, fargs[2], fargs[3], fargs[4]
		end
	end

	-- Otherwise assume manifest omitted: shift arguments
	if n == 1 then
		return nil, fargs[1], nil, nil
	elseif n == 2 then
		return nil, fargs[1], fargs[2], nil
	elseif n == 3 then
		return nil, fargs[1], fargs[2], fargs[3]
	else
		-- more than 3 args and no manifest: take first three as name,version,scope
		return nil, fargs[1], fargs[2], fargs[3]
	end
end

function M.detect_manifest_from_filename(filename)
	if not filename or filename == "" then
		return nil
	end
	local base = filename
	if base == "package.json" then
		return "package"
	end
	if base == "Cargo.toml" then
		return "crates"
	end
	if base == "pubspec.yaml" or base == "pubspec.yml" then
		return "pubspec"
	end
	if base == "composer.json" then
		return "composer"
	end
	if base == "go.mod" then
		return "go"
	end
	return nil
end

function M.validate_manifest_and_scope(manifest, scope)
	if type(manifest) ~= "string" or manifest == "" then
		return false, nil, "manifest must be a non-empty string"
	end

	local entry = manifests[manifest]
	if not entry then
		return false, nil, ("unsupported manifest '%s'"):format(tostring(manifest))
	end

	if type(scope) ~= "string" or scope == "" then
		return false,
			nil,
			("scope required for manifest '%s' (allowed: %s)"):format(manifest, table.concat(entry.allowed, ", "))
	end

	for _, a in ipairs(entry.allowed) do
		if scope == a then
			return true, a, nil
		end
	end

	local lk = scope:lower()
	if entry.aliases and entry.aliases[lk] then
		return true, entry.aliases[lk], nil
	end

	local ns = normalize_key(scope)
	for _, a in ipairs(entry.allowed) do
		if normalize_key(a) == ns then
			return true, a, nil
		end
	end
	for k, v in pairs(entry.aliases or {}) do
		if normalize_key(k) == ns then
			return true, v, nil
		end
	end

	return false,
		nil,
		("invalid scope '%s' for manifest '%s' (allowed: %s)"):format(
			tostring(scope),
			manifest,
			table.concat(entry.allowed, ", ")
		)
end

return M
