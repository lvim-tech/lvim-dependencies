local M = {}

-- require libs once and pick the parser function up-front (no runtime checks)
local json = require("lvim-dependencies.libs.json")
local json_decode = json.decode or json.parse or json

local toml = require("lvim-dependencies.libs.toml")
local toml_parse = toml.parse or toml.decode or toml

local yaml = require("lvim-dependencies.libs.yaml")
local yaml_parse = yaml.parse or yaml.load or yaml.decode or yaml

-- Parse helpers: return nil for empty content, otherwise call the selected parser directly.
-- Any parsing errors will propagate from the underlying libraries (intentional: libraries exist).
function M.parse_json(content)
  if not content or content == "" then
    return nil
  end
  return json_decode(content)
end

function M.parse_toml(content)
  if not content or content == "" then
    return nil
  end
  return toml_parse(content)
end

function M.parse_yaml(content)
  if not content or content == "" then
    return nil
  end
  return yaml_parse(content)
end

return M
