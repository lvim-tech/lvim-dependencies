-- A package declared in two sections, end to end: each manager's own update and delete, against
-- the real tool on a local package, and the virtual text. Quoted cargo names at the end.

local TOOL_ENV = { "HOME", "COMPOSER_HOME", "COMPOSER_DISABLE_NETWORK", "PUB_CACHE", "npm_config_cache", "CARGO_HOME" }

--- Run fn with every tool's home in a throwaway directory.
local function hermetic(fn)
    local saved = {}
    for _, key in ipairs(TOOL_ENV) do
        saved[key] = vim.env[key]
        vim.env[key] = vim.fn.tempname()
    end
    vim.fn.mkdir(vim.env.HOME, "p")
    vim.env.COMPOSER_DISABLE_NETWORK = "1"
    local ok, err = pcall(fn)
    for _, key in ipairs(TOOL_ENV) do
        vim.env[key] = saved[key]
    end
    if not ok then
        error(err, 0)
    end
end

local function open_manifest(file, content, row)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. file
    vim.fn.writefile(content, path)
    vim.cmd.edit(path)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return path, vim.api.nvim_get_current_buf(), dir
end

local function await(call)
    local result
    call(function(r)
        result = r
    end)
    vim.wait(60000, function()
        return result ~= nil
    end, 20)
    truthy(result and result.success, vim.inspect(result))
end

local function close(bufnr)
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end

local function decode(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

--- Answer every confirmation with yes, for the duration of fn.
local function confirmed(fn)
    local ui = require("lvim-dependencies.ui")
    local real = ui.select
    ui.select = function(_, _, _, _, callback)
        callback(true, 1)
    end
    local ok, err = pcall(fn)
    ui.select = real
    if not ok then
        error(err, 0)
    end
end

describe("npm: a package in two sections")

local NPM = {
    "{",
    '  "name": "x",',
    '  "version": "1.0.0",',
    '  "dependencies": {',
    '    "foo": "file:foo"',
    "  },",
    '  "devDependencies": {',
    '    "foo": "file:foo"',
    "  }",
    "}",
}

local function npm_project(row)
    local path, bufnr, dir = open_manifest("package.json", NPM, row)
    vim.fn.mkdir(dir .. "/foo", "p")
    vim.fn.writefile({ '{"name":"foo","version":"1.0.0"}' }, dir .. "/foo/package.json")
    vim.fn.mkdir(dir .. "/bar", "p")
    vim.fn.writefile({ '{"name":"foo","version":"1.0.0"}' }, dir .. "/bar/package.json")
    vim.fn.writefile({ "offline=true", "audit=false", "fund=false" }, dir .. "/.npmrc")
    return path, bufnr
end

it("update changes only the declaration under the cursor, and the other stays", function()
    if vim.fn.executable("npm") == 0 then
        return skip("npm update", "npm is not installed")
    end
    hermetic(function()
        local path, bufnr = npm_project(8)
        local api = require("lvim-dependencies.managers.npm.api")
        await(function(done)
            api.update_async("foo", { version = "file:bar", from_ui = true }, done)
        end)
        local data = decode(path)
        eq("file:foo", data.dependencies.foo)
        eq("file:bar", data.devDependencies.foo)
        close(bufnr)
    end)
end)

it("delete removes only the declaration under the cursor", function()
    if vim.fn.executable("npm") == 0 then
        return skip("npm delete", "npm is not installed")
    end
    hermetic(function()
        local path, bufnr, dir = npm_project(8)
        local api = require("lvim-dependencies.managers.npm.api")
        confirmed(function()
            await(function(done)
                api.delete("foo", { from_ui = true }, done)
            end)
        end)
        local data = decode(path)
        eq("file:foo", data.dependencies.foo)
        eq(nil, data.devDependencies and data.devDependencies.foo)
        truthy(vim.uv.fs_stat(vim.fs.dirname(path) .. "/package-lock.json"), "the lock file was written")
        local _ = dir
        close(bufnr)
    end)
end)

describe("composer: a package in two sections")

local function composer_project(row)
    local path, bufnr, dir = open_manifest("composer.json", {
        "{",
        '  "name": "t/x",',
        '  "minimum-stability": "dev",',
        '  "repositories": [{"packagist.org": false}, {"type": "path", "url": "foo", "options": {"symlink": false}}],',
        '  "require": {',
        '    "t/foo": "*"',
        "  },",
        '  "require-dev": {',
        '    "t/foo": "*"',
        "  }",
        "}",
    }, row)
    vim.fn.mkdir(dir .. "/foo", "p")
    vim.fn.writefile({ '{"name":"t/foo","version":"1.0.0"}' }, dir .. "/foo/composer.json")
    return path, bufnr
end

it("update changes only the declaration under the cursor", function()
    if vim.fn.executable("composer") == 0 then
        return skip("composer update", "composer is not installed")
    end
    hermetic(function()
        local path, bufnr = composer_project(9)
        local api = require("lvim-dependencies.managers.composer.api")
        await(function(done)
            api.update_async("t/foo", { version = "1.0.0", from_ui = true }, done)
        end)
        local data = decode(path)
        eq("*", data.require["t/foo"])
        eq("1.0.0", data["require-dev"]["t/foo"])
        truthy(vim.uv.fs_stat(vim.fs.dirname(path) .. "/composer.lock"), "the lock file was written")
        close(bufnr)
    end)
end)

it("update puts the manifest back when composer fails", function()
    if vim.fn.executable("composer") == 0 then
        return skip("composer rollback", "composer is not installed")
    end
    hermetic(function()
        local path, bufnr = composer_project(9)
        local before = vim.fn.readfile(path)
        local result
        require("lvim-dependencies.managers.composer.api").update_async(
            "t/foo",
            { version = "9.9.9", from_ui = true },
            function(r)
                result = r
            end
        )
        vim.wait(60000, function()
            return result ~= nil
        end, 20)
        eq(false, result and result.success)
        eq(before, vim.fn.readfile(path))
        close(bufnr)
    end)
end)

it("delete from the UI removes only the declaration under the cursor", function()
    if vim.fn.executable("composer") == 0 then
        return skip("composer delete", "composer is not installed")
    end
    hermetic(function()
        local path, bufnr = composer_project(6)
        await(function(done)
            require("lvim-dependencies.managers.composer.api")._delete_package("t/foo", { from_ui = true }, done)
        end)
        local data = decode(path)
        eq(nil, data.require and data.require["t/foo"])
        eq("*", data["require-dev"]["t/foo"])
        close(bufnr)
    end)
end)

it("the manifest-only paths edit the same declaration", function()
    local path, bufnr = composer_project(9)
    local api = require("lvim-dependencies.managers.composer.api")
    await(function(done)
        api.update_async("t/foo", { version = "2.0.0" }, done)
    end)
    eq("*", decode(path).require["t/foo"])
    eq("2.0.0", decode(path)["require-dev"]["t/foo"])
    await(function(done)
        api._delete_package("t/foo", {}, done)
    end)
    eq("*", decode(path).require["t/foo"])
    eq(nil, decode(path)["require-dev"] and decode(path)["require-dev"]["t/foo"])
    close(bufnr)
end)

describe("pubspec: the manifest paths and the commands")

local PUBSPEC = {
    "name: x",
    "dependencies:",
    "  foo: ^1.0.0",
    "dev_dependencies:",
    "  foo: ^2.0.0",
}

it("update and delete edit the declaration under the cursor", function()
    local path, bufnr = open_manifest("pubspec.yaml", PUBSPEC, 5)
    local api = require("lvim-dependencies.managers.pubspec.api")
    await(function(done)
        api.update_async("foo", { version = "3.0.0" }, done)
    end)
    local lines = vim.fn.readfile(path)
    eq("  foo: ^1.0.0", lines[3])
    truthy(lines[5]:match("3%.0%.0"), lines[5])
    await(function(done)
        api._delete_package("foo", {}, done)
    end)
    lines = vim.fn.readfile(path)
    eq("  foo: ^1.0.0", lines[3])
    eq("dev_dependencies:", lines[4])
    eq(4, #lines)
    close(bufnr)
end)

it("a Flutter project syncs with flutter pub get, and names no package", function()
    local pub_ops = require("lvim-dependencies.managers.pubspec.core.pub_ops")
    local path, bufnr = open_manifest("pubspec.yaml", {
        "name: x",
        "dependencies:",
        "  flutter:",
        "    sdk: flutter",
    }, 1)
    if vim.fn.executable("flutter") == 0 then
        close(bufnr)
        return skip("flutter command", "flutter is not installed")
    end
    local cmd = pub_ops.choose_pub_remove_cmd(path)
    eq({ "pub", "get" }, { cmd[2], cmd[3] })
    truthy(cmd[1]:match("flutter"), cmd[1])
    eq(3, #cmd)
    close(bufnr)
end)

describe("virtual text: each declaration on its own line")

--- The text painted on each line of a buffer.
local function painted(bufnr, vt)
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, vt.namespace, 0, -1, { details = true })) do
        local text = {}
        for _, chunk in ipairs(mark[4].virt_text) do
            text[#text + 1] = chunk[1]
        end
        out[mark[2]] = table.concat(text)
    end
    return out
end

for _, case in ipairs({
    { "cargo", "Cargo.toml", { "[dependencies]", 'foo = "1"', "[dev-dependencies.foo]", 'version = "2"' }, 1, 2 },
    { "npm", "package.json", {
        "{",
        '  "dependencies": {',
        '    "foo": "1"',
        "  },",
        '  "devDependencies": {',
        '    "foo": "2"',
        "  }",
        "}",
    }, 2, 5 },
    { "composer", "composer.json", {
        "{",
        '  "require": {',
        '    "t/foo": "1"',
        "  },",
        '  "require-dev": {',
        '    "t/foo": "2"',
        "  }",
        "}",
    }, 2, 5 },
    { "pubspec", "pubspec.yaml", { "dependencies:", "  foo: 1", "dev_dependencies:", "  foo: 2" }, 1, 3 },
}) do
    it(case[1] .. ": shows each line's own constraint, and clears both", function()
        local vt = require("lvim-dependencies.core.virtual_text")
        local _, bufnr = open_manifest(case[2], case[3], 1)
        local name = case[1] == "composer" and "t/foo" or "foo"
        vim.wait(50) -- a loading mark from the plugin's own open handler, when another spec set it up
        vt.virt_texts[bufnr] = vt.virt_texts[bufnr] or {}
        vt.clear_buffer(bufnr)
        vt.virt_texts[bufnr] = { manifest_type = case[1], declared = { [name] = "2" } }
        vt.update_package(bufnr, { package = name, declared = "2", installed = "1.5.0" })
        local text = painted(bufnr, vt)
        truthy(text[case[4]] and text[case[4]]:find("1", 1, true), vim.inspect(text))
        truthy(text[case[5]] and text[case[5]]:find("2", 1, true), vim.inspect(text))
        truthy(not text[case[4]]:find("2", 1, true), "the first line shows its own: " .. text[case[4]])
        vt.move_virt_texts_only(bufnr)
        eq(2, vim.tbl_count(painted(bufnr, vt)), "moving keeps one mark per line")
        vt.remove_package(bufnr, name)
        eq({}, painted(bufnr, vt), "removing clears both")
        vt.virt_texts[bufnr] = nil
        close(bufnr)
    end)
end

it("a package declared once is painted once", function()
    local vt = require("lvim-dependencies.core.virtual_text")
    local _, bufnr = open_manifest("Cargo.toml", { "[dependencies]", 'foo = "1"', "[features]", 'foo = ["dep:foo"]' }, 1)
    vim.wait(50)
    vt.virt_texts[bufnr] = vt.virt_texts[bufnr] or {}
    vt.clear_buffer(bufnr)
    vt.virt_texts[bufnr] = { manifest_type = "cargo", declared = { foo = "1" } }
    vt.update_package(bufnr, { package = "foo", declared = "1", installed = "1.5.0" })
    eq(1, vim.tbl_count(painted(bufnr, vt)), "a [features] key is not a declaration")
    vt.virt_texts[bufnr] = nil
    close(bufnr)
end)

describe("cargo: a quoted name")

local toml = require("lvim-dependencies.managers.cargo.core.toml_ops")

it("is found in a line and in a table header", function()
    eq("foo", toml.package_from_header('[dependencies."foo"]'))
    eq("foo", toml.package_from_header("[dependencies.'foo']"))
    eq({ 2, 2, "inline" }, { toml.locate_package({ "[dependencies]", '"foo" = "1"' }, "dependencies", "foo") })
    eq({ 1, 2, "table" }, { toml.locate_package({ '[dependencies."foo"]', 'version = "1"' }, "dependencies", "foo") })
    eq(
        { "dependencies" },
        require("lvim-dependencies.managers.cargo.utils.helpers").find_dependency_headers({ '[dependencies."foo"]' })
    )
end)

it("is edited with its quotes kept, by features and by update", function()
    local features = require("lvim-dependencies.managers.cargo.features")
    eq('"foo" = { version = "1", features = ["a"] }', features.edit_dependency_block({ '"foo" = "1"' }, { features = { "a" } }))
    local path, bufnr = open_manifest("Cargo.toml", { '[dependencies."foo"]', 'version = "1"' }, 2)
    await(function(done)
        require("lvim-dependencies.managers.cargo.api").update_async("foo", { version = "2" }, done)
    end)
    eq({ '[dependencies."foo"]', 'version = "2"' }, vim.fn.readfile(path))
    close(bufnr)
end)

it("is the package at the cursor, and its line", function()
    local _, bufnr = open_manifest("Cargo.toml", { '[dependencies."foo"]', 'version = "1"' }, 2)
    eq("foo", require("lvim-dependencies.managers.cargo.api").get_package_at_cursor({ bufnr = bufnr }))
    eq(0, require("lvim-dependencies.managers.cargo.virtual_text").find_package_line(bufnr, "foo"))
    close(bufnr)
end)
