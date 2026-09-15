-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local function class(base)
    local cls = {}
    cls.__index = cls
    if base then setmetatable(cls, { __index = base }) end
    function cls:new(...)
        local inst = setmetatable({}, cls)
        if inst.init then inst:init(...) end
        return inst
    end
    return cls
end

return class
