-- lvim-dependencies.health: :checkhealth lvim-dependencies — Neovim version, the required lvim-utils / lvim-ui
-- companions, curl for registry HTTP, the per-manager CLIs the plugin shells out to (a missing one only breaks
-- that manager's install / update / delete commands — recognition, virtual text and lookups keep working), and a
-- summary of the effective config.
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

    -- Per-manager CLIs. The plugin recognises the manifest, draws virtual text and looks up
    -- versions without them; only that manager's install / update / delete commands need the CLI.
    health.start("package managers")
    for _, m in ipairs(MANAGER_BINS) do
        local bin = first_present(m.bins)
        if bin then
            health.ok(("%s — using `%s`"):format(m.manager, bin))
        else
            health.warn(
                ("%s — none of { %s } on PATH; install / update / delete for this manager will fail (virtual text and lookups still work)"):format(
                    m.manager,
                    table.concat(m.bins, ", ")
                )
            )
        end
    end

    -- Required companions: the highlight and cursor helpers come from lvim-utils and every
    -- picker / info panel from lvim-ui — the plugin does not load without them.
    health.start("integration")
    local ok_hl = pcall(require, "lvim-utils.highlight")
    local ok_colors = pcall(require, "lvim-utils.colors")
    if ok_hl and ok_colors then
        health.ok("lvim-utils found — highlights self-theme from the shared palette")
    else
        health.error("lvim-utils not found — required (palette, highlights, dock); the plugin cannot load")
    end
    if pcall(require, "lvim-ui") then
        health.ok("lvim-ui found — pickers and the info panel")
    else
        health.error("lvim-ui not found — required (version picker, prompts, info panel)")
    end

    -- Config summary.
    local ok_cfg, config = pcall(require, "lvim-dependencies.config")
    if not ok_cfg then
        health.error("failed to load lvim-dependencies.config")
        return
    end
    local lsp = config.lsp or {}
    local ttl = (config.cache or {}).ttl or {}
    health.info(
        ("lsp=%s (hover=%s, actions=%s)  virtual text position=%s  cache TTL installed/latest=%s/%s s"):format(
            tostring(lsp.enabled ~= false),
            tostring(lsp.hover ~= false),
            tostring(lsp.actions ~= false),
            tostring(((config.ui or {}).virtual_text or {}).position or "eol"),
            tostring(ttl.installed or "none"),
            tostring(ttl.latest or "none")
        )
    )
    local enabled, disabled = {}, {}
    for name, flag in pairs(config.managers or {}) do
        if type(flag) == "table" and flag.enabled == false then
            disabled[#disabled + 1] = name
        else
            enabled[#enabled + 1] = name
        end
    end
    table.sort(enabled)
    table.sort(disabled)
    health.info(("managers enabled: %s"):format(table.concat(enabled, ", ")))
    if #disabled > 0 then
        health.info(("managers disabled in config: %s"):format(table.concat(disabled, ", ")))
    end
end

return M
