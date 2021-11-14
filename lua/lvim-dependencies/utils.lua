local M = {}
local jsts = require("lvim-dependencies/jsts")
local rust = require("lvim-dependencies/rust")
local dart = require("lvim-dependencies/dart")

M.merge = function(t1, t2)
    for k, v in pairs(t2) do
        if (type(v) == "table") and (type(t1[k] or false) == "table") then
            if M.is_array(t1[k]) then
                t1[k] = M.concat(t1[k], v)
            else
                M.merge(t1[k], t2[k])
            end
        else
            t1[k] = v
        end
    end
    return t1
end

M.concat = function(t1, t2)
    for i = 1, #t2 do
        table.insert(t1, t2[i])
    end
    return t1
end

M.is_array = function(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    return true
end

M.is_file_dependencies = function()
end

M.is_ft_dependencies = function()
end

M.add_dependencies = function()
end

M.remove_dependencies = function()
end

M.add_dev_dependencies = function()
end

M.remove_dev_dependencies = function()
end

M.remove_dependency = function()
end

M.change_dependency_version = function()
end

M.show_status = function()
end

M.hide_status = function()
end

return M
