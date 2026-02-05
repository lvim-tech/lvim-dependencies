local const = require("lvim-dependencies.const")
local utils = require("lvim-dependencies.utils")
local validator = require("lvim-dependencies.validator")
local popup = require("lvim-dependencies.ui.popup")
local config = require("lvim-dependencies.config")
local L = vim.log.levels

local current_icon = config.ui.floating.current or "➤"

local M = {}

M.delete = function(manifest, name, version, scope)
    if not manifest or manifest == "" then
        utils.notify_safe("manifest not provided", L.ERROR, {})
        return
    end
    if not name or name == "" then
        utils.notify_safe("package name not provided", L.ERROR, {})
        return
    end
    if not scope or scope == "" then
        utils.notify_safe("scope not provided", L.ERROR, {})
        return
    end

    local ok, canonical_scope, verr = validator.validate_manifest_and_scope(manifest, scope)
    if not ok then
        utils.notify_safe(verr, L.ERROR, {})
        return
    end

    if not utils.is_package_in_lock(manifest, name) then
        utils.notify_safe(("%s is not installed (not found in lock file)"):format(name), L.WARN, {})
        return
    end

    local display_name = name
    if version and version ~= "" then
        display_name = ("%s@%s"):format(name, tostring(version))
    end

    local title = "DELETE"
    local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), tostring(canonical_scope))
    local subject = "Delete the following package"
    local lines = { display_name }

    popup.select(title, subtitle, subject, lines, function(confirmed)
        if not confirmed then
            return
        end

        local module_name = const.ACTION_MAP[manifest]
        if not module_name then
            utils.notify_safe(("unsupported manifest '%s'"):format(manifest), L.ERROR, {})
            return
        end
        local okreq, mod = pcall(require, module_name)
        if not okreq or type(mod) ~= "table" or type(mod.delete) ~= "function" then
            utils.notify_safe(("cannot load delete action for %s"):format(manifest), L.ERROR, {})
            return
        end

        local opts = { scope = canonical_scope }
        if version and version ~= "" then
            opts.version = version
        end
        opts.from_ui = true

        local success, res = pcall(mod.delete, name, opts)
        if not success then
            utils.notify_safe(("delete action failed: %s"):format(tostring(res)), L.ERROR, {})
            return
        end

        if type(res) == "table" and res.ok == false then
            utils.notify_safe(("failed to delete %s: %s"):format(name, tostring(res.msg or "unknown")), L.ERROR, {})
        else
            utils.notify_safe(("removed %s from %s"):format(name, tostring(manifest)), L.INFO, {})
        end
    end)
end

M.update = function(manifest, name, version, scope)
    if not manifest or manifest == "" then
        utils.notify_safe("manifest not provided", L.ERROR, {})
        return
    end
    if not name or name == "" then
        utils.notify_safe("package name not provided", L.ERROR, {})
        return
    end

    local canonical_scope = nil
    if scope and scope ~= "" then
        local ok, cs, verr = validator.validate_manifest_and_scope(manifest, scope)
        if not ok then
            utils.notify_safe(verr, L.ERROR, {})
            return
        end
        canonical_scope = cs
    end

    local module_name = const.ACTION_MAP[manifest]
    if not module_name then
        utils.notify_safe(("unsupported manifest '%s'"):format(manifest), L.ERROR, {})
        return
    end

    local okreq, mod = pcall(require, module_name)
    if not okreq or type(mod) ~= "table" then
        utils.notify_safe(("cannot load update action for %s"):format(manifest), L.ERROR, {})
        return
    end

    local base_opts = {}
    if canonical_scope then
        base_opts.scope = canonical_scope
    end

    local function do_update(selected_version)
        local opts = vim.tbl_extend("force", {}, base_opts)
        if selected_version and selected_version ~= "" then
            opts.version = tostring(selected_version)
        end

        opts.from_ui = true

        if type(mod.update) ~= "function" then
            utils.notify_safe(("update action not implemented for %s"):format(manifest), L.ERROR, {})
            return
        end

        local success, res = pcall(function()
            return mod.update(name, opts)
        end)
        if not success then
            utils.notify_safe(("update action failed: %s"):format(tostring(res)), L.ERROR, {})
            return
        end

        if type(res) == "table" and res.ok == false then
            utils.notify_safe(("failed to update %s: %s"):format(name, tostring(res.msg or "unknown")), L.ERROR, {})
        else
            utils.notify_safe(("updated %s in %s"):format(name, tostring(manifest)), L.INFO, {})
        end
    end

    local is_installed = utils.is_package_in_lock(manifest, name)

    local versions_result = nil
    if type(mod.fetch_versions) == "function" then
        local okv, vr = pcall(function()
            return mod.fetch_versions(name, base_opts)
        end)
        if okv and vr then
            versions_result = vr
        end
    end

    if versions_result then
        local versions = nil
        local current = nil

        if type(versions_result) == "table" and type(versions_result.versions) == "table" then
            versions = versions_result.versions
            current = versions_result.current
        elseif type(versions_result) == "table" then
            versions = versions_result
        end

        if versions and #versions > 0 then
            local lines = {}
            local index_map = {}
            local current_index = nil

            local show_current = is_installed and current

            for _, v in ipairs(versions) do
                local vs = tostring(v)
                local label = (show_current and tostring(current) == vs) and (current_icon .. " " .. vs) or ("  " .. vs)
                table.insert(lines, label)
                index_map[#lines] = vs
                if show_current and tostring(current) == vs then
                    current_index = #lines
                end
            end

            local title = "UPDATE"
            local subject = tostring(name)
            if show_current then
                subject = subject .. " (current: " .. tostring(current) .. ")"
            else
                subject = subject .. " (not installed)"
            end
            local display_scope = canonical_scope and tostring(canonical_scope) or "<unspecified>"
            local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), display_scope)

            local confirm_opts = { border = "rounded", highlight_title = "Question" }
            if current_index then
                confirm_opts.default_index = current_index
            end

            popup.select(title, subtitle, subject, lines, function(confirmed, selected)
                if not confirmed then
                    return
                end

                local selected_version = nil
                if type(selected) == "number" then
                    selected_version = index_map[selected]
                elseif type(selected) == "string" then
                    for idx, lbl in ipairs(lines) do
                        if lbl == selected then
                            selected_version = index_map[idx]
                            break
                        end
                    end
                end

                if not selected_version and type(selected) == "string" and versions then
                    for _, v in ipairs(versions) do
                        local vs = tostring(v)
                        if selected:find(vs, 1, true) then
                            selected_version = vs
                            break
                        end
                    end
                end

                if not selected_version then
                    utils.notify_safe(("could not resolve selected version for %s"):format(name), L.ERROR, {})
                    return
                end

                do_update(selected_version)
            end, confirm_opts)

            return
        end
    end

    local title = "UPDATE"
    local subject = tostring(name)

    if is_installed then
        local ok_state, state_mod = pcall(require, "lvim-dependencies.state")
        if ok_state and type(state_mod.get_installed_version) == "function" then
            local curv = state_mod.get_installed_version(manifest, name)
            if curv and curv ~= "" then
                subject = subject .. " (current: " .. tostring(curv) .. ")"
            end
        end
    else
        subject = subject .. " (not installed)"
    end

    local display_scope = canonical_scope and tostring(canonical_scope) or "<unspecified>"
    local subtitle = ("Manifest: %s    Scope: %s"):format(tostring(manifest), display_scope)
    local lines = {}
    if version and version ~= "" then
        lines[#lines + 1] = ("Set %s -> %s"):format(name, tostring(version))
    else
        lines[#lines + 1] = ("Update %s (no version specified)"):format(name)
    end

    popup.select(title, subtitle, subject, lines, function(confirmed)
        if not confirmed then
            return
        end

        do_update(version)
    end)
end

M.install = function(manifest)
    if not manifest or manifest == "" then
        utils.notify_safe("manifest not provided", L.ERROR, {})
        return
    end

    local module_name = const.ACTION_MAP[manifest]
    if not module_name then
        utils.notify_safe(("unsupported manifest '%s'"):format(manifest), L.ERROR, {})
        return
    end

    local okreq, mod = pcall(require, module_name)
    if not okreq or type(mod) ~= "table" then
        utils.notify_safe(("cannot load install action for %s"):format(manifest), L.ERROR, {})
        return
    end

    popup.input(
        "INSTALL",
        ("Manifest: %s"):format(tostring(manifest)),
        "Enter package name...",
        function(confirmed, package_name)
            if not confirmed or not package_name or package_name == "" then
                return
            end

            package_name = package_name:match("^%s*(.-)%s*$")

            if package_name == "" then
                utils.notify_safe("package name cannot be empty", L.WARN, {})
                return
            end

            if type(mod.fetch_versions) ~= "function" then
                utils.notify_safe(("fetch_versions not implemented for %s"):format(manifest), L.ERROR, {})
                return
            end

            local okv, versions_result = pcall(function()
                return mod.fetch_versions(package_name, {})
            end)

            if not okv or not versions_result then
                utils.notify_safe(("failed to fetch versions for %s"):format(package_name), L.ERROR, {})
                return
            end

            local versions = nil
            if type(versions_result) == "table" and type(versions_result.versions) == "table" then
                versions = versions_result.versions
            elseif type(versions_result) == "table" then
                versions = versions_result
            end

            if not versions or #versions == 0 then
                utils.notify_safe(("no versions found for %s"):format(package_name), L.WARN, {})
                return
            end

            local lines = {}
            local index_map = {}

            for i, v in ipairs(versions) do
                local vs = tostring(v)
                local marker = i == 1 and "→ " or "  "
                local label = marker .. vs
                table.insert(lines, label)
                index_map[#lines] = vs
            end

            local title = "SELECT VERSION"
            local subtitle = ("Package: %s    Manifest: %s"):format(package_name, tostring(manifest))
            local subject = string.format("Found %d versions (latest: %s)", #versions, tostring(versions[1]))

            popup.select(title, subtitle, subject, lines, function(ver_confirmed, selected_idx)
                if not ver_confirmed or not selected_idx then
                    return
                end

                local selected_version = index_map[selected_idx]
                if not selected_version then
                    utils.notify_safe("invalid version selection", L.ERROR, {})
                    return
                end

                local valid_scopes = const.SECTION_NAMES[manifest] or { "dependencies", "dev_dependencies" }

                local scope_lines = {}
                local scope_map = {}
                for _, sc in ipairs(valid_scopes) do
                    if sc == "dependencies" or sc == "dev_dependencies" then
                        table.insert(scope_lines, sc)
                        scope_map[#scope_lines] = sc
                    end
                end

                if #scope_lines == 0 then
                    utils.notify_safe(("no valid scopes found for %s"):format(manifest), L.ERROR, {})
                    return
                end

                if #scope_lines == 1 then
                    local scope = scope_map[1]

                    if type(mod.update) ~= "function" then
                        utils.notify_safe(("install action not implemented for %s"):format(manifest), L.ERROR, {})
                        return
                    end

                    local opts = {
                        version = selected_version,
                        scope = scope,
                        from_ui = true,
                    }

                    local success, res = pcall(function()
                        return mod.update(package_name, opts)
                    end)

                    if not success then
                        utils.notify_safe(("install failed: %s"):format(tostring(res)), L.ERROR, {})
                        return
                    end

                    if type(res) == "table" and res.ok == false then
                        utils.notify_safe(
                            ("failed to install %s: %s"):format(package_name, tostring(res.msg or "unknown")),
                            L.ERROR,
                            {}
                        )
                    else
                        utils.notify_safe(
                            ("installing %s@%s in %s..."):format(package_name, selected_version, scope),
                            L.INFO,
                            {}
                        )
                    end

                    return
                end

                local scope_title = "SELECT SCOPE"
                local scope_subtitle = ("Package: %s@%s    Manifest: %s"):format(
                    package_name,
                    selected_version,
                    tostring(manifest)
                )
                local scope_subject = "Choose installation scope"

                popup.select(
                    scope_title,
                    scope_subtitle,
                    scope_subject,
                    scope_lines,
                    function(scope_confirmed, scope_idx)
                        if not scope_confirmed or not scope_idx then
                            return
                        end

                        local scope = scope_map[scope_idx]
                        if not scope then
                            utils.notify_safe("invalid scope selection", L.ERROR, {})
                            return
                        end

                        if type(mod.update) ~= "function" then
                            utils.notify_safe(("install action not implemented for %s"):format(manifest), L.ERROR, {})
                            return
                        end

                        local opts = {
                            version = selected_version,
                            scope = scope,
                            from_ui = true,
                        }

                        local success, res = pcall(function()
                            return mod.update(package_name, opts)
                        end)

                        if not success then
                            utils.notify_safe(("install failed: %s"):format(tostring(res)), L.ERROR, {})
                            return
                        end

                        if type(res) == "table" and res.ok == false then
                            utils.notify_safe(
                                ("failed to install %s: %s"):format(package_name, tostring(res.msg or "unknown")),
                                L.ERROR,
                                {}
                            )
                        else
                            utils.notify_safe(
                                ("installing %s@%s in %s..."):format(package_name, selected_version, scope),
                                L.INFO,
                                {}
                            )
                        end
                    end,
                    { default_index = 1 }
                )
            end, { default_index = 1 })
        end
    )
end

return M
