-- lvim-dependencies.hooks.help: markdown help text builders for the :LvimDeps command.
-- Command metadata lives in the section/category/per-command tables at the top; the
-- builders render them into markdown tables (main/short) or a single command page, with
-- get_real_length() correcting column widths for the backtick markup the tables carry.
--
---@module "lvim-dependencies.hooks.help"

local M = {}

--- Command definitions grouped by section
---@type {section: string, commands: {cmd: string, desc: string}[]}[]
local COMMAND_SECTIONS = {
    {
        section = "Package Operations",
        commands = {
            { cmd = "install", desc = "Install all packages" },
            { cmd = "update", desc = "Update all packages" },
            { cmd = "update-direct <package>", desc = "Update specific package" },
            { cmd = "delete", desc = "Delete all packages" },
        },
    },
    {
        section = "Virtual Text",
        commands = {
            { cmd = "show", desc = "Show virtual text" },
            { cmd = "hide", desc = "Hide virtual text" },
            { cmd = "toggle", desc = "Toggle virtual text" },
        },
    },
    {
        section = "Cache Management",
        commands = {
            { cmd = "show-declared", desc = "Show declared cache" },
            { cmd = "show-installed", desc = "Show installed cache" },
            { cmd = "show-latest", desc = "Show latest cache" },
            { cmd = "show-all-caches", desc = "Show all caches" },
            { cmd = "clear-declared", desc = "Clear declared cache" },
            { cmd = "clear-installed", desc = "Clear installed cache" },
            { cmd = "clear-latest", desc = "Clear latest cache" },
            { cmd = "clear-all-caches", desc = "Clear all caches" },
        },
    },
    {
        section = "Registry",
        commands = {
            { cmd = "show-registry", desc = "Show registered managers" },
            { cmd = "show-manager <name>", desc = "Show manager details" },
        },
    },
    {
        section = "Other",
        commands = {
            { cmd = "help", desc = "Show this help" },
        },
    },
}

--- Short help category definitions
---@type {name: string, commands: string}[]
local SHORT_CATEGORIES = {
    { name = "Package Ops", commands = "`install`, `update`, `delete`" },
    { name = "Update Direct", commands = "`update-direct [pkg]`" },
    { name = "Virtual Text", commands = "`show`, `hide`, `toggle`" },
    { name = "Cache Show", commands = "`show-{declared,installed,latest,all-caches}`" },
    { name = "Cache Clear", commands = "`clear-{declared,installed,latest,all-caches}`" },
    { name = "Registry", commands = "`show-registry`, `show-manager`" },
    { name = "Help", commands = "`help`" },
}

--- Per-command help entries
---@type table<string, {title: string, desc: string, details: string, usage: string, examples?: string[]}>
local COMMAND_HELP = {
    install = {
        title = ":LvimDeps install",
        desc = "Install all packages.",
        details = "Runs the package manager's install command.",
        usage = ":LvimDeps install",
    },
    update = {
        title = ":LvimDeps update",
        desc = "Update all packages.",
        details = "Updates all packages to their latest versions.",
        usage = ":LvimDeps update",
    },
    ["update-direct"] = {
        title = ":LvimDeps update-direct",
        desc = "Update specific package.",
        details = "If package name is provided, updates that package.\nIf no package is provided, attempts to get package name from cursor position.",
        usage = ":LvimDeps update-direct [package]",
        examples = { ":LvimDeps update-direct", ":LvimDeps update-direct http" },
    },
    delete = {
        title = ":LvimDeps delete",
        desc = "Delete all packages.",
        details = "Removes all installed packages.",
        usage = ":LvimDeps delete",
    },
    show = {
        title = ":LvimDeps show",
        desc = "Show virtual text for all packages.",
        details = "Shows installed vs latest versions for all dependencies in the current file.",
        usage = ":LvimDeps show",
    },
    hide = {
        title = ":LvimDeps hide",
        desc = "Hide virtual text.",
        details = "Removes all virtual text from the current buffer.",
        usage = ":LvimDeps hide",
    },
    toggle = {
        title = ":LvimDeps toggle",
        desc = "Toggle virtual text.",
        details = "Shows virtual text if hidden, hides it if shown.",
        usage = ":LvimDeps toggle",
    },
    ["show-declared"] = {
        title = ":LvimDeps show-declared",
        desc = "Show declared cache.",
        details = "Displays all cached declared versions.",
        usage = ":LvimDeps show-declared",
    },
    ["show-installed"] = {
        title = ":LvimDeps show-installed",
        desc = "Show installed cache.",
        details = "Displays all cached installed versions.",
        usage = ":LvimDeps show-installed",
    },
    ["show-latest"] = {
        title = ":LvimDeps show-latest",
        desc = "Show latest cache.",
        details = "Displays all cached latest versions.",
        usage = ":LvimDeps show-latest",
    },
    ["show-all-caches"] = {
        title = ":LvimDeps show-all-caches",
        desc = "Show all caches.",
        details = "Displays declared, installed and latest caches.",
        usage = ":LvimDeps show-all-caches",
    },
    ["clear-declared"] = {
        title = ":LvimDeps clear-declared",
        desc = "Clear declared cache.",
        details = "Clears cached declared versions.",
        usage = ":LvimDeps clear-declared",
    },
    ["clear-installed"] = {
        title = ":LvimDeps clear-installed",
        desc = "Clear installed cache.",
        details = "Clears cached installed versions.",
        usage = ":LvimDeps clear-installed",
    },
    ["clear-latest"] = {
        title = ":LvimDeps clear-latest",
        desc = "Clear latest cache.",
        details = "Clears cached latest versions.",
        usage = ":LvimDeps clear-latest",
    },
    ["clear-all-caches"] = {
        title = ":LvimDeps clear-all-caches",
        desc = "Clear all caches.",
        details = "Clears declared, installed and latest caches.",
        usage = ":LvimDeps clear-all-caches",
    },
    ["show-registry"] = {
        title = ":LvimDeps show-registry",
        desc = "Show registered managers.",
        details = "Displays all registered package managers.",
        usage = ":LvimDeps show-registry",
    },
    ["show-manager"] = {
        title = ":LvimDeps show-manager",
        desc = "Show manager details.",
        details = "Displays detailed information about a specific manager.",
        usage = ":LvimDeps show-manager <name>",
        examples = { ":LvimDeps show-manager pubspec" },
    },
}

--- Get real length of text without markdown symbols
---@param text string
---@return integer
local function get_real_length(text)
    local plain_text = text:gsub("[`]", "")
    return #plain_text
end

M.get_real_length = get_real_length

--- Compute maximum command display length across all sections
---@return integer
local function max_command_length()
    local max_len = 7 -- minimum for "Command" header
    for _, section in ipairs(COMMAND_SECTIONS) do
        for _, entry in ipairs(section.commands) do
            max_len = math.max(max_len, M.get_real_length(entry.cmd))
        end
    end
    return max_len
end

--- Append a markdown table header for commands
---@param lines string[]
---@param col_width integer
local function append_table_header(lines, col_width)
    table.insert(lines, string.format("| %-" .. col_width .. "s | Description |", "Command"))
    table.insert(lines, string.format("|%s|-------------|", string.rep("-", col_width + 2)))
end

--- Append a formatted command row to lines
---@param lines string[]
---@param cmd string
---@param desc string
---@param col_width integer
local function append_command_row(lines, cmd, desc, col_width)
    local padding = col_width - M.get_real_length(cmd)
    local formatted = "`" .. cmd .. "`" .. string.rep(" ", padding)
    table.insert(lines, string.format("| %s | %s |", formatted, desc))
end

--- Get main help content
---@return string
function M.get_main_help()
    local col_width = max_command_length()

    local lines = {
        "# LvimDeps Help",
        "",
        "> Package manager integration for Neovim",
        "",
        "## USAGE",
        "",
        ":LvimDeps <command> <arguments>",
        "",
        "## COMMANDS",
    }

    for _, section in ipairs(COMMAND_SECTIONS) do
        table.insert(lines, "")
        table.insert(lines, "")
        table.insert(lines, string.format("### %s", section.section))
        table.insert(lines, "")
        table.insert(lines, "")
        append_table_header(lines, col_width)

        for _, entry in ipairs(section.commands) do
            append_command_row(lines, entry.cmd, entry.desc, col_width)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "")
    table.insert(lines, "## EXAMPLES")
    table.insert(lines, "")
    table.insert(lines, "`:LvimDeps show`")
    table.insert(lines, "`:LvimDeps hide`")
    table.insert(lines, "`:LvimDeps toggle`")
    table.insert(lines, "`:LvimDeps update-direct`")
    table.insert(lines, "`:LvimDeps update-direct http`")
    table.insert(lines, "`:LvimDeps show-registry`")
    table.insert(lines, "`:LvimDeps show-manager pubspec`")
    table.insert(lines, "`:LvimDeps clear-all-caches`")

    return table.concat(lines, "\n")
end

--- Get short help content
---@return string
function M.get_short_help()
    local max_cat_len = 8 -- minimum for "Category" header
    for _, cat in ipairs(SHORT_CATEGORIES) do
        max_cat_len = math.max(max_cat_len, #cat.name)
    end

    local lines = {
        "# LvimDeps Commands",
        "",
        string.format("| %-" .. max_cat_len .. "s | Commands |", "Category"),
        string.format("|%s|----------|", string.rep("-", max_cat_len + 2)),
    }

    for _, cat in ipairs(SHORT_CATEGORIES) do
        table.insert(lines, string.format("| %-" .. max_cat_len .. "s | %s |", cat.name, cat.commands))
    end

    table.insert(lines, "")
    table.insert(lines, "Run `:LvimDeps help` for detailed information.")

    return table.concat(lines, "\n")
end

--- Get command-specific help content
---@param command string
---@return string
function M.get_command_help(command)
    local h = COMMAND_HELP[command]
    if not h then
        return string.format("# Unknown command: %s\n\nNo help available for '%s'", command, command)
    end

    local lines = {
        string.format("# `%s`", h.title),
        "",
        h.desc,
        "",
        h.details,
        "",
        "## Usage",
        "",
        string.format("`%s`", h.usage),
    }

    if h.examples then
        table.insert(lines, "")
        table.insert(lines, "## Examples")
        table.insert(lines, "")
        for _, ex in ipairs(h.examples) do
            table.insert(lines, string.format("`%s`", ex))
        end
    end

    return table.concat(lines, "\n")
end

return M
