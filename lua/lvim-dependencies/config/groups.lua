-- lvim-dependencies.config.groups: the single source of truth mapping each logical UI role
-- (separator, version states, panel chrome, …) to its highlight-group NAME. Both the
-- highlight builder and the render code look names up here, so a rename stays consistent.
---@module "lvim-dependencies.config.groups"

--- Logical UI role → highlight-group NAME. The fields below (`error`, `comment`,
--- `latest`, `sdk`) are OPTIONAL, dedicated highlight groups a theme may define; when
--- absent the render code falls back to a builtin group (`Comment`/`Error`/`Special`),
--- so they are read with an `or "<builtin>"` guard and never assigned in the default table.
---@class LvimDependenciesGroups
---@field error? string Highlight group for error indicators (falls back to `Error`/`Comment`)
---@field comment? string Highlight group for muted/placeholder text (falls back to `Comment`)
---@field latest? string Highlight group for the latest-version chunk (falls back to `Special`)
---@field sdk? string Highlight group for SDK dependency markers (pubspec)
return {
    separator = "LvimDepsSeparator",

    declared = "LvimDepsDeclaredVersion",
    installed = "LvimDepsInstalledVersion",
    up_to_date = "LvimDepsUpToDateVersion",
    outdated = "LvimDepsOutdatedVersion",

    loading = "LvimDepsLoading",
    working = "LvimDepsWorking",

    normal = "LvimDepsNormal",
    cursor_line = "LvimDepsCursorLine",
    border = "LvimDepsBorder",
    title = "LvimDepsTitle",
    sub_title = "LvimDepsSubTitle",
    subject = "LvimDepsSubject",
    info = "LvimDepsInfo",
    line_active = "LvimDepsLineActive",
    line_inactive = "LvimDepsLineInactive",
    navigation = "LvimDepsNavigation",
    input = "LvimDepsInsert",
}
