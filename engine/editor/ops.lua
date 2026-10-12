-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local MapCompiler = require "engine.game.map_compiler"
local Catalog     = require "engine.editor.catalog"

-- Editing operations of the map editor above the document's primitives:
-- placing a catalog entry, the objective marks a building carries (POW flag
-- and pickup pad, agent drop pad, waiting crew), copy and paste, grouping the
-- parts of a cloned stage.
local Ops = {}

local PAD_OFFSET    = 48   -- world px from a building to the pad placed for it
local CREW_RING     = 22   -- radius of the ring waiting people stand on
local PASTE_OFFSET  = 16
local HANGAR_REACH  = 24   -- see World:_link_hangar_tanks

local KIND_FLAG, KIND_PAD, KIND_PERSON =
    MapCompiler.KIND_POW_MARKER, MapCompiler.KIND_PAD, MapCompiler.KIND_PERSON

local function type_of_part(doc, part, set)
    return doc:intern({ from = part.from, class = part.class, sprite = part.sprite, set = set })
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

-- A copy of objects as relative records, to paste any number of times.
function Ops.copy(doc, objects)
    if #objects == 0 then return nil end
    local cx, cy = objects[1].x, objects[1].y
    local items = {}
    for i, o in ipairs(objects) do
        local dx, dy = doc:delta(o.x, o.y, cx, cy)
        items[i] = { id = o.id, map_type = doc.map.types[o.t], dx = dx, dy = dy, route = o.route,
                     owner = o.owner, group = o.group }
    end
    return { items = items }
end

-- Paste a copy with its first object at (x, y). Links inside the copy are
-- kept among the new objects; an owner outside it is dropped.
function Ops.paste(doc, clip, x, y)
    local new_id, new_group, objects = {}, {}, {}
    for i, item in ipairs(clip.items) do
        new_id[item.id] = doc:new_id()
        if item.group and not new_group[item.group] then new_group[item.group] = doc:new_id() end
        objects[i] = { id = new_id[item.id], t = doc:intern(item.map_type), x = x + item.dx, y = y + item.dy,
                       route = item.route and doc:route(item.route) and item.route or nil,
                       group = item.group and new_group[item.group] or nil }
    end
    for i, item in ipairs(clip.items) do
        objects[i].owner = item.owner and new_id[item.owner] or nil
    end
    doc:begin("PASTE")
    doc:add(objects)
    doc:commit()
    return objects
end

function Ops.duplicate(doc, objects)
    local clip = Ops.copy(doc, objects)
    if not clip then return {} end
    return Ops.paste(doc, clip, objects[1].x + PASTE_OFFSET, objects[1].y + PASTE_OFFSET)
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
