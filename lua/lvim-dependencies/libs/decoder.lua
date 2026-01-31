local M = {}

function M.parse_json(content)
	if not content or content == "" then
		return nil, "empty content"
	end

	local ok_lib, json = pcall(require, "lvim-dependencies.libs.json")
	if not ok_lib or not json then
		return nil, "bundled json library not available (lvim-dependencies.libs.json)"
	end

	if type(json.decode) == "function" then
		local ok, res = pcall(json.decode, content)
		if ok then
			return res
		end
		return nil, "json.decode failed: " .. tostring(res)
	end
	if type(json.parse) == "function" then
		local ok, res = pcall(json.parse, content)
		if ok then
			return res
		end
		return nil, "json.parse failed: " .. tostring(res)
	end
	if type(json) == "function" then
		local ok, res = pcall(json, content)
		if ok then
			return res
		end
		return nil, "json() call failed: " .. tostring(res)
	end

	return nil, "json library has no decode/parse/callable API"
end

function M.parse_toml(content)
	if not content or content == "" then
		return nil, "empty content"
	end

	local ok_lib, toml = pcall(require, "lvim-dependencies.libs.toml")
	if not ok_lib or not toml then
		return nil, "bundled toml library not available (lvim-dependencies.libs.toml)"
	end

	if type(toml.parse) == "function" then
		local ok, res = pcall(toml.parse, content)
		if ok then
			return res
		end
		return nil, "toml.parse failed: " .. tostring(res)
	end
	if type(toml.decode) == "function" then
		local ok, res = pcall(toml.decode, content)
		if ok then
			return res
		end
		return nil, "toml.decode failed: " .. tostring(res)
	end
	if type(toml) == "function" then
		local ok, res = pcall(toml, content)
		if ok then
			return res
		end
		return nil, "toml() call failed: " .. tostring(res)
	end

	return nil, "toml library has no parse/decode/callable API"
end

function M.parse_yaml(content)
	if not content or content == "" then
		return nil, "empty content"
	end

	local ok_lib, yaml = pcall(require, "lvim-dependencies.libs.yaml")
	if not ok_lib or not yaml then
		ok_lib, yaml = pcall(require, "lvim-dependencies.libs.tinyyaml")
	end
	if not ok_lib or not yaml then
		return nil,
			"bundled yaml library not available (lvim-dependencies.libs.yaml or lvim-dependencies.libs.tinyyaml)"
	end

	if type(yaml.parse) == "function" then
		local ok, res = pcall(yaml.parse, content)
		if ok then
			return res
		end
		return nil, "yaml.parse failed: " .. tostring(res)
	end
	if type(yaml.load) == "function" then
		local ok, res = pcall(yaml.load, content)
		if ok then
			return res
		end
		return nil, "yaml.load failed: " .. tostring(res)
	end
	if type(yaml.decode) == "function" then
		local ok, res = pcall(yaml.decode, content)
		if ok then
			return res
		end
		return nil, "yaml.decode failed: " .. tostring(res)
	end
	if type(yaml) == "function" then
		local ok, res = pcall(yaml, content)
		if ok then
			return res
		end
		return nil, "yaml() call failed: " .. tostring(res)
	end

	return nil, "yaml library has no parse/load/decode/callable API"
end

return M
