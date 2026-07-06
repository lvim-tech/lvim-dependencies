-- lvim-dependencies.config.dock: dock-stack integration settings for the plugin's info panel — the
-- registry / manager / cache / state / metrics viewer (`ui.open`). NAMESPACED under `dock` on purpose:
-- the top-level `config.force` is ALREADY the highlight-override flag, so the shared dock-rollout block
-- keeps its field NAMES (`dock_stack`, `force`) here to stay uniform with every other lvim-tech plugin
-- without colliding with the highlight `force`. The info viewer is inherently a centred FLOAT, so
-- `force.float` is the operative override; `area` / `bottom` are carried only for the uniform shape.
---@module "lvim-dependencies.config.dock"

---@class LvimDependenciesDockConfig
---@field dock_stack boolean                                          Join the managed dock stack vs open standalone.
---@field force      table<"float"|"area"|"bottom", table>            Per-layout anchored geometry overrides.
return {
    -- true = full dock-STACK consumer (managed: cyclable <Leader>n/p/x/m, :LvimDock,
    -- one-visible-per-layout, no overlap); false = geometry-only (central dock.slot size/
    -- backdrop, opens standalone, NOT in the stack).
    dock_stack = true,
    -- Per-plugin per-layout ANCHORED geometry overrides, deep-merged per field OVER the global
    -- `lvim-utils.config.dock.geometry.<layout>`; empty {} = inherit the global unchanged. Each
    -- layout may carry: height, height_auto, backdrop = { enabled, mode, dim = { amount },
    -- darken = { amount } }, auto_hide, keep_focus. FLOAT ALSO: width, width_auto. area/bottom
    -- are ALWAYS full-width — NO width/width_auto (ignored if set).
    force = { float = {}, area = {}, bottom = {} },
}
