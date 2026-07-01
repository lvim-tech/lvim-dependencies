-- lvim-dependencies.config.manager: per-manager enable flags for the managers that default
-- off elsewhere and are opted in here. Merged over by the user's opts and read live by the
-- manager registry when deciding which backends to activate.
---@module "lvim-dependencies.config.manager"

---@class LvimDependenciesManagers
return {
    pubspec = {
        enabled = true,
    },
    cargo = {
        enabled = true,
    },
}
