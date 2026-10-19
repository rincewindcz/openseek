-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class       = require "engine.core.class"
local Mathx       = require "engine.core.mathx"
local MapFile     = require "engine.game.map_file"
local MapCompiler = require "engine.game.map_compiler"
local Roads       = require "engine.game.roads"
local Catalog     = require "engine.editor.catalog"

-- The map open in the editor: the map table of engine/game/map_file.lua plus
-- what editing needs around it: lookups by id, group and owner, a grid for
-- picking and culling, and an undo history. Every change goes through a
-- method here that records how to take it back.
--
-- An object's group ties the parts placed as one thing (a turret and its
-- hull); its owner is the building a POW flag, a landing pad or a waiting
-- person belongs to. Object order is entity order in the compiled stage.
local Document = Class()

local CELL       = 128    -- grid cell in world pixels
local UNDO_LIMIT = 300

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function type_key(map_type)
    if map_type.pickup then
        return "pickup|" .. map_type.pickup .. "|" .. tostring(map_type.weapon) .. "|" .. tostring(map_type.ammo_only)
    end
    if map_type.start then return "start|" .. map_type.start end
    local keys = {}
    for k in pairs(map_type.set or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = { map_type.from, tostring(map_type.class), tostring(map_type.sprite) }
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(map_type.set[k]) end
    return table.concat(parts, "|")
end

function Document:init(map, name)
    self.map      = map
    self.name     = name    -- file name in maps/, nil until first saved
    self.dirty    = false
    self.revision = 0       -- counts changes; views cache against it
    self.undo     = {}
    self.redo     = {}
    self.batch    = nil
    self.built    = { revision = -1, roads = nil }
    self:_drop_unused_types()
    self:_index()
end

-- Types left behind by earlier edits go when a map is opened; while it is
-- open the type list only grows, so the history can keep type indices.
function Document:_drop_unused_types()
    local map, used, remap, types = self.map, {}, {}, {}
    for _, o in ipairs(map.objects) do used[o.t] = true end
    for i, map_type in ipairs(map.types) do
        if used[i] then
            types[#types + 1] = map_type
            remap[i] = #types
        end
    end
    for _, o in ipairs(map.objects) do o.t = remap[o.t] end
    map.types = types
end

function Document:_index()
    local map = self.map
    self.by_id, self.cells, self.groups, self.owned, self.type_keys = {}, {}, {}, {}, {}
    for i, map_type in ipairs(map.types) do self.type_keys[type_key(map_type)] = i end
    for _, o in ipairs(map.objects) do self:_attach(o) end
    self.routes_by_id = {}
    for _, route in ipairs(map.routes) do self.routes_by_id[route.id] = route end
end

-- lookups

function Document:size()
    return self.map.size
end

function Document:art()
    return tostring(self.map.environment.art or 0)
end

function Document:info(o)
    return Catalog.type_info(self.map.types[o.t])
end

function Document:new_id()
    local id = self.map.next_id
    self.map.next_id = id + 1
    return id
end

local function cell_of(doc, x, y)
    local n = math.ceil(doc.map.size / CELL)
    local cx = math.floor((x % doc.map.size) / CELL)
    local cy = math.floor((y % doc.map.size) / CELL)
    return cy * n + cx
end

local function list_add(index, key, o)
    local list = index[key]
    if not list then
        list = {}
        index[key] = list
    end
    list[#list + 1] = o
end

local function list_remove(index, key, o)
    local list = index[key]
    if not list then return end
    for i, item in ipairs(list) do
        if item == o then
            table.remove(list, i)
            break
        end
    end
    if #list == 0 then index[key] = nil end
end

function Document:_attach(o)
    self.by_id[o.id] = o
    o.cell = cell_of(self, o.x, o.y)
    list_add(self.cells, o.cell, o)
    if o.group then list_add(self.groups, o.group, o) end
    if o.owner then list_add(self.owned, o.owner, o) end
end

function Document:_detach(o)
    self.by_id[o.id] = nil
    list_remove(self.cells, o.cell, o)
    if o.group then list_remove(self.groups, o.group, o) end
    if o.owner then list_remove(self.owned, o.owner, o) end
end

function Document:_touch()
    self.revision = self.revision + 1
    self.dirty    = true
end

-- Every object placed with o: its group, or just o.
function Document:members(o)
    return o.group and self.groups[o.group] or { o }
end

-- The flag, pads and people that belong to building o.
function Document:owned_by(o)
    return self.owned[o.id] or {}
end

function Document:route(id)
    return self.routes_by_id[id]
end

-- Call fn(o) for every object whose anchor lies in the rect (map
-- coordinates, grown by margin). The rect may reach past the map edges; the
-- caller draws one map copy at a time.
function Document:each_in(x0, y0, x1, y1, margin, fn)
    local size = self.map.size
    local n    = math.ceil(size / CELL)
    x0 = math.max(0, x0 - margin); y0 = math.max(0, y0 - margin)
    x1 = math.min(size - 1, x1 + margin); y1 = math.min(size - 1, y1 + margin)
    if x1 < x0 or y1 < y0 then return end
    for cy = math.floor(y0 / CELL), math.floor(y1 / CELL) do
        for cx = math.floor(x0 / CELL), math.floor(x1 / CELL) do
            local list = self.cells[cy * n + cx]
            if list then
                for _, o in ipairs(list) do
                    if o.x >= x0 and o.x <= x1 and o.y >= y0 and o.y <= y1 then fn(o) end
                end
            end
        end
    end
end

-- Shortest signed delta a - b on the wrapped map.
function Document:delta(ax, ay, bx, by)
    local s  = self.map.size
    local dx = (ax - bx) % s
    if dx > s / 2 then dx = dx - s end
    local dy = (ay - by) % s
    if dy > s / 2 then dy = dy - s end
    return dx, dy
end

-- A route, ground line or road keeps its points as drawn: the first on the
-- map, each next one where it lies from the one before, past the seam when
-- the shape crosses it. So a shape is drawn and compiled the short way
-- across the seam, and a leg longer than half the map stays as it was laid.

-- (x, y) moved by whole periods to lie nearest to the point ref.
function Document.near(x, y, ref, size)
    local dx = (x - ref[1]) % size
    local dy = (y - ref[2]) % size
    if dx > size / 2 then dx = dx - size end
    if dy > size / 2 then dy = dy - size end
    return ref[1] + dx, ref[2] + dy
end

-- points moved as one by whole periods, so the first lies on the map.
function Document.anchored(points, size)
    local first = points[1]
    if not first then return points end
    local sx, sy = first[1] - first[1] % size, first[2] - first[2] % size
    if sx == 0 and sy == 0 then return points end
    local out = {}
    for i, p in ipairs(points) do out[i] = { p[1] - sx, p[2] - sy } end
    return out
end

-- The object the world takes for the home pad: the heliport mark when the map
-- has one, else the first pad circle in entity order (see World:load).
function Document:home()
    local home = Catalog.data().home_pad
    local pad
    for _, o in ipairs(self.map.objects) do
        local info = self:info(o)
        if info.kind_name == "ground_decal" then
            if info.stem == home.mark then return o end
            if info.stem == home.pad and not pad then pad = o end
        end
    end
    return pad
end

-- types

-- Index of a type equal to map_type, added when the map has none.
function Document:intern(map_type)
    if map_type.set and next(map_type.set) == nil then map_type.set = nil end
    local key   = type_key(map_type)
    local index = self.type_keys[key]
    if not index then
        self.map.types[#self.map.types + 1] = map_type
        index = #self.map.types
        self.type_keys[key] = index
    end
    return index
end

-- Index of type t with class fields changed. A field set back to what the
-- pack class has is dropped from the type.
function Document:type_with(t, changes)
    local base = self.map.types[t]
    local src  = MapCompiler.type_source(base)
    local set  = copy(base.set or {})
    for k, v in pairs(changes) do
        if src and src[k] == v then set[k] = nil else set[k] = v end
    end
    return self:intern({ from = base.from, class = base.class, sprite = base.sprite, set = set })
end

-- history

function Document:begin(label)
    if self.batch then
        self.batch.depth = self.batch.depth + 1
    else
        self.batch = { label = label, steps = {}, depth = 1 }
    end
end

function Document:commit()
    local batch = self.batch
    if not batch then return end
    batch.depth = batch.depth - 1
    if batch.depth > 0 then return end
    self.batch = nil
    if #batch.steps == 0 then return end
    self.undo[#self.undo + 1] = batch
    if #self.undo > UNDO_LIMIT then table.remove(self.undo, 1) end
    self.redo = {}
end

-- Do a change now and remember how to take it back.
function Document:_run(label, redo, undo)
    local own = not self.batch
    if own then self:begin(label) end
    redo()
    self:_touch()
    table.insert(self.batch.steps, { redo = redo, undo = undo })
    if own then self:commit() end
end

function Document:can_undo() return #self.undo > 0 end
function Document:can_redo() return #self.redo > 0 end

function Document:undo_step()
    local batch = table.remove(self.undo)
    if not batch then return nil end
    for i = #batch.steps, 1, -1 do batch.steps[i].undo() end
    self.redo[#self.redo + 1] = batch
    self:_touch()
    return batch.label
end

function Document:redo_step()
    local batch = table.remove(self.redo)
    if not batch then return nil end
    for _, step in ipairs(batch.steps) do step.redo() end
    self.undo[#self.undo + 1] = batch
    self:_touch()
    return batch.label
end

-- objects

-- Add objects (each { t, x, y, ... }, ids are given here) at the end of the
-- entity order, or at the front.
function Document:add(objects, front)
    local size = self.map.size
    for _, o in ipairs(objects) do
        o.id = o.id or self:new_id()
        o.x  = math.floor(o.x + 0.5) % size
        o.y  = math.floor(o.y + 0.5) % size
    end
    self:_run("ADD", function()
        local list = self.map.objects
        for i, o in ipairs(objects) do
            if front then table.insert(list, i, o) else list[#list + 1] = o end
            self:_attach(o)
        end
    end, function()
        local gone = {}
        for _, o in ipairs(objects) do
            gone[o] = true
            self:_detach(o)
        end
        local kept = {}
        for _, o in ipairs(self.map.objects) do
            if not gone[o] then kept[#kept + 1] = o end
        end
        self.map.objects = kept
    end)
end

-- Remove objects, and with a building its flag, pads and people.
function Document:remove(objects)
    local gone, count = {}, 0
    local function mark(o)
        if gone[o] or not self.by_id[o.id] then return end
        gone[o] = true
        count   = count + 1
        for _, child in ipairs(self:owned_by(o)) do mark(child) end
    end
    for _, o in ipairs(objects) do mark(o) end
    if count == 0 then return end
    local slots = {}   -- { index, object } in ascending index, to put them back in place
    for i, o in ipairs(self.map.objects) do
        if gone[o] then slots[#slots + 1] = { i, o } end
    end
    self:_run("DELETE", function()
        local kept = {}
        for _, o in ipairs(self.map.objects) do
            if gone[o] then self:_detach(o) else kept[#kept + 1] = o end
        end
        self.map.objects = kept
    end, function()
        for _, slot in ipairs(slots) do
            table.insert(self.map.objects, slot[1], slot[2])
            self:_attach(slot[2])
        end
    end)
end

function Document:_place(o, x, y)
    local size = self.map.size
    list_remove(self.cells, o.cell, o)
    o.x, o.y = x % size, y % size
    o.cell   = cell_of(self, o.x, o.y)
    list_add(self.cells, o.cell, o)
end

-- Move objects by a whole-pixel delta. live moves without recording (a drag
-- in progress); the drag ends with one recorded move of the total.
function Document:move(objects, dx, dy, live)
    if dx == 0 and dy == 0 then return end
    local function shift(sx, sy)
        for _, o in ipairs(objects) do self:_place(o, o.x + sx, o.y + sy) end
    end
    if live then
        shift(dx, dy)
        self.revision = self.revision + 1
        return
    end
    self:_run("MOVE", function() shift(dx, dy) end, function() shift(-dx, -dy) end)
end

-- Record a finished live drag of (dx, dy) in total, already applied.
function Document:record_move(objects, dx, dy)
    if dx == 0 and dy == 0 then return end
    local first = true
    local function shift(sx, sy)
        for _, o in ipairs(objects) do self:_place(o, o.x + sx, o.y + sy) end
    end
    self:_run("MOVE", function()
        if first then first = false else shift(dx, dy) end
    end, function() shift(-dx, -dy) end)
end

-- Set one field (t, route, owner, group) on objects: value, or per object
-- from a table keyed by the object.
function Document:set_field(objects, field, value, label)
    local before, after = {}, {}
    local changed = false
    for i, o in ipairs(objects) do
        before[i] = o[field]
        if type(value) == "table" then after[i] = value[o] else after[i] = value end
        if before[i] ~= after[i] then changed = true end
    end
    if not changed then return end
    local function apply(values)
        for i, o in ipairs(objects) do
            self:_detach(o)
            o[field] = values[i]
            self:_attach(o)
        end
    end
    self:_run(label or "CHANGE", function() apply(after) end, function() apply(before) end)
end

-- Change class fields on objects, each keeping the rest of its own type.
function Document:set_class_fields(objects, changes, label)
    local types = {}
    for _, o in ipairs(objects) do types[o] = self:type_with(o.t, changes) end
    self:set_field(objects, "t", types, label)
end

-- routes and lines

function Document:add_route(points)
    local route  = { id = self:new_id(), points = Document.anchored(points, self.map.size) }
    local routes = self.map.routes
    self:_run("ADD ROUTE", function()
        routes[#routes + 1] = route
        self.routes_by_id[route.id] = route
    end, function()
        for i, r in ipairs(routes) do
            if r == route then table.remove(routes, i); break end
        end
        self.routes_by_id[route.id] = nil
    end)
    return route
end

function Document:remove_route(route)
    local routes = self.map.routes
    local index
    for i, r in ipairs(routes) do
        if r == route then index = i end
    end
    if not index then return end
    local riders = {}
    for _, o in ipairs(self.map.objects) do
        if o.route == route.id then riders[#riders + 1] = o end
    end
    self:begin("DELETE ROUTE")
    self:set_field(riders, "route", nil)
    self:_run("DELETE ROUTE", function()
        table.remove(routes, index)
        self.routes_by_id[route.id] = nil
    end, function()
        table.insert(routes, index, route)
        self.routes_by_id[route.id] = route
    end)
    self:commit()
end

function Document:add_line(line)
    line.points = Document.anchored(line.points, self.map.size)
    local lines = self.map.lines
    self:_run("ADD LINE", function() lines[#lines + 1] = line end, function()
        for i, l in ipairs(lines) do
            if l == line then table.remove(lines, i); break end
        end
    end)
end

function Document:remove_line(line)
    local lines = self.map.lines
    local index
    for i, l in ipairs(lines) do
        if l == line then index = i end
    end
    if not index then return end
    self:_run("DELETE LINE", function() table.remove(lines, index) end,
        function() table.insert(lines, index, line) end)
end

-- roads

-- Add a road { points, width, pitch, edge, across, down }; its id is given here.
function Document:add_road(road)
    road.id     = road.id or self:new_id()
    road.points = Document.anchored(road.points, self.map.size)
    local roads = self.map.roads
    self:_run("ADD ROAD", function() roads[#roads + 1] = road end, function()
        for i, r in ipairs(roads) do
            if r == road then table.remove(roads, i); break end
        end
    end)
    return road
end

function Document:remove_road(road)
    local roads = self.map.roads
    local index
    for i, r in ipairs(roads) do
        if r == road then index = i end
    end
    if not index then return end
    self:_run("DELETE ROAD", function() table.remove(roads, index) end,
        function() table.insert(roads, index, road) end)
end

-- Set one field of a road (width, pitch).
function Document:set_road(road, field, value, label)
    local before = road[field]
    if before == value then return end
    self:_run(label or "ROAD", function() road[field] = value end, function() road[field] = before end)
end

local function shifted(points, dx, dy, size)
    local out = {}
    for i, p in ipairs(points) do out[i] = { p[1] + dx, p[2] + dy } end
    return Document.anchored(out, size)
end

-- Move roads by a whole-pixel delta. live moves without recording (a drag in
-- progress); the drag ends with Document:record_road_move of the total. A
-- road gets a new point list each time: the history keeps the old ones.
function Document:move_roads(roads, dx, dy, live)
    if #roads == 0 or (dx == 0 and dy == 0) then return end
    local function shift(sx, sy)
        for _, road in ipairs(roads) do road.points = shifted(road.points, sx, sy, self.map.size) end
    end
    if live then
        shift(dx, dy)
        self.revision = self.revision + 1
        return
    end
    self:_run("MOVE", function() shift(dx, dy) end, function() shift(-dx, -dy) end)
end

-- Record a finished live drag of roads by (dx, dy) in total, already applied.
function Document:record_road_move(roads, dx, dy)
    if #roads == 0 or (dx == 0 and dy == 0) then return end
    local first = true
    local function shift(sx, sy)
        for _, road in ipairs(roads) do road.points = shifted(road.points, sx, sy, self.map.size) end
    end
    self:_run("MOVE", function()
        if first then first = false else shift(dx, dy) end
    end, function() shift(-dx, -dy) end)
end

-- The road whose ground holds the map point (x, y), the one drawn last first.
function Document:road_at(x, y)
    local legs = self:built_roads().legs
    local size = self.map.size
    for i = #legs, 1, -1 do
        local leg = legs[i]
        -- A leg past the seam is found from the map copy it lies in.
        local lx = leg.left + (x - leg.left) % size
        local ly = leg.top + (y - leg.top) % size
        if lx <= leg.right and ly <= leg.bottom then return leg.road end
    end
    return nil
end

-- The roads as border segments, centre marks and legs (engine/game/roads.lua),
-- rebuilt when the map changed.
function Document:built_roads()
    if self.built.revision ~= self.revision then
        self.built = { revision = self.revision, roads = Roads.build(self.map.roads, self.map.size) }
    end
    return self.built.roads
end

-- Something drawn from the map changed without a recorded step (a point
-- dragged by a tool before the drag is recorded): views drop what they cached.
function Document:refresh()
    self.revision = self.revision + 1
end

-- Replace the points of a route, a line or a road (and a line's colour).
function Document:set_points(shape, points, color, label)
    points = Document.anchored(points, self.map.size)
    local before, before_color = shape.points, shape.color
    self:_run(label or "EDIT POINTS", function()
        shape.points = points
        if color then shape.color = color end
    end, function()
        shape.points = before
        shape.color  = before_color
    end)
end

-- map settings

function Document:set_map(field, value, label)
    local before = self.map[field]
    if before == value then return end
    self:_run(label or "MAP SETTINGS", function() self.map[field] = value end,
        function() self.map[field] = before end)
end

-- Change the wrap period. Objects, route, line and road points and objective places
-- past the new edge wrap around; the history is cleared, since it holds positions of the old size.
function Document:resize(size)
    if size == self.map.size then return end
    self.map.size = size
    for _, o in ipairs(self.map.objects) do
        o.x, o.y = o.x % size, o.y % size
    end
    for _, shapes in ipairs({ self.map.routes, self.map.lines, self.map.roads }) do
        for _, shape in ipairs(shapes) do
            for _, p in ipairs(shape.points) do p[1], p[2] = p[1] % size, p[2] % size end
            shape.points = Mathx.unwrap(shape.points, size)
        end
    end
    for _, goal in ipairs(self.map.objectives) do
        if goal.x then goal.x, goal.y = goal.x % size, goal.y % size end
    end
    self.undo, self.redo = {}, {}
    self:_index()
    self:_touch()
end

-- files

function Document:save(name)
    name = name or self.name
    if not name then return false end
    if not MapFile.write(self.map, name) then return false end
    self.name  = name
    self.dirty = false
    return true
end

return Document
