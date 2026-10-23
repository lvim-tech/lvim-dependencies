-- What gets asked of a registry, and what is shown when the answer does not come.
--
-- Three faults met on the same line of a Cargo.toml and together erased it:
--   * crates.io answers 403 to curl's own User-Agent, so EVERY `latest` lookup failed;
--   * a path / git / sdk / workspace dependency was looked up at all, and 404s;
--   * a failed lookup then replaced the declared and installed versions — facts read from
--     the manifest and the lock file, still true — with its own error message.

local http = require("lvim-dependencies.utils.http")

describe("http: the plugin says who it is")

it("sends a User-Agent of its own, not curl's", function()
    local cmd = http.build_cmd("https://crates.io/api/v1/crates/serde", 10)
    local agent
    for i, arg in ipairs(cmd) do
        if arg == "-A" then
            agent = cmd[i + 1]
        end
    end
    truthy(agent, "the argv carries -A")
    truthy(not agent:match("^curl/"), "and not curl's own, which crates.io answers 403 to")
    truthy(agent:match("lvim%-dependencies"), "it names the plugin: " .. tostring(agent))
end)

it("still carries the url and the timeout it was given", function()
    local cmd = http.build_cmd("https://example.com/x", 7)
    eq("https://example.com/x", cmd[#cmd])
    truthy(vim.tbl_contains(cmd, "7"), "the timeout is passed through")
end)

describe("package_loader: a dependency with no registry entry is not looked up")

--- Run `fn(package_loader)` with the three hubs replaced, then put the real ones back.
---@param hub_latest table
---@param declared table
---@param fn fun(loader: table)
local function with_hubs(hub_latest, declared, fn)
    local names = {
        ["lvim-dependencies.core.hub.declared"] = {
            get_data = function()
                return declared
            end,
            clear_cache = function() end,
        },
        ["lvim-dependencies.core.hub.installed"] = {
            get_package_installed = function(_, _, cb)
                cb(nil, nil)
            end,
        },
        ["lvim-dependencies.core.hub.latest"] = hub_latest,
    }

    local saved = {}
    for name, stub in pairs(names) do
        saved[name] = package.loaded[name]
        package.loaded[name] = stub
    end
    local saved_loader = package.loaded["lvim-dependencies.core.package_loader"]
    package.loaded["lvim-dependencies.core.package_loader"] = nil

    local ok, err = pcall(fn, require("lvim-dependencies.core.package_loader"))

    package.loaded["lvim-dependencies.core.package_loader"] = saved_loader
    for name in pairs(names) do
        package.loaded[name] = saved[name]
    end
    if not ok then
        error(err, 0)
    end
end

--- Load one package through the loader and return its result plus the names asked of the registry.
---@param declared table  the declared record for "pkg"
---@return table result, string[] asked
local function load(declared)
    local asked, result = {}, nil
    with_hubs({
        get_package_latest = function(_, name, cb)
            asked[#asked + 1] = name
            cb(nil, { version = "9.9.9", metadata = {} })
        end,
    }, { pkg = declared }, function(loader)
        loader.load_package_data_async("cargo", "pkg", function(res)
            result = res
        end)
        vim.wait(2000, function()
            return result ~= nil
        end)
    end)
    truthy(result, "the load finished")
    return result, asked
end

it("asks for a crate that comes from the registry", function()
    local result, asked = load({ name = "pkg", type = "registry", declared = "1.0" })
    eq({ "pkg" }, asked)
    eq("9.9.9", result.latest.version)
end)

it("does not ask for a path dependency — crates.io has never heard of it", function()
    local result, asked = load({ name = "pkg", type = "path", path = { location = "crates/pkg" } })
    eq({}, asked)
    eq(nil, result.latest)
    eq(nil, result.latest_err, "and not asking is not an error")
end)

it("does not ask for a git dependency either", function()
    local _, asked = load({ name = "pkg", type = "git", git = { url = "https://example.com/pkg" } })
    eq({}, asked)
end)

describe("virtual text: a failed lookup does not erase what is already known")

local vt = require("lvim-dependencies.managers.cargo.virtual_text")

---@param record table
---@return string
local function text(record)
    local out = {}
    for _, chunk in ipairs(vt.format_package_chunks(record)) do
        out[#out + 1] = chunk[1]
    end
    return table.concat(out)
end

it("keeps the declared and installed versions when `latest` fails", function()
    local shown = text({
        package = "serde",
        declared = "1.0",
        declared_version = "1.0",
        installed = "1.0.210",
        latest_err = "curl failed with code 22",
    })
    truthy(shown:match("1%.0%.210"), "the installed version is still shown: " .. shown)
    truthy(not shown:match("curl failed"), "the error does not stand in its place: " .. shown)
end)

it("shows the error when that is genuinely all there is", function()
    local shown = text({ package = "serde", latest_err = "curl failed with code 22" })
    truthy(shown:match("curl failed"), "nothing else is known, so say what went wrong: " .. shown)
end)

it("renders a path dependency, which has neither an installed nor a latest version", function()
    -- Through the CORE, which is where the gate was: formatting was reached only when a record
    -- had an installed or a latest version, so a path dependency — which has neither, and is not
    -- an error either — left the line blank.
    local core_vt = require("lvim-dependencies.core.virtual_text")
    local declared = { name = "se-core", type = "path", path = { location = "crates/se-core" } }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "[workspace.dependencies]",
        'se-core = { path = "crates/se-core" }',
    })
    core_vt.virt_texts[buf] = { manifest_type = "cargo", declared = { ["se-core"] = declared } }
    core_vt.update_package(buf, { manifest = "cargo", package = "se-core", declared = declared })

    local marks = vim.api.nvim_buf_get_extmarks(buf, core_vt.namespace, 0, -1, { details = true })
    eq(1, #marks, "the line is marked")
    local shown = ""
    for _, chunk in ipairs(marks[1][4].virt_text or {}) do
        shown = shown .. chunk[1]
    end
    vim.api.nvim_buf_delete(buf, { force = true })

    truthy(shown:match("crates/se%-core"), "the path it points at is the whole truth: " .. shown)
end)

describe("pubspec: an SDK dependency")

it("carries the shape its own formatter reads", function()
    -- `flutter:` is short-circuited by NAME before the manifest's detector runs; the record it
    -- built put a bare string where sdk.format reads `dep.sdk.name`, and the line came out empty.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = assert(io.open(dir .. "/pubspec.yaml", "w"))
    file:write("name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n  http: ^1.2.0\n")
    file:close()

    require("lvim-dependencies.managers.pubspec.parser").clear_cache()
    local declared = require("lvim-dependencies.managers.pubspec.data.declared").get_data({ root = dir })
    truthy(declared.flutter, "the sdk dependency is declared")
    eq("sdk", declared.flutter.type)
    eq({ name = "flutter" }, declared.flutter.sdk)
end)
