-- Where a registry's answer arrives, and what a crate with no features may do with it.
--
-- `vim.system` runs its callback in a fast event, where most of the Neovim API is forbidden.
-- `http.get` handed that context on to whoever asked, so each caller had to remember to leave
-- it. The cargo features lookup did not: opening the features of a crate that has none raised
-- E5560 from `nvim_get_current_buf`, and only that error stood between the empty answer and a
-- rewrite of the dependency line.

local http = require("lvim-dependencies.utils.http")

--- Run a GET and report the callback's arguments and whether it ran in a fast event.
---@param url string
---@return { fast: boolean, output: string|nil, err: string|nil }
local function get(url)
    local seen
    http.get(url, function(output, err)
        seen = { fast = vim.in_fast_event(), output = output, err = err }
    end, 5)
    vim.wait(5000, function()
        return seen ~= nil
    end, 10)
    truthy(seen, "the callback ran")
    return seen
end

describe("http: a callback runs where the Neovim API is allowed")

it("on an answer", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "answer" }, path)
    local seen = get("file://" .. path)
    vim.fn.delete(path)
    eq(false, seen.fast, "fast event")
    eq("answer\n", seen.output)
end)

it("on a failure", function()
    local seen = get("file://" .. vim.fn.tempname() .. "-missing")
    eq(false, seen.fast, "fast event")
    truthy(seen.err, "the failure is reported")
end)

describe("cargo features: a crate with none has nothing to change")

--- Open the features of a crate the registry answers `body` for, with `update_features` spied.
---@param name string
---@param body string
---@return integer updates, string[] messages
local function open_features(name, body)
    local features = require("lvim-dependencies.managers.cargo.features")
    local real_get, real_update, real_notify = http.get, features.update_features, vim.notify
    local updates, messages = 0, {}
    http.get = function(_, callback)
        callback(body, nil)
    end
    features.update_features = function()
        updates = updates + 1
    end
    vim.notify = function(message)
        messages[#messages + 1] = message
    end
    local ok, err = pcall(function()
        features.clear_cache(name)
        features.show_ui(name, vim.api.nvim_get_current_buf())
        -- The second opening is served from the cache, which was its own way in.
        features.show_ui(name, vim.api.nvim_get_current_buf())
        vim.wait(50)
    end)
    http.get, features.update_features, vim.notify = real_get, real_update, real_notify
    features.clear_cache(name)
    truthy(ok, err)
    return updates, messages
end

it("says so and does not touch the manifest, first time or from the cache", function()
    local updates, messages = open_features("no-features", '{"versions":[{"yanked":false,"features":{}}]}')
    eq(0, updates, "update_features calls")
    eq(2, #messages, "one message per opening")
    truthy(messages[1]:match("No features available for no%-features"), messages[1])
end)
