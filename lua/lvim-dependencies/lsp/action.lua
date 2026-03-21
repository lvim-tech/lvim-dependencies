-- lvim-dependencies/lsp/action.lua
-- LSP code actions for dependency management

local utils = require("lvim-dependencies.utils")
local registry = require("lvim-dependencies.core.registry")
local cache = require("lvim-dependencies.core.cache")
local init = require("lvim-dependencies.core.init")
local operation = require("lvim-dependencies.core.operation")
local operator = require("lvim-dependencies.core.operator")

local utils_lsp = utils.lsp
local notify = utils.notify

local M = {}

local function is_enabled()
    local config = require("lvim-dependencies.config")
    return config.lsp and config.lsp.actions or false
end

---@param bufnr integer
---@param manifest_type string
---@param cursor_line integer
---@return string|nil
local function find_package(bufnr, manifest_type, cursor_line)
    local ok, manager_cmds = pcall(require, string.format("lvim-dependencies.managers.%s.commands", manifest_type))
    if ok and manager_cmds and manager_cmds.get_package_at_cursor then
        local pkg = manager_cmds.get_package_at_cursor(bufnr, cursor_line)
        if pkg then
            return pkg
        end
    end

    local deps = utils_lsp.parse_dependencies(manifest_type, cache)

    local vt = init.get_virtual_text and init.get_virtual_text(manifest_type)
    if vt and vt.find_package_line then
        for name, _ in pairs(deps) do
            if vt.find_package_line(bufnr, name) == cursor_line then
                return name
            end
        end
    end

    local line = vim.api.nvim_buf_get_lines(bufnr, cursor_line, cursor_line + 1, false)[1] or ""

    -- Try manager's find_package_in_line and validate against declared deps
    local vt_mod_ok, vt_mod = pcall(require, string.format("lvim-dependencies.managers.%s.virtual_text", manifest_type))
    if vt_mod_ok and vt_mod and vt_mod.find_package_in_line then
        local pkg = vt_mod.find_package_in_line(line)
        if pkg and deps[pkg] then
            return pkg
        end
    end

    -- Fallback: simple key pattern, validated against declared deps
    local pkg = line:match("^%s*([%w_%-%.]+)%s*[=:]")
    if pkg and deps[pkg] then
        return pkg
    end

    return nil
end

---@param manifest_type string
---@param pkg string
---@param bufnr integer
---@param params table
---@return table[]
local function get_manager_actions(manifest_type, pkg, bufnr, params)
    local action_handler = registry.get_actions_provider(manifest_type)
    if action_handler then
        local ok, result = pcall(action_handler, params, bufnr, pkg)
        if ok and result and type(result) == "table" then
            return result
        end
    end

    local ok, manager_actions = pcall(require, string.format("lvim-dependencies.managers.%s.actions", manifest_type))
    if ok and manager_actions and manager_actions.get_actions then
        local ok2, result = pcall(manager_actions.get_actions, pkg, bufnr, params)
        if ok2 and result and type(result) == "table" then
            return result
        end
    end

    return {}
end

---@param op_fn fun(cb: InstallerCallback)
---@param success_msg string
---@param error_msg string
local function run_operation(op_fn, success_msg, error_msg)
    op_fn(function(result)
        if result and result.success then
            notify(success_msg, vim.log.levels.INFO)
        elseif result and result.message and result.message ~= "" and result.message ~= "cancelled" then
            notify(result.message, vim.log.levels.ERROR)
        end
    end)
end

---@param sel table
---@param pkg string
---@param manifest string
---@param buf integer
local function execute_action(sel, pkg, manifest, buf)
    if sel.id == "update" then
        run_operation(function(cb)
            local op = operation.update(manifest, { pkg }, {}, cb)
            operator.execute(op)
        end, string.format("Update completed for %s", pkg), string.format("Update failed for %s", pkg))
    elseif sel.id == "delete" then
        run_operation(function(cb)
            local op = operation.delete(manifest, { pkg }, {}, cb)
            operator.execute(op)
        end, string.format("Deleted %s", pkg), string.format("Delete failed for %s", pkg))
    elseif sel.action and type(sel.action) == "function" then
        vim.schedule(function()
            sel.action()
        end)
    elseif sel.command then
        local cmd_name = sel.command.command
        local cmd_args = sel.command.arguments or {}
        local clients = vim.lsp.get_clients({ bufnr = buf })
        local ctx = {
            bufnr = buf,
            client_id = clients and clients[1] and clients[1].id or nil,
        }
        if vim.lsp.commands and vim.lsp.commands[cmd_name] then
            vim.lsp.commands[cmd_name](
                { command = cmd_name, arguments = cmd_args, title = sel.command.title or cmd_name },
                ctx
            )
        else
            notify("Unknown command: " .. tostring(cmd_name), vim.log.levels.ERROR)
        end
    elseif sel.url then
        vim.ui.open(sel.url)
        notify(string.format("Opening %s", sel.url), vim.log.levels.INFO)
    end
end

--- Check if a package supports update/delete actions.
--- Delegates to the manager manifest's is_package_actionable() if available.
---@param manifest_type string
---@param pkg string
---@return boolean
local function is_actionable(manifest_type, pkg)
    local init = require("lvim-dependencies.core.init")
    local manifest = init.get_manifest(manifest_type)
    if manifest and type(manifest.is_package_actionable) == "function" then
        return manifest.is_package_actionable(pkg)
    end
    return true
end

function M.show()
    if not is_enabled() then
        notify("Code actions disabled", vim.log.levels.WARN)
        return
    end

    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local cursor_line = cursor[1] - 1
    local filename = vim.api.nvim_buf_get_name(buf)
    local manifest = registry.determine_manifest_type(filename)

    if not manifest then
        notify("No manifest type found", vim.log.levels.WARN)
        return
    end

    local pkg = find_package(buf, manifest, cursor_line)
    if not pkg then
        notify("No package at cursor", vim.log.levels.WARN)
        return
    end

    local deps = utils_lsp.parse_dependencies(manifest, cache)
    local dep = deps[pkg]
    local meta = utils_lsp.get_metadata_from_cache(manifest, pkg, dep, cache)
    local items = {}

    if is_actionable(manifest, pkg) then
        table.insert(items, { id = "update", text = string.format("Update %s", pkg) })
        table.insert(items, { id = "delete", text = string.format("Delete %s", pkg) })
    end

    local manager_actions = get_manager_actions(manifest, pkg, buf, { position = { line = cursor_line } })
    for _, act in ipairs(manager_actions) do
        if act.title then
            if act.action and type(act.action) == "function" then
                table.insert(items, { id = "manager_fn_" .. (#items + 1), text = act.title, action = act.action })
            elseif act.command then
                table.insert(items, { id = "manager_cmd_" .. (#items + 1), text = act.title, command = act.command })
            end
        end
    end

    if meta then
        if meta.homepage then
            table.insert(items, { id = "homepage", text = "Open homepage", url = meta.homepage })
        end
        if meta.repository then
            table.insert(items, { id = "repository", text = "Open repository", url = meta.repository })
        end
        if meta.documentation then
            table.insert(items, { id = "docs", text = "Open documentation", url = meta.documentation })
        end
    end

    if #items == 0 then
        notify(string.format("No actions available for %s", pkg), vim.log.levels.INFO)
        return
    end

    vim.ui.select(
        vim.tbl_map(function(v)
            return v.text
        end, items),
        { prompt = string.format("Actions - %s (%s)", pkg, manifest), kind = "codeaction" },
        function(_, idx)
            if not idx then
                return
            end
            execute_action(items[idx], pkg, manifest, buf)
        end
    )
end

---@param params table
---@param callback function
function M.handle(params, callback)
    if not is_enabled() then
        callback(nil, {})
        return
    end

    local buf = params and params.textDocument and params.textDocument.uri and vim.uri_to_bufnr(params.textDocument.uri)
        or vim.api.nvim_get_current_buf()

    local cursor_line = params and params.position and params.position.line or vim.api.nvim_win_get_cursor(0)[1] - 1

    local filename = vim.api.nvim_buf_get_name(buf)
    local manifest = registry.determine_manifest_type(filename)
    if not manifest then
        callback(nil, {})
        return
    end

    local pkg = find_package(buf, manifest, cursor_line)
    if not pkg then
        callback(nil, {})
        return
    end

    local deps = utils_lsp.parse_dependencies(manifest, cache)
    local dep = deps[pkg]
    local meta = utils_lsp.get_metadata_from_cache(manifest, pkg, dep, cache)
    local actions = {}

    if is_actionable(manifest, pkg) then
        table.insert(actions, {
            title = string.format("Update %s", pkg),
            kind = "quickfix",
            command = { title = "Update", command = "lvim-dependencies.update", arguments = { pkg, manifest } },
        })
        table.insert(actions, {
            title = string.format("Delete %s", pkg),
            kind = "quickfix",
            command = { title = "Delete", command = "lvim-dependencies.delete", arguments = { pkg, manifest } },
        })
    end

    local manager_actions = get_manager_actions(manifest, pkg, buf, params)
    for _, act in ipairs(manager_actions) do
        if act.title then
            if act.action and type(act.action) == "function" then
                local cmd_key = string.format("lvim-dependencies.manager-action.%s.%s", manifest, act.title)
                if not vim.lsp.commands[cmd_key] then
                    vim.lsp.commands[cmd_key] = function()
                        vim.schedule(function()
                            act.action()
                        end)
                    end
                end
                table.insert(actions, {
                    title = act.title,
                    kind = "quickfix",
                    command = { title = act.title, command = cmd_key, arguments = {} },
                })
            elseif act.command then
                table.insert(actions, act)
            end
        end
    end

    if meta then
        if meta.homepage then
            table.insert(actions, {
                title = "Open homepage",
                kind = "quickfix",
                command = {
                    title = "Open homepage",
                    command = "lvim-dependencies.open-url",
                    arguments = { meta.homepage },
                },
            })
        end
        if meta.repository then
            table.insert(actions, {
                title = "Open repository",
                kind = "quickfix",
                command = {
                    title = "Open repository",
                    command = "lvim-dependencies.open-url",
                    arguments = { meta.repository },
                },
            })
        end
        if meta.documentation then
            table.insert(actions, {
                title = "Open documentation",
                kind = "quickfix",
                command = {
                    title = "Open documentation",
                    command = "lvim-dependencies.open-url",
                    arguments = { meta.documentation },
                },
            })
        end
    end

    callback(nil, actions)
end

function M.setup()
    if not vim.lsp.commands["lvim-dependencies.update"] then
        vim.lsp.commands["lvim-dependencies.update"] = function(command)
            local args = command.arguments or {}
            local pkg = args[1] and tostring(args[1]) or nil
            local manifest = args[2] and tostring(args[2]) or nil
            if pkg and manifest then
                vim.schedule(function()
                    local op = operation.update(manifest, { pkg }, {}, function() end)
                    operator.execute(op)
                end)
            end
        end
    end

    if not vim.lsp.commands["lvim-dependencies.delete"] then
        vim.lsp.commands["lvim-dependencies.delete"] = function(command)
            local args = command.arguments or {}
            local pkg = args[1] and tostring(args[1]) or nil
            local manifest = args[2] and tostring(args[2]) or nil
            if pkg and manifest then
                vim.schedule(function()
                    local op = operation.delete(manifest, { pkg }, {}, function() end)
                    operator.execute(op)
                end)
            end
        end
    end

    if not vim.lsp.commands["lvim-dependencies.open-url"] then
        vim.lsp.commands["lvim-dependencies.open-url"] = function(command)
            local args = command.arguments or {}
            local url = args[1] and tostring(args[1]) or nil
            if url then
                vim.ui.open(url)
            end
        end
    end
end

return M
