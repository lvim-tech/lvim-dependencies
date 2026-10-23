-- Where cargo declares its dependencies.
--
-- The parser read `[dependencies]`, `[dev-dependencies]` and `[build-dependencies]` and nothing
-- else, so a workspace root — which keeps the shared set under `[workspace.dependencies]` and
-- often has no `[dependencies]` at all — parsed as a manifest with NO dependencies, and not one
-- line of it ever got virtual text. Platform dependencies (`[target.'cfg(unix)'.dependencies]`)
-- were invisible for the same reason.
--
-- The line editor has the mirror question: which header does a crate live under? Answering it
-- with the three bare names made `update` create a `[dependencies]` section in a virtual
-- workspace manifest and write the crate there, beside the real declaration, where cargo does
-- not read it.

local parser = require("lvim-dependencies.managers.cargo.parser")
local helpers = require("lvim-dependencies.managers.cargo.utils.helpers")

--- Write `content` as Cargo.toml in a fresh directory and return that directory.
---@param content string
---@return string
local function manifest_dir(content)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = assert(io.open(dir .. "/Cargo.toml", "w"))
    file:write(content)
    file:close()
    return dir
end

---@param content string
---@return table<string, any>
local function parse(content)
    parser.clear_cache()
    return parser.get_dependencies({ root = manifest_dir(content) })
end

---@param deps table<string, any>
---@return string[]
local function names(deps)
    local out = vim.tbl_keys(deps)
    table.sort(out)
    return out
end

describe("cargo parser: every place a dependency is declared")

it("reads the three top-level sections", function()
    local deps = parse([[
[package]
name = "demo"

[dependencies]
serde = "1.0"

[dev-dependencies]
tempfile = "3"

[build-dependencies]
cc = "1"
]])
    eq({ "cc", "serde", "tempfile" }, names(deps))
    eq("1.0", deps.serde)
end)

it("reads a workspace root, which has no [dependencies] at all", function()
    -- The reported manifest's shape: a virtual root that declares the shared set for its members.
    local deps = parse([[
[workspace]
resolver = "3"
members = ["crates/*"]

[workspace.package]
version = "0.1.0"

[workspace.dependencies]
se-core = { path = "crates/se-core" }
tonic = { version = "0.14", features = ["transport"] }
prost = "0.14"
]])
    eq({ "prost", "se-core", "tonic" }, names(deps))
    eq("0.14", deps.prost, "the version, not the whole inline table")
    eq("crates/se-core", deps["se-core"].path)
end)

it("reads the per-target sections", function()
    local deps = parse([[
[dependencies]
serde = "1.0"

[target.'cfg(unix)'.dependencies]
nix = "0.29"

[target.'cfg(windows)'.dev-dependencies]
winapi = "0.3"
]])
    eq({ "nix", "serde", "winapi" }, names(deps))
end)

it("still skips the manifest's non-dependency keys", function()
    local deps = parse([[
[workspace.dependencies]
serde = "1.0"
]])
    eq({ "serde" }, names(deps))
end)

describe("cargo helpers: the dependency headers a FILE actually has")

it("names the plain sections of an ordinary manifest, in file order", function()
    eq(
        { "dependencies", "dev-dependencies" },
        helpers.find_dependency_headers({
            "[package]",
            'name = "demo"',
            "[dependencies]",
            'serde = "1.0"',
            "[dev-dependencies]",
            'tempfile = "3"',
        })
    )
end)

it("names a workspace root's section, which is the only one it has", function()
    eq(
        { "workspace.dependencies" },
        helpers.find_dependency_headers({
            "[workspace]",
            'members = ["crates/*"]',
            "[workspace.package]",
            'version = "0.1.0"',
            "[workspace.dependencies]",
            'prost = "0.14"',
        })
    )
end)

it("names a target section by its full header", function()
    -- The kind is the trailing dotted component; the cfg in the middle is part of the name and
    -- is kept verbatim, because that is the string the line editor has to match again.
    eq(
        { "dependencies", "target.'cfg(unix)'.dev-dependencies" },
        helpers.find_dependency_headers({
            "[dependencies]",
            'serde = "1.0"',
            "[target.'cfg(unix)'.dev-dependencies]",
            'nix = "0.29"',
        })
    )
end)

it("does not mistake [package] or a lock file's [[package]] for one", function()
    eq(
        { "dependencies" },
        helpers.find_dependency_headers({
            "[package]",
            'name = "demo"',
            "[[package]]",
            "[features]",
            "[dependencies]",
        })
    )
end)

it("falls back to the bare names for a manifest that declares nothing yet", function()
    -- A new crate has no dependency section; `add` must still know which one to create.
    eq(
        { "dependencies", "dev-dependencies", "build-dependencies" },
        helpers.find_dependency_headers({
            "[package]",
            'name = "demo"',
        })
    )
end)
