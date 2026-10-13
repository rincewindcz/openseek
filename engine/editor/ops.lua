-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local MapCompiler = require "engine.game.map_compiler"
local Catalog     = require "engine.editor.catalog"

-- Editing operations of the map editor above the document's primitives:
-- placing a catalog entry, the objective marks a building carries (POW flag
-- and pickup pad, agent drop pad, waiting crew), copy and paste of objects
-- and roads, arranging a selection (align, even gaps, turn, mirror), grouping
-- the parts of a cloned stage.
local Ops = {}

local PAD_OFFSET    = 48   -- world px from a building to the pad placed for it
local CREW_RING     = 22   -- radius of the ring waiting people stand on
local PASTE_OFFSET  = 16
local HANGAR_REACH  = 24   -- see World:_link_hangar_tanks

local KIND_FLAG, KIND_PAD, KIND_PERSON =
    MapCompiler.KIND_POW_MARKER, MapCompiler.KIND_PAD, MapCompiler.KIND_PERSON

local function type_of_part(doc, part, set)
    return doc:intern(Catalog.part_type(part, set))
end

-- Place a catalog entry with its main part at (x, y). The parts of a stack
-- share a group. The home pad is one of a kind and leads the entity order
-- (the world takes the first pad circle for the home): placing it again moves
-- it. Returns the new objects.
function Ops.place(doc, entry, x, y)
    local objects = {}
    local group   = #entry.parts > 1 and doc:new_id() or nil
    for i, part in ipairs(entry.parts) do
        objects[i] = { t = type_of_part(doc, part), x = x, y = y, group = group }
    end
    doc:begin("PLACE " .. entry.label)
    if entry.home then
        local home = doc:home()
        if home then doc:remove(doc:members(home)) end
    end
    doc:add(objects, entry.home)
    doc:commit()
    return objects
end

-- objective marks

local function owned_of_kind(doc, building, test)
    local out = {}
    for _, o in ipairs(doc:owned_by(building)) do
        if test(doc:info(o).cls) then out[#out + 1] = o end
    end
    return out
end

function Ops.flags(doc, building)
    return owned_of_kind(doc, building, function(cls) return cls.kind == KIND_FLAG end)
end

function Ops.pickup_pads(doc, building)
    return owned_of_kind(doc, building, function(cls) return cls.kind == KIND_PAD and cls.behaviour == 1 end)
end

function Ops.drop_pads(doc, building)
    return owned_of_kind(doc, building, function(cls) return cls.kind == KIND_PAD and cls.behaviour ~= 1 end)
end

function Ops.crew(doc, building)
    return owned_of_kind(doc, building, function(cls) return cls.kind == KIND_PERSON end)
end

-- The group a building shares with its marks, made when it has none.
local function group_of(doc, building)
    if building.group then return building.group end
    local group = doc:new_id()
    doc:set_field({ building }, "group", group)
    return group
end

local function add_mark(doc, building, part, set, dx, dy)
    local o = { t = type_of_part(doc, part, set), x = building.x + dx, y = building.y + dy,
                owner = building.id, group = group_of(doc, building) }
    doc:add({ o })
    return o
end

-- People held in a building (class pows): the count, with the POW flag over
-- it and the pad a vehicle lands on to take them out. Zero takes all three
-- away. Returns false when the pack has no sprite for a mark.
function Ops.set_people(doc, building, count)
    local art  = doc:art()
    local flag = Catalog.feature(art, "flag")
    local pad  = Catalog.feature(art, "pickup_pad") or Catalog.feature(art, "any_pad")
    if count > 0 and not (flag and pad) then return false end
    doc:begin("PEOPLE INSIDE")
    doc:set_class_fields({ building }, { pows = count })
    local flags, pads = Ops.flags(doc, building), Ops.pickup_pads(doc, building)
    if count > 0 then
        if #flags == 0 then add_mark(doc, building, flag, nil, 0, 0) end
        if #pads == 0 then add_mark(doc, building, pad, { behaviour = 1 }, 0, PAD_OFFSET) end
    else
        doc:remove(flags)
        doc:remove(pads)
    end
    doc:commit()
    return true
end

-- An agent's target: the pad a vehicle lands on to send the agent in.
function Ops.set_agent_target(doc, building, on)
    local art = doc:art()
    local pad = Catalog.feature(art, "drop_pad") or Catalog.feature(art, "any_pad")
    if on and not pad then return false end
    doc:begin("AGENT TARGET")
    local pads = Ops.drop_pads(doc, building)
    if on and #pads == 0 then
        add_mark(doc, building, pad, { behaviour = 0 }, PAD_OFFSET, 0)
    elseif not on then
        doc:remove(pads)
    end
    doc:commit()
    return true
end

-- People waiting beside a wreck to be picked up.
function Ops.set_crew(doc, building, count)
    local person = Catalog.feature(doc:art(), "person")
    if count > 0 and not person then return false end
    doc:begin("WAITING CREW")
    local crew = Ops.crew(doc, building)
    for i = #crew + 1, count do
        local turn = (i - 1) * 2 * math.pi / math.max(3, count)
        add_mark(doc, building, person, nil, math.floor(math.cos(turn) * CREW_RING + 0.5),
            math.floor(math.sin(turn) * CREW_RING + 0.5))
    end
    local extra = {}
    for i = count + 1, #crew do extra[#extra + 1] = crew[i] end
    doc:remove(extra)
    doc:commit()
    return true
end

-- clipboard

-- The points of a shape from (cx, cy): the first by the shortest way over the
-- seam, the rest as they follow it.
local function relative(doc, points, cx, cy)
    local out = {}
    for i, p in ipairs(points) do
        if i == 1 then
            local dx, dy = doc:delta(p[1], p[2], cx, cy)
            out[i] = { dx, dy }
        else
            out[i] = { out[i - 1][1] + p[1] - points[i - 1][1], out[i - 1][2] + p[2] - points[i - 1][2] }
        end
    end
    return out
end

local function placed(doc, points, x, y)
    local size, out = doc:size(), {}
    for i, p in ipairs(points) do out[i] = { math.floor(x + p[1] + 0.5) % size, math.floor(y + p[2] + 0.5) % size } end
    return out
end

-- A copy of objects and roads as relative records, to paste any number of
-- times: items, the routes the objects drive and the roads, all measured from
-- the first object (or the first road's first point). nil for nothing.
function Ops.copy(doc, objects, roads)
    roads = roads or {}
    local origin = objects[1] and { objects[1].x, objects[1].y } or (roads[1] and roads[1].points[1])
    if not origin then return nil end
    local cx, cy = origin[1], origin[2]
    local items, routes, seen = {}, {}, {}
    for i, o in ipairs(objects) do
        local dx, dy = doc:delta(o.x, o.y, cx, cy)
        items[i] = { id = o.id, map_type = doc.map.types[o.t], dx = dx, dy = dy, route = o.route,
                     owner = o.owner, group = o.group }
        local route = o.route and doc:route(o.route)
        if route and not seen[route] then
            seen[route] = true
            routes[#routes + 1] = { id = route.id, points = relative(doc, route.points, cx, cy) }
        end
    end
    local lanes = {}
    for i, road in ipairs(roads) do
        lanes[i] = { points = relative(doc, road.points, cx, cy), width = road.width, pitch = road.pitch,
                     edge = road.edge, across = road.across, down = road.down }
    end
    return { items = items, routes = routes, roads = lanes }
end

-- Move a copy's origin to the middle of what it holds, so it is placed by its
-- middle (a prefab under the pointer).
function Ops.centre(clip)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local function take(x, y)
        x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
    end
    for _, item in ipairs(clip.items) do take(item.dx, item.dy) end
    for _, road in ipairs(clip.roads) do
        for _, p in ipairs(road.points) do take(p[1], p[2]) end
    end
    if x0 > x1 then return clip end
    local cx, cy = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    for _, item in ipairs(clip.items) do item.dx, item.dy = item.dx - cx, item.dy - cy end
    for _, shapes in ipairs({ clip.roads, clip.routes }) do
        for _, shape in ipairs(shapes) do
            for _, p in ipairs(shape.points) do p[1], p[2] = p[1] - cx, p[2] - cy end
        end
    end
    return clip
end

-- The type an item is placed as: a portable copy outlives the map, so the map
-- gets a type table of its own.
local function own_type(clip, map_type)
    if not clip.portable then return map_type end
    local out = {}
    for k, v in pairs(map_type) do out[k] = v end
    if map_type.set then
        out.set = {}
        for k, v in pairs(map_type.set) do out.set[k] = v end
    end
    return out
end

-- The roads of a copy laid with its origin at (x, y), as road tables the
-- document has not taken yet.
function Ops.lay_roads(doc, clip, x, y)
    local roads = {}
    for i, road in ipairs(clip.roads or {}) do
        roads[i] = { points = placed(doc, road.points, x, y), width = road.width, pitch = road.pitch,
                     edge = { { unpack(road.edge[1]) }, { unpack(road.edge[2]) } }, across = road.across,
                     down = road.down }
    end
    return roads
end

-- Paste a copy with its origin at (x, y). Links inside the copy are kept
-- among the new objects; an owner outside it is dropped. A copy of this map
-- leaves its units on the routes they had; a portable one (a prefab, which may
-- come from another map) brings its routes along. Returns the new objects and
-- the new roads.
function Ops.paste(doc, clip, x, y, label)
    local new_id, new_group, new_route, objects, roads = {}, {}, {}, {}, {}
    doc:begin(label or "PASTE")
    for _, route in ipairs(clip.portable and clip.routes or {}) do
        new_route[route.id] = doc:add_route(placed(doc, route.points, x, y)).id
    end
    for i, item in ipairs(clip.items) do
        new_id[item.id] = doc:new_id()
        if item.group and not new_group[item.group] then new_group[item.group] = doc:new_id() end
        local route = item.route and doc:route(item.route) and item.route or nil
        if clip.portable then route = new_route[item.route] end
        objects[i] = { id = new_id[item.id], t = doc:intern(own_type(clip, item.map_type)), x = x + item.dx, y = y + item.dy,
                       route = route, group = item.group and new_group[item.group] or nil }
    end
    for i, item in ipairs(clip.items) do
        objects[i].owner = item.owner and new_id[item.owner] or nil
    end
    if #objects > 0 then doc:add(objects) end
    for i, road in ipairs(Ops.lay_roads(doc, clip, x, y)) do roads[i] = doc:add_road(road) end
    doc:commit()
    return objects, roads
end

function Ops.duplicate(doc, objects, roads)
    local clip = Ops.copy(doc, objects, roads)
    if not clip then return {}, {} end
    local origin = objects[1] and { objects[1].x, objects[1].y } or roads[1].points[1]
    return Ops.paste(doc, clip, origin[1] + PASTE_OFFSET, origin[2] + PASTE_OFFSET, "DUPLICATE")
end

-- arranging

local ALIGN_AXIS = { left = "x", center = "x", right = "x", top = "y", middle = "y", bottom = "y" }
local ALIGN_LOW  = { left = true, top = true }
local ALIGN_HIGH = { right = true, bottom = true }

-- What of a selection moves as one: the selected parts of a group, or an
-- object on its own. Each { objects, x0, y0, x1, y1 }, the box of its sprites
-- measured from the first object, so a selection over the seam stays whole.
local function units(doc, objects)
    local origin = objects[1]
    local out, by_group = {}, {}
    for _, o in ipairs(objects) do
        local unit = o.group and by_group[o.group]
        if not unit then
            unit = { objects = {}, x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
            out[#out + 1] = unit
            if o.group then by_group[o.group] = unit end
        end
        unit.objects[#unit.objects + 1] = o
        local info   = doc:info(o)
        local dx, dy = doc:delta(o.x, o.y, origin.x, origin.y)
        unit.x0, unit.y0 = math.min(unit.x0, dx + info.ox), math.min(unit.y0, dy + info.oy)
        unit.x1, unit.y1 = math.max(unit.x1, dx + info.ox + info.w), math.max(unit.y1, dy + info.oy + info.h)
    end
    return out
end

local function shift(doc, objects, axis, by)
    by = math.floor(by + 0.5)
    doc:move(objects, axis == "x" and by or 0, axis == "y" and by or 0)
end

-- Bring the sprite boxes of a selection to one edge of the box around them
-- all (left, right, top, bottom), or their middles to its middle (center: on
-- a column, middle: on a row), as a drawing program aligns.
function Ops.align(doc, objects, edge)
    local list = units(doc, objects)
    if #list < 2 then return end
    local axis   = ALIGN_AXIS[edge]
    local lo, hi = axis .. "0", axis .. "1"
    local a, b   = math.huge, -math.huge
    for _, unit in ipairs(list) do a, b = math.min(a, unit[lo]), math.max(b, unit[hi]) end
    doc:begin("ALIGN")
    for _, unit in ipairs(list) do
        if ALIGN_LOW[edge] then shift(doc, unit.objects, axis, a - unit[lo])
        elseif ALIGN_HIGH[edge] then shift(doc, unit.objects, axis, b - unit[hi])
        else shift(doc, unit.objects, axis, (a + b - unit[lo] - unit[hi]) / 2) end
    end
    doc:commit()
end

-- Make the gaps between the sprite boxes of a selection equal along an axis
-- ("x" or "y"); the outermost stay. Returns false under three to space out.
function Ops.distribute(doc, objects, axis)
    local list = units(doc, objects)
    if #list < 3 then return false end
    local lo, hi = axis .. "0", axis .. "1"
    table.sort(list, function(a, b)
        if a[lo] ~= b[lo] then return a[lo] < b[lo] end
        return a.objects[1].id < b.objects[1].id
    end)
    local filled, last = 0, -math.huge
    for _, unit in ipairs(list) do
        filled = filled + unit[hi] - unit[lo]
        last   = math.max(last, unit[hi])
    end
    local gap = (last - list[1][lo] - filled) / (#list - 1)
    local at  = list[1][lo]
    doc:begin("EVEN GAPS")
    for _, unit in ipairs(list) do
        local width = unit[hi] - unit[lo]
        shift(doc, unit.objects, axis, at - unit[lo])
        at = at + width + gap
    end
    doc:commit()
    return true
end

-- Where the objects' anchors lie from the first one, and the box they span.
local function spread(doc, objects)
    local origin = objects[1]
    local at     = {}
    local x0, y0, x1, y1 = 0, 0, 0, 0
    for i, o in ipairs(objects) do
        local dx, dy = doc:delta(o.x, o.y, origin.x, origin.y)
        at[i] = { dx, dy }
        x0, y0, x1, y1 = math.min(x0, dx), math.min(y0, dy), math.max(x1, dx), math.max(y1, dy)
    end
    return at, x0, y0, x1, y1
end

-- Turn a selection a quarter about its middle: dir 1 clockwise, -1 the other
-- way. Positions only; a sprite stands as it did.
function Ops.turn(doc, objects, dir)
    if #objects < 2 then return end
    local at, x0, y0, x1, y1 = spread(doc, objects)
    local cx, cy = math.floor((x0 + x1) / 2), math.floor((y0 + y1) / 2)
    doc:begin(dir > 0 and "TURN RIGHT" or "TURN LEFT")
    for i, o in ipairs(objects) do
        local rx, ry = at[i][1] - cx, at[i][2] - cy
        doc:move({ o }, cx - ry * dir - at[i][1], cy + rx * dir - at[i][2])
    end
    doc:commit()
end

-- Mirror a selection about its middle, left to right ("x") or top to bottom
-- ("y"). Positions only.
function Ops.mirror(doc, objects, axis)
    if #objects < 2 then return end
    local at, x0, y0, x1, y1 = spread(doc, objects)
    doc:begin("MIRROR")
    for i, o in ipairs(objects) do
        if axis == "x" then doc:move({ o }, x0 + x1 - 2 * at[i][1], 0)
        else doc:move({ o }, 0, y0 + y1 - 2 * at[i][2]) end
    end
    doc:commit()
end

-- grouping

function Ops.group(doc, objects)
    if #objects < 2 then return end
    doc:set_field(objects, "group", doc:new_id(), "GROUP")
end

function Ops.ungroup(doc, objects)
    doc:set_field(objects, "group", nil, "UNGROUP")
end

-- Tie together what a pack stage places as one thing, on a map cloned from
-- it: the classes sharing a spot (a turret on its hull, a gun on its base, a
-- radar dish on its mast), a hangar hut with the tank inside it, and a
-- building with its flag, pads and people. Not recorded in the history.
function Ops.auto_group(doc)
    local map    = doc.map
    local parent = {}   -- union-find over the objects
    local function root(o)
        while parent[o] do o = parent[o] end
        return o
    end
    local function join(a, b)
        local ra, rb = root(a), root(b)
        if ra ~= rb then parent[rb] = ra end
    end
    local at, huts = {}, {}
    for _, o in ipairs(map.objects) do
        local info = doc:info(o)
        if info.layer ~= "scenery" then
            local spot = o.x * 8192 + o.y
            if at[spot] then join(at[spot], o) else at[spot] = o end
        end
        if info.kind_name == "structure" and (info.stem == "shut" or info.stem == "jhanger") then
            huts[#huts + 1] = o
        end
    end
    for _, o in ipairs(map.objects) do
        local owner = o.owner and doc.by_id[o.owner]
        if owner then join(owner, o) end
        local info = doc:info(o)
        if info.kind_name == "tank" and Catalog.is_ride(info.cls) then
            for _, hut in ipairs(huts) do
                if math.abs(hut.x - o.x) < HANGAR_REACH and math.abs(hut.y - o.y) < HANGAR_REACH then
                    join(o, hut)
                    break
                end
            end
        end
    end
    local size, group = {}, {}
    for _, o in ipairs(map.objects) do
        local r = root(o)
        size[r] = (size[r] or 0) + 1
    end
    for _, o in ipairs(map.objects) do
        local r = root(o)
        if size[r] > 1 then
            group[r] = group[r] or doc:new_id()
            o.group  = group[r]
        else
            o.group = nil
        end
    end
    doc:_index()
end

return Ops
