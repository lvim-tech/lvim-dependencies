local M = {}

M.merge = function(t1, t2)
    for k, v in pairs(t2) do
        if (type(v) == "table") and (type(t1[k] or false) == "table") then
            t1[k] = M.concat(t1[k], t2[k])
            -- M.merge(t1[k], t2[k])
        else
            t1[k] = v
        end
    end
    return t1
end

M.concat = function(tbl1, tbl2)
    for i = 1, #tbl2 do
        table.insert(tbl1, tbl2[i])
    end
    return tbl1
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

return M
