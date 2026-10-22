-- Comparing versions, which is where "is there an update?" is actually decided.
--
-- npm mixes prerelease and stable dist-tags, so there are deliberately TWO comparators and the
-- difference between them is the whole point: `compare` follows strict SemVer (a prerelease sorts
-- BELOW its release, which is what a constraint check needs), while `compare_numeric` ignores the
-- prerelease suffix (which is what "which published tag is newest by number" needs). The header
-- states both with examples; these are those examples, run.

local npm = require("lvim-dependencies.managers.npm.compare_versions")
local cargo = require("lvim-dependencies.managers.cargo.compare_versions")

describe("npm compare_versions.compare: strict SemVer")

it("orders by number, not by text", function()
    -- The classic: 1.10.0 is newer than 1.9.0, though "1.10.0" < "1.9.0" as strings.
    eq(1, npm.compare("1.10.0", "1.9.0"))
    eq(-1, npm.compare("1.9.0", "1.10.0"))
    eq(0, npm.compare("1.2.3", "1.2.3"))
end)

it("compares each component in turn", function()
    eq(1, npm.compare("2.0.0", "1.99.99"))
    eq(1, npm.compare("1.2.0", "1.1.99"))
    eq(1, npm.compare("1.2.4", "1.2.3"))
end)

it("sorts a prerelease BELOW its release", function()
    eq(-1, npm.compare("7.21.4-esm.4", "7.21.4"), "a prerelease is not the release")
end)

it("ignores a leading range operator or v", function()
    eq(0, npm.compare("^1.2.3", "1.2.3"))
    eq(0, npm.compare("~1.2.3", "1.2.3"))
    eq(0, npm.compare(">=1.2.3", "1.2.3"))
    eq(0, npm.compare("v1.2.3", "1.2.3"))
end)

it("treats a missing component as zero", function()
    eq(0, npm.compare("1.2", "1.2.0"))
    eq(0, npm.compare("1", "1.0.0"))
    eq(1, npm.compare("1.3", "1.2.9"))
end)

describe("npm compare_versions.compare_numeric: newest published tag")

it("counts a prerelease by its numbers", function()
    -- The header's example: 7.21.4-esm.4 IS newer than 7.18.6 by number.
    eq(1, npm.compare_numeric("7.21.4-esm.4", "7.18.6"))
    eq(0, npm.compare_numeric("7.21.4-esm.4", "7.21.4"), "same base, so the same")
end)

it("survives an absent side rather than erroring", function()
    local ok, err = pcall(npm.compare_numeric, nil, "1.0.0")
    truthy(ok, tostring(err))
    ok, err = pcall(npm.compare_numeric, "1.0.0", nil)
    truthy(ok, tostring(err))
end)

describe("npm compare_versions.parse")

it("breaks a version into its components", function()
    local p = npm.parse("1.2.3")
    truthy(p, "no parse for 1.2.3")
    eq(1, p.major)
    eq(2, p.minor)
    eq(3, p.patch)
end)

it("says nothing for something that is not a version", function()
    eq(nil, npm.parse("not-a-version"))
    eq(nil, npm.parse(""))
end)

describe("npm compare_versions.sort")

it("sorts ascending and descending by version, not by string", function()
    local list = { "1.9.0", "1.10.0", "1.2.0" }
    eq({ "1.2.0", "1.9.0", "1.10.0" }, npm.sort(vim.deepcopy(list)))
    eq({ "1.10.0", "1.9.0", "1.2.0" }, npm.sort_desc(vim.deepcopy(list)))
end)

it("finds the latest of a list", function()
    eq("1.10.0", npm.latest({ "1.9.0", "1.10.0", "1.2.0" }))
end)

describe("npm compare_versions.satisfies")

it("accepts a version inside a caret range and refuses one outside it", function()
    eq(true, npm.satisfies("1.2.5", "^1.2.3"), "a patch bump satisfies a caret")
    eq(true, npm.satisfies("1.3.0", "^1.2.3"), "a minor bump satisfies a caret")
    eq(false, npm.satisfies("2.0.0", "^1.2.3"), "a major bump does not")
end)

it("accepts a version inside a tilde range and refuses one outside it", function()
    eq(true, npm.satisfies("1.2.9", "~1.2.3"), "a patch bump satisfies a tilde")
    eq(false, npm.satisfies("1.3.0", "~1.2.3"), "a minor bump does not")
end)

describe("cargo compare_versions: the same questions, its own flavour")

it("orders by number", function()
    eq(1, cargo.compare("0.10.0", "0.9.0"))
    eq(0, cargo.compare("1.2.3", "1.2.3"))
end)

it("ignores a leading operator", function()
    eq(0, cargo.compare("^1.2.3", "1.2.3"))
    eq(0, cargo.compare("=1.2.3", "1.2.3"))
end)
