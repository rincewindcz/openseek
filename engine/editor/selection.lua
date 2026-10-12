-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"

-- The objects selected in the map editor: an ordered list and a set.
local Selection = Class()

function Selection:init()
    self.list = {}
    self.set  = {}
end

function Selection:count()
    return #self.list
end

function Selection:has(o)
    return self.set[o] == true
end

function Selection:clear()
    self.list, self.set = {}, {}
end

function Selection:add(objects)
    for _, o in ipairs(objects) do
        if not self.set[o] then
            self.set[o] = true
            self.list[#self.list + 1] = o
        end
    end
end

function Selection:remove(objects)
    for _, o in ipairs(objects) do self.set[o] = nil end
    local kept = {}
    for _, o in ipairs(self.list) do
        if self.set[o] then kept[#kept + 1] = o end
    end
    self.list = kept
end

function Selection:replace(objects)
    self:clear()
    self:add(objects)
end

-- Drop what the document no longer holds (after a delete or an undo).
function Selection:prune(doc)
    local kept, set = {}, {}
    for _, o in ipairs(self.list) do
        if doc.by_id[o.id] == o then
            kept[#kept + 1] = o
            set[o] = true
        end
    end
    self.list, self.set = kept, set
end

return Selection
