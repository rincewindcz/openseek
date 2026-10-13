-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"

-- What is selected in the map editor: the objects as an ordered list and a
-- set, and the roads picked with them.
local Selection = Class()

function Selection:init()
    self.list     = {}
    self.set      = {}
    self.roads    = {}
    self.road_set = {}
end

function Selection:count()
    return #self.list
end

-- Anything selected, object or road.
function Selection:any()
    return #self.list > 0 or #self.roads > 0
end

function Selection:total()
    return #self.list + #self.roads
end

function Selection:has(o)
    return self.set[o] == true
end

function Selection:has_road(road)
    return self.road_set[road] == true
end

function Selection:clear()
    self.list, self.set       = {}, {}
    self.roads, self.road_set = {}, {}
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

function Selection:add_roads(roads)
    for _, road in ipairs(roads) do
        if not self.road_set[road] then
            self.road_set[road] = true
            self.roads[#self.roads + 1] = road
        end
    end
end

function Selection:remove_roads(roads)
    for _, road in ipairs(roads) do self.road_set[road] = nil end
    local kept = {}
    for _, road in ipairs(self.roads) do
        if self.road_set[road] then kept[#kept + 1] = road end
    end
    self.roads = kept
end

function Selection:replace(objects, roads)
    self:clear()
    self:add(objects)
    self:add_roads(roads or {})
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
    local held = {}
    for _, road in ipairs(doc.map.roads) do held[road] = true end
    local roads, road_set = {}, {}
    for _, road in ipairs(self.roads) do
        if held[road] then
            roads[#roads + 1] = road
            road_set[road]    = true
        end
    end
    self.roads, self.road_set = roads, road_set
end

return Selection
