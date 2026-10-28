-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json    = require "lib.json"
local MapFile = require "engine.game.map_file"
local Roads   = require "engine.game.roads"

-- Turns a map (engine/game/map_file.lua) into the stage table World:load
-- builds a phase from, and a pack stage into a map (a clone to edit).
--
-- A compiled stage starts as the class table of the map's base stage, so the
-- classes the engine addresses by index (projectiles, the walker sheet, the
-- helicopters) sit where they always do, and every map type is appended as a
-- class of its own: a copy of the pack class it names with its changed fields.
-- The original ties a landing pad or a waiting person to its building through
-- the class (parent_class is an entity index) and a POW flag to the entity
-- stored just before it; a map keeps those as per-object owner links and the
-- compiler writes them back in the original's form.
local MapCompiler = {}

-- Stage class kinds of the people objectives (see World:load).
local KIND_POW_MARKER = 9
local KIND_PERSON     = 11
local KIND_PAD        = 14

-- A map's objective types as the mission knows them (Mission.TYPES).
local GOAL_TYPES = {
    targets = "destroy_targets", rescue = "rescue_people", sabotage = "sabotage", destroy = "destroy",
    reach = "reach", survive = "survive", collect = "collect", protect = "protect", air = "air",
}

local PAD_PICKUP = 1       -- pad class behaviour: people run out to the vehicle
local HOLD_ALL   = 65535   -- stage global 5: agents wait until all are inside
local HOLD_SLOT  = 5
local WRAP_SLACK = 32      -- see World:_fit_wrap_period

MapCompiler.KIND_POW_MARKER = KIND_POW_MARKER
MapCompiler.KIND_PERSON     = KIND_PERSON
MapCompiler.KIND_PAD        = KIND_PAD

local pack_cache = {}   -- pack stage name -> its class side, or false when absent

local function read_pack_stage(name)
    local path = "assets/" .. name .. ".json"
    local raw  = love.filesystem.getInfo(path) and love.filesystem.read(path)
    return raw and json.decode(raw) or nil
end

-- The class side of a pack stage: classes, assets, globals, how often each
-- class is placed (uses, by class index) and which classes share a spot
-- (stacks). Cached; nil when the pack lacks it.
function MapCompiler.pack_stage(name)
    local hit = pack_cache[name]
    if hit ~= nil then return hit or nil end
    local stage = name:match("^stage%d") and read_pack_stage(name)
    if not stage then
        pack_cache[name] = false
        return nil
    end
    local uses, at = {}, {}
    for _, e in ipairs(stage.entities) do
        uses[e.class] = (uses[e.class] or 0) + 1
        local spot = e.x * 8192 + e.y
        local here = at[spot]
        if here then here[#here + 1] = e.class else at[spot] = { e.class } end
    end
    -- Classes placed on one spot (a turret on its hull, a gun on its base), by
    -- the class list in entity order: "a,b" -> { classes, count }.
    local stacks = {}
    for _, here in pairs(at) do
        if #here > 1 then
            local key   = table.concat(here, ",")
            local stack = stacks[key]
            if stack then stack.count = stack.count + 1 else stacks[key] = { classes = here, count = 1 } end
        end
    end
    hit = { name = name, classes = stage.classes, assets = stage.assets, globals = stage.globals,
            header = stage.header, world_size = stage.world_size, uses = uses, stacks = stacks }
    pack_cache[name] = hit
    return hit
end

function MapCompiler.asset_stem(pack, cls)
    local asset = cls and cls.asset and pack.assets[cls.asset + 1]
    return asset and asset.file and asset.file:lower():gsub("%.bin$", "") or nil
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- A class as the compiled stage holds it: its sprite found in the pack stage
-- it comes from.
local function sourced(cls, dir)
    if not cls.render then return cls end
    local out  = copy(cls)
    out.render = copy(cls.render)
    out.render.dir = dir
    return out
end

-- The pack class a map type names, or nil when this pack does not have it. A
-- class index that no longer carries the type's sprite (another edition of the
-- data) falls back to a class of that sprite.
function MapCompiler.type_source(map_type)
    local pack = map_type.from and MapCompiler.pack_stage(map_type.from)
    if not pack then return nil end
    local cls = pack.classes[(map_type.class or -1) + 1]
    if cls and (not map_type.sprite or MapCompiler.asset_stem(pack, cls) == map_type.sprite) then
        return cls, pack
    end
    for _, c in ipairs(pack.classes) do
        if c.render and MapCompiler.asset_stem(pack, c) == map_type.sprite then return c, pack end
    end
    return nil
end

-- The class fields of a map type: the pack class with the type's changes.
function MapCompiler.type_fields(map_type)
    local cls = MapCompiler.type_source(map_type)
    if not cls then return nil end
    local out = copy(cls)
    for k, v in pairs(map_type.set or {}) do out[k] = v end
    return out
end

local function is_linked_kind(kind)
    return kind == KIND_PAD or kind == KIND_PERSON
end

-- map -> stage. Returns nil and the reason when the pack lacks the base stage.
-- Objects whose type this pack cannot resolve are left out and counted in
-- stage.missing. A pickup type is no class: its objects are no entities and
-- go to stage.pickups, which engine/game/powerups.lua lays out. Nor is a
-- player's start: the first placed for a player is stage.starts[player].
function MapCompiler.compile(map)
    local base = MapCompiler.pack_stage(map.base)
    if not base then return nil, "needs the game data of " .. tostring(map.base) end

    local classes, assets = {}, {}
    for i, a in ipairs(base.assets) do assets[i] = a end
    for i, c in ipairs(base.classes) do classes[i] = sourced(c, map.base) end

    local asset_of = {}   -- "stage/asset index" -> asset index in the output
    local function asset_index(pack, cls)
        if pack.name == map.base or not cls.asset then return cls.asset end
        local key = pack.name .. "/" .. cls.asset
        if not asset_of[key] then
            local asset = copy(pack.assets[cls.asset + 1])
            asset.index = #assets
            assets[#assets + 1] = asset
            asset_of[key] = asset.index
        end
        return asset_of[key]
    end

    local function add_class(cls)
        cls.index = #classes
        classes[#classes + 1] = cls
        return cls.index
    end

    -- The class of a map type, added to the stage: false when this pack cannot resolve it.
    local function class_of(map_type)
        local src, pack = MapCompiler.type_source(map_type)
        if not src then return false end
        local cls = sourced(src, pack.name)
        if cls == src then cls = copy(src) end
        for k, v in pairs(map_type.set or {}) do cls[k] = v end
        cls.asset = asset_index(pack, src)
        if is_linked_kind(cls.kind) then cls.parent_class = -1 end
        return add_class(cls)
    end

    local type_class = {}   -- type index -> class index, false when unresolved or a pickup
    for i, map_type in ipairs(map.types) do
        type_class[i] = not (map_type.pickup or map_type.start) and class_of(map_type)
    end

    -- Entity order is object order, except that a POW flag follows its building.
    local by_id, flags_of = {}, {}
    for _, o in ipairs(map.objects) do by_id[o.id] = o end
    local function is_flag(o)
        local index = type_class[o.t]
        local owner = o.owner and by_id[o.owner]
        return index and owner and classes[index + 1].kind == KIND_POW_MARKER and type_class[owner.t]
    end
    for _, o in ipairs(map.objects) do
        if is_flag(o) then
            flags_of[o.owner] = flags_of[o.owner] or {}
            table.insert(flags_of[o.owner], o)
        end
    end
    local order, pickups, starts, missing = {}, {}, {}, 0
    local pickup_index = {}   -- object id -> place in pickups
    for _, o in ipairs(map.objects) do
        local map_type = map.types[o.t]
        if map_type.pickup then
            pickups[#pickups + 1] = { kind = map_type.pickup, weapon = map_type.weapon,
                                      ammo_only = map_type.ammo_only == true or nil, x = o.x, y = o.y }
            pickup_index[o.id] = #pickups
        elseif map_type.start then
            starts[map_type.start] = starts[map_type.start] or { x = o.x, y = o.y }
        elseif not type_class[o.t] then
            missing = missing + 1
        elseif not is_flag(o) then
            order[#order + 1] = o
            for _, flag in ipairs(flags_of[o.id] or {}) do order[#order + 1] = flag end
        end
    end
    local entity_index = {}   -- object id -> 0-based entity index
    for i, o in ipairs(order) do entity_index[o.id] = i - 1 end

    local routes, route_index = {}, {}
    for _, route in ipairs(map.routes) do
        local points = {}
        for i, p in ipairs(route.points) do points[i] = { x = p[1], y = p[2] } end
        route_index[route.id] = #routes
        routes[#routes + 1] = { points = points, trailer = #points }
    end

    local linked = {}   -- "class/owner entity" -> class index
    local entities, targets, target_classes = {}, 0, {}
    for i, o in ipairs(order) do
        local index = type_class[o.t]
        local cls   = classes[index + 1]
        local owner = o.owner and entity_index[o.owner]
        if owner and is_linked_kind(cls.kind) then
            local key = index .. "/" .. owner
            if not linked[key] then
                local own = copy(cls)
                own.parent_class = owner
                linked[key] = add_class(own)
            end
            index = linked[key]
        end
        if cls.is_target then
            targets = targets + 1
            if not target_classes[index] then
                target_classes[index] = true
                target_classes[#target_classes + 1] = index
            end
        end
        entities[i] = { class = index, x = o.x, y = o.y, route = o.route and route_index[o.route] or nil }
    end

    local segments = {}
    for _, line in ipairs(map.lines) do
        local points = line.points
        for i = 1, #points - 1 do
            segments[#segments + 1] = { x1 = points[i][1], y1 = points[i][2],
                x2 = points[i + 1][1], y2 = points[i + 1][2], value = 0, color = line.color }
        end
    end

    -- The roads: their borders join the ground lines, their centre marks are
    -- decals after everything the map places.
    local roads, mark_class = Roads.build(map.roads, map.size), {}
    for _, s in ipairs(roads.segments) do
        segments[#segments + 1] = { x1 = s.x1, y1 = s.y1, x2 = s.x2, y2 = s.y2, value = 0, color = s.color }
    end
    for _, mark in ipairs(roads.marks) do
        local key = table.concat({ tostring(mark.type.from), tostring(mark.type.class), tostring(mark.type.sprite) }, "/")
        if mark_class[key] == nil then mark_class[key] = class_of(mark.type) end
        if mark_class[key] then
            entities[#entities + 1] = { class = mark_class[key], x = mark.x, y = mark.y }
        end
    end

    local globals = copy(base.globals or {})
    globals[HOLD_SLOT] = map.hold_agents and HOLD_ALL or 0

    -- The objectives as the mission takes them: an object named by its id
    -- becomes its place in the entity list.
    local function placed(ids)
        local out = {}
        for _, id in ipairs(ids or {}) do
            if entity_index[id] then out[#out + 1] = entity_index[id] + 1 end
        end
        return out
    end
    local function placed_pickups(ids)
        local out = {}
        for _, id in ipairs(ids or {}) do
            if pickup_index[id] then out[#out + 1] = pickup_index[id] end
        end
        return out
    end
    local function event_ids(ids)
        local out = {}
        for _, id in ipairs(type(ids) == "table" and ids or {}) do
            if tonumber(id) then out[#out + 1] = tonumber(id) end
        end
        return out
    end
    -- An event of the map (Mission:_fire): the objects it acts on by entity
    -- place, those it brings in or takes away that are pickups by their place
    -- in stage.pickups, the route it sends units along by its place in routes.
    local function event(raw)
        if type(raw) ~= "table" then return nil end
        local out = { say = raw.say, show_pickups = placed_pickups(raw.show), hide_pickups = placed_pickups(raw.hide),
                      add_time = tonumber(raw.add_time), weather = type(raw.weather) == "string" and raw.weather or nil,
                      strength = tonumber(raw.strength), route = raw.route and route_index[raw.route],
                      switch_on = event_ids(raw.switch_on), switch_off = event_ids(raw.switch_off),
                      ends = (raw.ends == "win" or raw.ends == "fail") and raw.ends or nil }
        for _, key in ipairs(MapFile.EVENT_OBJECTS) do out[key] = placed(raw[key]) end
        local shell = raw.shell
        if type(shell) == "table" and tonumber(shell.x) and tonumber(shell.y) then
            out.shell = { x = tonumber(shell.x), y = tonumber(shell.y), radius = tonumber(shell.radius) }
        end
        return out
    end
    local goals = {}
    for _, goal in ipairs(map.objectives or {}) do
        local spec = { type = GOAL_TYPES[goal.type], label = goal.label, optional = goal.optional,
                       on_open = event(goal.on_open), on_done = event(goal.on_done) }
        if goal.type == "destroy" then
            spec.mark  = true
            spec.count = goal.count
            if goal.kinds then spec.kinds = goal.kinds else spec.entities = placed(goal.objects) end
        elseif goal.type == "reach" then
            spec.x, spec.y, spec.radius, spec.land = goal.x, goal.y, goal.radius, goal.land
        elseif goal.type == "survive" then
            spec.seconds = goal.seconds
        elseif goal.type == "collect" or goal.type == "air" then
            spec.count = goal.count
        elseif goal.type == "protect" then
            spec.entities, spec.losses = placed(goal.objects), goal.losses
        end
        if spec.type then goals[#goals + 1] = spec end
    end
    local rescue = MapFile.objective(map, "rescue")
    -- The map's events, with what sets each off.
    local events = {}
    for _, raw in ipairs(map.events or {}) do
        local spec = event(raw)
        spec.id, spec.off = raw.id, raw.off
        spec.when, spec.at, spec.every, spec.times = raw.when, raw.at, raw.every, raw.times
        spec.count, spec.below = raw.count, raw.below
        if raw.place then
            spec.place = { x = raw.place.x, y = raw.place.y, radius = raw.place.radius, land = raw.place.land }
        end
        if raw.units then spec.units = placed(raw.units) end
        if raw.targets then spec.targets = placed(raw.targets) end
        events[#events + 1] = spec
    end

    return {
        world_size  = map.size,
        header      = base.header,
        name        = map.name,
        globals     = globals,
        assets      = assets,
        classes     = classes,
        routes      = routes,
        wrap_routes = true,   -- a route may cross the seam (Entity:_patrol)
        entities    = entities,
        segments    = segments,
        pickups     = pickups,
        starts      = starts,
        environment = map.environment,
        terrain     = map.terrain and { cell = map.terrain.cell, cells = copy(map.terrain.cells) },
        objectives  = {
            destroy           = targets > 0,
            rescue            = not (rescue and rescue.optional),
            special_end       = map.commander == true,
            target_classes    = target_classes,
            n_target_entities = targets,
        },
        -- What the briefing and the mission read in place of data/missions.json.
        mission     = { name = map.name, author = map.author, briefing = map.briefing, vehicle = map.vehicle,
                        players = map.players, objectives = goals, loadout = map.loadout, equip = map.equip,
                        difficulty = map.difficulty, ordered = map.ordered == true, time_limit = map.time_limit,
                        no_return = map.no_return == true, events = events },
        missing     = missing,
    }
end

-- The compiled stage of the map file `name`, or nil and the reason.
function MapCompiler.load(name)
    local map, raw = MapFile.read(name)
    if not map then return nil, raw end
    local stage, err = MapCompiler.compile(map)
    if not stage then return nil, err end
    stage.map_hash = MapFile.hash(raw)
    return stage
end

-- pack stage -> map

-- The wrap period World:_fit_wrap_period gives a pack stage, which a map states
-- as its size: the extent of what the world draws when that is clearly inside
-- the stage (mission 0 phases 0-2), else the stage's own size.
local function fitted_size(stage, in_world)
    local s = stage.world_size
    local lo_x, lo_y, hi_x, hi_y = s, s, 0, 0
    for i, e in ipairs(stage.entities) do
        if in_world[i] then
            if e.x < lo_x then lo_x = e.x end
            if e.x > hi_x then hi_x = e.x end
            if e.y < lo_y then lo_y = e.y end
            if e.y > hi_y then hi_y = e.y end
        end
    end
    if hi_x <= lo_x or hi_y <= lo_y then return s end
    local period = math.min(hi_x - lo_x + 1, hi_y - lo_y + 1)
    return period < s - WRAP_SLACK and period or s
end

-- Ground segments chained into polylines where one ends on the next's start.
local function chain_segments(segments)
    local lines, last = {}, nil
    for _, s in ipairs(segments or {}) do
        local tail = last and last.points[#last.points]
        local same = last and last.color[1] == s.color[1] and last.color[2] == s.color[2]
            and last.color[3] == s.color[3]
        if same and tail[1] == s.x1 and tail[2] == s.y1 then
            last.points[#last.points + 1] = { s.x2, s.y2 }
        else
            last = { color = { s.color[1], s.color[2], s.color[3] }, points = { { s.x1, s.y1 }, { s.x2, s.y2 } } }
            lines[#lines + 1] = last
        end
    end
    return lines
end

-- A map holding everything the pack stage `stage_name` does: one type per
-- class in use, one object per entity in its order, the owner links read back
-- from the classes. goals is the stage's entry of data/missions.json, for the
-- objective labels. Returns nil when the pack lacks the stage.
function MapCompiler.decompile(stage_name, goals)
    local stage = stage_name:match("^stage%d") and read_pack_stage(stage_name)
    if not stage then return nil end
    local art = tonumber(stage_name:match("^stage(%d)")) or 0
    local map = MapFile.new(stage_name:upper() .. " COPY", art, stage_name)
    map.based_on = stage_name

    local classes  = stage.classes
    local type_of  = {}   -- class index -> type index
    local in_world = {}
    for i, e in ipairs(stage.entities) do
        local cls = classes[e.class + 1]
        if not type_of[e.class] then
            map.types[#map.types + 1] = { from = stage_name, class = e.class,
                sprite = MapCompiler.asset_stem(stage, cls) }
            type_of[e.class] = #map.types
        end
        local o = { id = i, t = type_of[e.class], x = e.x, y = e.y, route = e.route and e.route + 1 or nil }
        local prev   = stage.entities[i - 1]
        local parent = is_linked_kind(cls.kind) and stage.entities[(cls.parent_class or -1) + 1]
        if parent and classes[parent.class + 1].kind_name == "structure" then
            o.owner = cls.parent_class + 1
        elseif cls.kind == KIND_POW_MARKER and prev then
            local before = classes[prev.class + 1]
            if before.kind_name == "structure" and (before.pows or 0) > 0 then o.owner = i - 1 end
        end
        map.objects[i] = o
        in_world[i] = not (cls.kind_name == "enemy_helicopter"
            or (cls.kind == KIND_PAD and cls.behaviour == PAD_PICKUP and o.owner))
    end
    local driven = {}
    for _, o in ipairs(map.objects) do
        if o.route then driven[o.route] = true end
    end
    for i, route in ipairs(stage.routes or {}) do
        if driven[i] then
            local points = {}
            for k, p in ipairs(route.points) do points[k] = { p.x, p.y } end
            map.routes[#map.routes + 1] = { id = i, points = points }
        end
    end
    map.lines       = chain_segments(stage.segments)
    map.size        = fitted_size(stage, in_world)
    map.hold_agents = (stage.globals or {})[HOLD_SLOT] == HOLD_ALL
    map.commander   = stage.objectives and stage.objectives.special_end or false
    map.next_id     = #map.objects + 1

    local flags = stage.objectives or {}
    local function add(kind, label, optional)
        if not MapFile.objective(map, kind) then
            map.objectives[#map.objectives + 1] = { type = kind, label = label, optional = optional }
        end
    end
    for _, spec in ipairs(goals and goals.objectives or {}) do
        if spec.type == "destroy" or spec.type == "destroy_targets" then
            add("targets", spec.label)
        elseif spec.type == "rescue_people" then
            local optional = spec.optional
            if optional == nil then optional = not flags.rescue end
            add("rescue", spec.label, optional or nil)
        elseif spec.type == "sabotage" then
            add("sabotage", spec.label)
        end
    end
    if not flags.rescue then add("rescue", nil, true) end
    map.vehicle = goals and goals.vehicle or nil
    return map
end

return MapCompiler
