-- lvim-dependencies.health: :checkhealth lvim-dependencies — Neovim version, the per-manager CLIs the plugin
-- shells out to (a missing one only disables THAT manager), curl for registry HTTP, and whether lvim-utils is
-- present for palette-driven theming (optional — it degrades to plain highlights without it).
--
---@module "lvim-dependencies.health"

local M = {}

--- The external CLIs each package manager needs; a manager is fully usable only when at least one of its
--- binaries is on PATH (npm accepts any of npm/yarn/pnpm).
---@type { manager: string, bins: string[] }[]
local MANAGER_BINS = {
    { manager = "npm (package.json)", bins = { "npm", "yarn", "pnpm" } },
    { manager = "cargo (Cargo.toml)", bins = { "cargo" } },
    { manager = "go (go.mod)", bins = { "go" } },
    { manager = "composer (composer.json)", bins = { "composer" } },
    { manager = "pub (pubspec.yaml)", bins = { "dart", "flutter" } },
}

--- Report whether any of `bins` resolves on PATH.
---@param bins string[]
---@return string|nil found
local function first_present(bins)
    for _, b in ipairs(bins) do
        if vim.fn.executable(b) == 1 then
            return b
        end
    end
    return nil
end

function M.check()
    local health = vim.health
    health.start("lvim-dependencies")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required")
    end

    -- Registry HTTP.
    if vim.fn.executable("curl") == 1 then
        health.ok("curl found (registry requests)")
    else
        health.error("curl not found — latest-version lookups will fail")
    end

    -- Per-manager CLIs (a missing one just disables that manager).
    health.start("package managers")
    for _, m in ipairs(MANAGER_BINS) do
        local bin = first_present(m.bins)
        if bin then
            health.ok(("%s — using `%s`"):format(m.manager, bin))
        else
            health.warn(
                ("%s — none of { %s } on PATH; this manager is disabled"):format(
                    m.manager,
                    table.concat(m.bins, ", ")
                )
            )
        end
    end

    -- Optional lvim-utils integration (palette-driven theming).
    health.start("integration")
    local ok_hl = pcall(require, "lvim-utils.highlight")
    local ok_colors = pcall(require, "lvim-utils.colors")
    if ok_hl and ok_colors then
        health.ok("lvim-utils found — highlights self-theme from the shared palette")
    else
        health.info("lvim-utils not found — using plain highlight groups (no palette sync)")
    end

    -- Config summary.
    local ok_cfg, config = pcall(require, "lvim-dependencies.config")
    if not ok_cfg then
        health.error("failed to load lvim-dependencies.config")
        return
    end
    local mgrs = config.managers or {}
    health.info(
        ("virtual_text=%s  lsp=%s  cache TTL declared/installed/latest=%s"):format(
            tostring((config.ui or {}).virtual_text ~= false),
            tostring((config.lsp or {}).enabled ~= false),
            tostring((config.cache or {}).ttl or "default")
        )
    )
    health.info(("managers configured: %d"):format(vim.tbl_count(mgrs)))
end

return M
