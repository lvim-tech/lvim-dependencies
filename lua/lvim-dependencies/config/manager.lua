-- lvim-dependencies.config.manager: the per-manager on/off switches. Every manager ships
-- enabled; setting one to false keeps its manifest out of the registry entirely, so that
-- ecosystem's files are no longer recognised, no virtual text is drawn for them and none of
-- its commands, LSP handlers or hover providers are loaded. Merged over by the user's opts
-- and read live by core.registry when it decides which backends to register.
--
-- A manager missing from this table counts as enabled: the flag is an opt-OUT.
---@module "lvim-dependencies.config.manager"

---@class LvimDependenciesManagerFlag
---@field enabled boolean

---@class LvimDependenciesManagers
---@field pubspec  LvimDependenciesManagerFlag
---@field cargo    LvimDependenciesManagerFlag
---@field npm      LvimDependenciesManagerFlag
---@field composer LvimDependenciesManagerFlag
---@field go       LvimDependenciesManagerFlag
return {
    pubspec = {
        enabled = true,
    },
    cargo = {
        enabled = true,
    },
    npm = {
        enabled = true,
    },
    composer = {
        enabled = true,
    },
    go = {
        enabled = true,
    },
}
