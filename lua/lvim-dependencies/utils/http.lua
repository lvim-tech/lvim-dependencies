-- lvim-dependencies.utils.http: minimal async HTTP GET helpers built on `curl` via
-- `vim.system`, used to fetch registry metadata. Callbacks always receive `(result, err)`
-- so network/parse failures propagate without throwing; get_json layers JSON decoding on top.
--
---@module "lvim-dependencies.utils.http"

local M = {}

--- Who we say we are. crates.io's crawler policy REFUSES curl's own `curl/8.x` with 403 —
--- every `latest` lookup for Cargo failed on it, and the error replaced the virtual text that
--- the declared/installed data had already earned. A registry is entitled to know who is
--- calling it, so every request says so, not only the crates.io ones.
M.USER_AGENT = "lvim-dependencies (+https://github.com/lvim-tech/lvim-dependencies)"

--- The curl argv for a GET of `url`. Exposed so the identification above is testable without
--- a network round trip.
---@param url string
---@param timeout number Timeout in seconds
---@return string[]
function M.build_cmd(url, timeout)
    return { "curl", "-f", "-s", "-L", "-A", M.USER_AGENT, "--max-time", tostring(timeout), url }
end

--- HTTP GET request using curl
---@param url string
---@param callback fun(output: string|nil, err: string|nil)
---@param timeout? number Timeout in seconds (default 10)
function M.get(url, callback, timeout)
    timeout = timeout or 10

    vim.system(M.build_cmd(url, timeout), { text = true }, function(obj)
        if obj.code == 0 then
            callback(obj.stdout, nil)
        else
            callback(nil, string.format("curl failed with code %d: %s", obj.code, obj.stderr or "unknown error"))
        end
    end)
end

--- HTTP GET with JSON response
---@param url string
---@param callback fun(data: table|nil, err: string|nil)
---@param timeout? number
function M.get_json(url, callback, timeout)
    M.get(url, function(output, err)
        if err then
            callback(nil, err)
            return
        end

        if not output or output == "" then
            callback(nil, "Empty response from server")
            return
        end

        local ok, data = pcall(vim.json.decode, output)
        if not ok then
            callback(nil, "Failed to parse JSON response")
            return
        end

        callback(data, nil)
    end, timeout)
end

return M
