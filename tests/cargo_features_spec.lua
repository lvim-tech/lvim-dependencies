-- Choosing features must change the features. The line used to be rebuilt from version, features,
-- default-features and optional, so anything else on it (path, package, registry, workspace)
-- was silently dropped, and a sub-project's manifest was read from the cwd instead of its buffer.

local features = require("lvim-dependencies.managers.cargo.features")

describe("cargo features: only the chosen keys change")

local function edit(line, opts)
    return features.edit_dependency_block(type(line) == "table" and line or { line }, opts)
end

it("keeps every other key as written", function()
    eq(
        'foo = { version = "1", package = "bar", registry = "corp", features = ["a", "b"] }',
        edit('foo = { version = "1", package = "bar", registry = "corp" }', { features = { "b", "a" } })
    )
end)

it("works on a dependency with no version", function()
    eq('foo = { workspace = true, features = ["a"] }', edit("foo = { workspace = true }", { features = { "a" } }))
    eq(
        'foo = { path = "../foo", default-features = false }',
        edit('foo = { path = "../foo" }', { default_features = false })
    )
end)

it("turns a plain version into a table and back", function()
    eq('foo = { version = "1", features = ["a"] }', edit('foo = "1"', { features = { "a" } }))
    eq('foo = "1"', edit('foo = { version = "1", features = ["a"] }', { features = {} }))
end)

it("removes what is switched off, in either spelling", function()
    eq(
        'foo = { version = "1", package = "bar" }',
        edit(
            'foo = { version = "1", default_features = false, package = "bar", optional = true }',
            { default_features = true, optional = false }
        )
    )
end)

it("leaves unchanged features exactly as written", function()
    local line = 'foo = { features = ["b", "a"], version = "1" }'
    eq(line, edit(line, { features = { "a", "b" } }))
end)

it("keeps the indent, a trailing comment and commas inside strings", function()
    eq(
        '  foo = { git = "https://x/a,b}", optional = true } # why',
        edit('  foo = { git = "https://x/a,b}" } # why', { optional = true })
    )
end)

it("folds a multi-line array", function()
    eq(
        'foo = { version = "1", features = [ "a", ], optional = true }',
        edit({ 'foo = { version = "1", features = [', '    "a",', "] }" }, { optional = true })
    )
end)

it("refuses what it cannot read rather than guess", function()
    eq(nil, edit({ 'foo = { version = "1", features = [' }, { optional = true }), "unterminated")
    eq(nil, edit({ 'foo = { features = [ # c', '  "a" ] }' }, { optional = true }), "comment inside")
    eq(nil, edit("foo = 1", { optional = true }), "not a dependency value")
end)

describe("cargo features: the manifest is the buffer's, not the cwd's")

it("reads and edits a sub-project's Cargo.toml", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/Cargo.toml"
    vim.fn.writefile({ "[workspace.dependencies]", 'foo = { version = "1", features = ["old"], package = "bar" }' }, path)
    vim.cmd.edit(path)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.cmd.enew() -- a picker or any other window may be current by now

    eq({ "old" }, features.get_current_features("foo", bufnr).features)
    local ok, message
    features.update_features("foo", { features = { "new" }, bufnr = bufnr }, function(o, m)
        ok, message = o, m
    end)
    truthy(ok, message)
    eq('foo = { version = "1", features = ["new"], package = "bar" }', vim.fn.readfile(path)[2])
    eq(vim.fn.readfile(path), vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "the buffer follows")
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)

describe("project: no buffer named means the manifest being edited, for every manager")

it("search_root follows the current manifest, and only then the cwd", function()
    local project = require("lvim-dependencies.core.project")
    local registry = require("lvim-dependencies.core.registry")
    local real = registry.determine_manifest_type
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd.edit(dir .. "/manifest")
    local buf = vim.api.nvim_get_current_buf()
    local ok, err = pcall(function()
        for _, manager in ipairs({ "cargo", "npm", "go", "composer", "pubspec" }) do
            registry.determine_manifest_type = function()
                return manager
            end
            eq(vim.fs.dirname(vim.api.nvim_buf_get_name(buf)), project.search_root(manager), manager)
            registry.determine_manifest_type = function()
                return "other"
            end
            eq(vim.fn.getcwd(), project.search_root(manager), manager .. " in a foreign buffer")
        end
    end)
    registry.determine_manifest_type = real
    vim.cmd("bwipeout! " .. buf)
    truthy(ok, err)
end)

describe("a package declared twice: the declaration under the cursor is the one meant")

--- Open `content` as `file` in a fresh directory, with the cursor on the line matching `at`.
local function open_manifest(file, content, at)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. file
    vim.fn.writefile(content, path)
    vim.cmd.edit(path)
    for i, line in ipairs(content) do
        if at and line:match(at) then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
        end
    end
    return path, vim.api.nvim_get_current_buf()
end

local TWICE = {
    "[dependencies]",
    'foo = { version = "1", features = ["prod"] }',
    "",
    "[dev-dependencies]",
    'foo = { version = "1", features = ["test"] }',
    'other = "2"',
}

it("cargo: reads and writes the dev declaration when the cursor is on it", function()
    local path, bufnr = open_manifest("Cargo.toml", TWICE, "test")
    eq({ "test" }, features.get_current_features("foo", bufnr).features)
    local ok, message
    features.update_features("foo", { features = { "new" }, bufnr = bufnr }, function(o, m)
        ok, message = o, m
    end)
    truthy(ok, message)
    local lines = vim.fn.readfile(path)
    eq(TWICE[2], lines[2], "the other declaration is untouched")
    eq('foo = { version = "1", features = ["new"] }', lines[5])
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("cargo: the cursor elsewhere means the first declaration", function()
    local _, bufnr = open_manifest("Cargo.toml", TWICE, "other")
    eq({ "prod" }, features.get_current_features("foo", bufnr).features)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("cargo: the section survives a picker being current", function()
    local path, bufnr = open_manifest("Cargo.toml", TWICE, "test")
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 5,
        height = 1,
    })
    local helpers = require("lvim-dependencies.managers.cargo.utils.helpers")
    eq("dev-dependencies", helpers.find_package_section("foo", path))
    vim.api.nvim_win_close(float, true)
    vim.cmd("bwipeout! " .. bufnr)
end)

for _, case in ipairs({
    { "npm", "package.json", "dependencies", "devDependencies" },
    { "composer", "composer.json", "require", "require-dev" },
}) do
    it(case[1] .. ": finds the section under the cursor", function()
        local helpers = require("lvim-dependencies.managers." .. case[1] .. ".utils.helpers")
        local content = {
            "{",
            '  "' .. case[3] .. '": {',
            '    "foo": "1"',
            "  },",
            '  "' .. case[4] .. '": {',
            '    "foo": "2"',
            "  }",
            "}",
        }
        local path, bufnr = open_manifest(case[2], content, '"foo": "2"')
        eq(case[4], helpers.find_package_section("foo", path))
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        eq(case[3], helpers.find_package_section("foo", path), "cursor elsewhere")
        vim.cmd("bwipeout! " .. bufnr)
    end)
end

it("pubspec: finds the section under the cursor", function()
    local helpers = require("lvim-dependencies.managers.pubspec.utils.helpers")
    local path, bufnr = open_manifest(
        "pubspec.yaml",
        { "name: x", "dependencies:", "  foo: ^1.0.0", "dev_dependencies:", "  foo: ^2.0.0" },
        "foo: ^2"
    )
    eq("dev_dependencies", helpers.find_package_section("foo", path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq("dependencies", helpers.find_package_section("foo", path), "cursor elsewhere")
    vim.cmd("bwipeout! " .. bufnr)
end)

describe("cargo: a dependency in a table of its own")

local TABLE = {
    "[dependencies]",
    'plain = "1"',
    "",
    "[dependencies.foo]",
    'version = "1" # pinned',
    'package = "bar"',
    'features = ["a"]',
    "",
    "[target.'cfg(unix)'.dev-dependencies.baz]",
    'version = "3"',
}

local toml = require("lvim-dependencies.managers.cargo.core.toml_ops")
local cargo_helpers = require("lvim-dependencies.managers.cargo.utils.helpers")

it("is recognised, and lookalikes are not", function()
    eq("foo", toml.package_from_header("[dependencies.foo]"))
    eq("baz", toml.package_from_header("[target.'cfg(unix)'.dev-dependencies.baz]"))
    eq("q", toml.package_from_header("[workspace.dependencies.q]"))
    eq(nil, toml.package_from_header("[package.metadata.dependencies.foo]"))
    eq(nil, toml.package_from_header("[profile.dev]"))
    eq(nil, toml.package_from_header("[dependencies]"))
end)

it("gives the sections a file without a bare header declares in", function()
    eq({ "dependencies" }, cargo_helpers.find_dependency_headers({ "[dependencies.foo]", 'version = "1"' }))
    eq(
        { "dependencies", "target.'cfg(unix)'.dev-dependencies" },
        cargo_helpers.find_dependency_headers(TABLE)
    )
end)

it("is located without its trailing blank line", function()
    local first, last, form = toml.locate_package(TABLE, "dependencies", "foo")
    eq({ 4, 7, "table" }, { first, last, form })
end)

it("features: changes only the chosen keys, on their own lines", function()
    local path, bufnr = open_manifest("Cargo.toml", TABLE, "package")
    eq({ "a" }, features.get_current_features("foo", bufnr).features)
    eq("1", features.get_current_features("foo", bufnr).version)
    local ok, message
    features.update_features("foo", { features = { "b" }, optional = true, bufnr = bufnr }, function(o, m)
        ok, message = o, m
    end)
    truthy(ok, message)
    eq({
        "[dependencies.foo]",
        'version = "1" # pinned',
        'package = "bar"',
        'features = ["b"]',
        "optional = true",
    }, vim.list_slice(vim.fn.readfile(path), 4, 8))
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("features: removes a key and folds a multi-line array it changes", function()
    eq(
        { "[dependencies.foo]", 'version = "1"', 'features = ["z"]' },
        features.edit_dependency_table(
            { "[dependencies.foo]", 'version = "1"', "features = [", '  "a", # c', "]", "optional = true" },
            { features = { "z" }, optional = false }
        )
    )
    eq(nil, features.edit_dependency_table({ "[dependencies.foo]", "features = [" }, { optional = true }))
end)

it("update: changes the version in place instead of adding a second declaration", function()
    local path, bufnr = open_manifest("Cargo.toml", TABLE, "package")
    local api = require("lvim-dependencies.managers.cargo.api")
    local result
    api.update_async("foo", { version = "9" }, function(r)
        result = r
    end)
    vim.wait(2000, function()
        return result ~= nil
    end)
    truthy(result and result.success, vim.inspect(result))
    local lines = vim.fn.readfile(path)
    eq('version = "9" # pinned', lines[5])
    eq(#TABLE, #lines, "nothing was added")
    eq('plain = "1"', lines[2])
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("update: refuses a git or path table", function()
    local _, bufnr = open_manifest("Cargo.toml", { "[dependencies.foo]", 'path = "../foo"' }, "path")
    local api = require("lvim-dependencies.managers.cargo.api")
    local result
    api.update_async("foo", { version = "9" }, function(r)
        result = r
    end)
    vim.wait(1000, function()
        return result ~= nil
    end)
    eq(false, result and result.success)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("delete: removes the whole table", function()
    local path, bufnr = open_manifest("Cargo.toml", TABLE, "package")
    local api = require("lvim-dependencies.managers.cargo.api")
    local result
    api._delete_package("foo", {}, function(r)
        result = r
    end)
    vim.wait(2000, function()
        return result ~= nil
    end)
    truthy(result and result.success, vim.inspect(result))
    eq({
        "[dependencies]",
        'plain = "1"',
        "",
        "[target.'cfg(unix)'.dev-dependencies.baz]",
        'version = "3"',
    }, vim.fn.readfile(path))
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("the virtual text anchors on the header", function()
    local vt = require("lvim-dependencies.managers.cargo.virtual_text")
    local _, bufnr = open_manifest("Cargo.toml", TABLE, "plain")
    eq(3, vt.find_package_line(bufnr, "foo"))
    eq("foo", vt.find_package_in_line("[dependencies.foo]"))
    vim.cmd("bwipeout! " .. bufnr)
end)

it("delete from the UI: takes one declaration and brings the lock file along", function()
    if vim.fn.executable("cargo") == 0 then
        skip("delete from the UI", "cargo is not installed")
        return
    end
    local real_home = vim.env.CARGO_HOME
    vim.env.CARGO_HOME = vim.fn.tempname()
    local path, bufnr = open_manifest("Cargo.toml", {
        "[package]",
        'name = "x"',
        'version = "0.1.0"',
        'edition = "2021"',
        "",
        "[lib]",
        'path = "lib.rs"',
        "",
        "[dependencies]",
        'foo = { path = "foo" }',
        "",
        "[dev-dependencies]",
        'foo = { path = "foo" }',
    }, "XX")
    vim.api.nvim_win_set_cursor(0, { 13, 0 })
    local dir = vim.fs.dirname(path)
    vim.fn.writefile({}, dir .. "/lib.rs")
    vim.fn.mkdir(dir .. "/foo/src", "p")
    vim.fn.writefile({}, dir .. "/foo/src/lib.rs")
    vim.fn.writefile({ "[package]", 'name = "foo"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/foo/Cargo.toml")
    local result
    require("lvim-dependencies.managers.cargo.api")._delete_package("foo", { from_ui = true }, function(r)
        result = r
    end)
    vim.wait(30000, function()
        return result ~= nil
    end)
    vim.env.CARGO_HOME = real_home
    truthy(result and result.success, vim.inspect(result))
    local lines = vim.fn.readfile(path)
    eq('foo = { path = "foo" }', lines[10], "the other declaration stays")
    eq("[dev-dependencies]", lines[12])
    eq(12, #lines)
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)

it("pubspec delete from the UI: takes one declaration", function()
    if vim.fn.executable("dart") == 0 then
        skip("pubspec delete from the UI", "dart is not installed")
        return
    end
    local real_home, real_cache = vim.env.HOME, vim.env.PUB_CACHE
    vim.env.HOME, vim.env.PUB_CACHE = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.mkdir(vim.env.HOME, "p")
    local env = { "environment:", '  sdk: ">=3.0.0 <4.0.0"' }
    local path, bufnr = open_manifest("pubspec.yaml", {
        "name: x",
        env[1],
        env[2],
        "dependencies:",
        "  foo:",
        "    path: foo",
        "dev_dependencies:",
        "  foo:",
        "    path: foo",
    }, "XX")
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    local dir = vim.fs.dirname(path)
    vim.fn.mkdir(dir .. "/foo", "p")
    vim.fn.writefile({ "name: foo", env[1], env[2] }, dir .. "/foo/pubspec.yaml")
    local result
    require("lvim-dependencies.managers.pubspec.api")._delete_package("foo", { from_ui = true }, function(r)
        result = r
    end)
    vim.wait(30000, function()
        return result ~= nil
    end)
    vim.env.HOME, vim.env.PUB_CACHE = real_home, real_cache
    truthy(result and result.success, vim.inspect(result))
    local lines = vim.fn.readfile(path)
    eq({ "dependencies:", "  foo:", "    path: foo" }, vim.list_slice(lines, 4, 6), "the other declaration stays")
    eq(nil, table.concat(lines, "\n"):match("dev_dependencies:%s*\n%s*foo"), "the dev one is gone")
    vim.wait(100)
    vim.cmd("bwipeout! " .. bufnr)
end)
