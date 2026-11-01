-- A declaration is what its brackets say, not what a formatter's line breaks suggest. Each manager
-- used to decide by indent or by the end of the line, so a value split over lines was cut short:
-- what lay beyond the cut was not read, and an edit left it behind as a broken file.

local function buffer(file, content, row)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. file
    vim.fn.writefile(content, path)
    vim.cmd.edit(path)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return path, vim.api.nvim_get_current_buf()
end

local function await(call)
    local result
    call(function(r)
        result = r
    end)
    vim.wait(2000, function()
        return result ~= nil
    end, 10)
    return result
end

--- First and last line of a block, without the line itself.
local function span(first, last)
    return { first, last }
end

local function close(bufnr)
    vim.wait(50)
    vim.cmd("bwipeout! " .. bufnr)
end

for _, mgr in ipairs({ "npm", "composer" }) do
    local json = require("lvim-dependencies.managers." .. mgr .. ".core.json_ops")

    describe(mgr .. ": a value split over lines")

    local SPLIT = {
        "{",
        '  "SECTION": {',
        '    "split":',
        '      "1.0.0",',
        '    "allman":',
        "    {",
        '      "version": "1"',
        "    },",
        '    "brace": "it\'s {",',
        '    "last": "2"',
        "  }",
        "}",
    }

    it("is one block, whatever the formatter did", function()
        local e = #SPLIT - 1
        eq({ 3, 4 }, span(json.find_package_block(SPLIT, 2, e, "split")), "next line")
        eq({ 5, 8 }, span(json.find_package_block(SPLIT, 2, e, "allman")), "brace on the next line")
        eq({ 9, 9 }, span(json.find_package_block(SPLIT, 2, e, "brace")), "a bracket inside a string")
        eq({ 10, 10 }, span(json.find_package_block(SPLIT, 2, e, "last")))
    end)

    it("is replaced and removed whole, keeping the comma", function()
        local e = #SPLIT - 1
        local out = json.replace_package_in_section(SPLIT, 2, e, "split", json.format_package_line("split", "3"))
        eq('    "split": "3",', out[3])
        eq('    "allman":', out[4])
        out = json.remove_package_from_section(SPLIT, 2, e, "allman")
        eq('      "1.0.0",', out[4])
        eq('    "brace": "it\'s {",', out[5])
    end)
end

describe("composer: a section on one line")

it("refuses rather than write a second declaration", function()
    local path, bufnr = buffer("composer.json", { "{", '  "require": { "t/foo": "1" }', "}" }, 2)
    local before = vim.fn.readfile(path)
    local result = await(function(done)
        require("lvim-dependencies.managers.composer.api").update_async("t/foo", { version = "2" }, done)
    end)
    eq(false, result and result.success)
    eq(before, vim.fn.readfile(path))
    close(bufnr)
end)

describe("npm: a virtual text constraint split over lines")

it("is read from the value's own line", function()
    local vt = require("lvim-dependencies.managers.npm.virtual_text")
    local found = vt.find_declarations({
        "{",
        '  "dependencies": {',
        '    "foo":',
        '      "1.0.0"',
        "  },",
        '  "devDependencies": {',
        '    "foo": "2"',
        "  }",
        "}",
    }, "foo")
    eq({ { line = 2, declared = "1.0.0" }, { line = 6, declared = "2" } }, found)
end)

describe("pubspec: a block with comments, blanks and flow values")

local yaml = require("lvim-dependencies.managers.pubspec.core.yaml_ops")

local PUBSPEC = {
    "name: x",
    "dependencies:",
    "  gitdep:",
    "    # pinned for a reason",
    "",
    "    git: https://example.com/a",
    "# a comment at column 0",
    "  flow: {",
    "    path: ../flow",
    "  }",
    "  zero: {",
    "    path: ../zero",
    "}",
    "  plain: ^1.0.0",
    "",
    "# about flutter",
    "flutter:",
    "  uses-material-design: true",
}

it("does not end the section at a comment or a closing bracket", function()
    eq(14, yaml.find_section_end(PUBSPEC, 2))
end)

it("is one block", function()
    local e = yaml.find_section_end(PUBSPEC, 2)
    eq({ 3, 6 }, span(yaml.find_package_block(PUBSPEC, 2, e, "gitdep")), "across a comment and a blank")
    eq({ 8, 10 }, span(yaml.find_package_block(PUBSPEC, 2, e, "flow")), "closing at the package's indent")
    eq({ 11, 13 }, span(yaml.find_package_block(PUBSPEC, 2, e, "zero")), "closing at column 0")
    eq({ 14, 14 }, span(yaml.find_package_block(PUBSPEC, 2, e, "plain")))
end)

it("is replaced and removed whole", function()
    local e = yaml.find_section_end(PUBSPEC, 2)
    local out = yaml.remove_package_from_section(PUBSPEC, 2, e, "zero")
    eq("  flow: {", out[8])
    eq("  plain: ^1.0.0", out[11])
    out = yaml.replace_package_in_section(PUBSPEC, 2, e, "flow", "  flow: ^2.0.0")
    eq("  flow: ^2.0.0", out[8])
    eq("  zero: {", out[9])
end)

it("finds a package below a comment at column 0, through the real update", function()
    local path, bufnr = buffer("pubspec.yaml", PUBSPEC, 14)
    local result = await(function(done)
        require("lvim-dependencies.managers.pubspec.api").update_async("plain", { version = "2.0.0" }, done)
    end)
    truthy(result and result.success, vim.inspect(result))
    local lines = vim.fn.readfile(path)
    eq(#PUBSPEC, #lines, "nothing was added")
    truthy(lines[14]:match("plain: .*2%.0%.0"), lines[14])
    close(bufnr)
end)

describe("cargo: the cursor inside a value split over lines")

it("answers with the package it belongs to", function()
    local _, bufnr = buffer("Cargo.toml", {
        "[workspace.dependencies]",
        'tonic = { version = "0.14", features = [',
        '    "transport",',
        "] }",
        'prost = "0.14"',
    }, 3)
    local api = require("lvim-dependencies.managers.cargo.api")
    eq("tonic", api.get_package_at_cursor({ bufnr = bufnr }))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq("tonic", api.get_package_at_cursor({ bufnr = bufnr }))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    eq("prost", api.get_package_at_cursor({ bufnr = bufnr }))
    close(bufnr)
end)

describe("go: what gofmt and go mod write")

it("is read in both require forms, with a tab and an indirect comment", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
        "module x",
        "",
        "require github.com/one/a v1.0.0",
        "",
        "require (",
        "\tgithub.com/two/b v2.0.0",
        "\tgithub.com/three/c v3.0.0 // indirect",
        ")",
    }, dir .. "/go.mod")
    local parser = require("lvim-dependencies.managers.go.parser")
    parser.clear_cache()
    local deps = parser.get_dependencies({ root = dir })
    eq("v1.0.0", deps["github.com/one/a"].version)
    eq("v2.0.0", deps["github.com/two/b"].version)
    eq(true, deps["github.com/three/c"].indirect)
    parser.clear_cache()
end)
