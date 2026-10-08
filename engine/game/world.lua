-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local json      = require "lib.json"
local Entity    = require "engine.game.entity"
local Animation = require "engine.core.animation"
local Rng       = require "engine.core.rng"
local Debris    = require "engine.game.debris"
local Log       = require "engine.core.log"

-- Class flag bit of the player's own base buildings (tested at spawn by the
-- original, 0x1f64e4). The player's fire cannot harm them (see Entity:take_damage).
local BASE_FLAG       = 0x40
local BASE_HIT_POINTS = 100
-- Class flag bits of the radars and radio towers whose loss makes the ground
-- and helicopter missiles track more loosely (counted in World.homing_jam).
local RADAR_FLAG      = 0x10
local TOWER_FLAG      = 0x20
-- Stage class behaviour of a soldier-kind class that is a proximity mine.
local MINE_BEHAVIOUR  = 2

-- Dust puff a landing shard leaves, per mission digit (DUST.BIN of that
-- mission); missions without their own use mission 0's.
local DUST_CLIP    = "dust"

-- Ground fill colors per mission (palette entry 49 of STAGE0M/PAL1.BIN, 6-bit DAC to 8-bit).
local MISSION_GROUND = {
    ["0"] = { 178 / 255, 125 / 255, 81 / 255  },
    ["1"] = { 195 / 255, 195 / 255, 215 / 255 },
    ["2"] = { 138 / 255, 125 / 255, 81 / 255  },
    ["3"] = { 81  / 255, 28  / 255, 0         },
    ["4"] = { 150 / 255, 125 / 255, 97 / 255  },
}
local DEFAULT_GROUND = { 0.3, 0.5, 0 }

-- Missions rendered without a sun (the volcanic phases): helicopter ground
-- shadows are disabled there. Keyed by mission digit, like MISSION_GROUND.
local NIGHT_MISSIONS = { ["3"] = true }

-- Per-mission night lighting (consumed by LightFX). ambient is the dimmed floor
-- colour the scene multiplies down to; headlight is the vehicle beam: reach is
-- how far ahead the lit pool sits and radius its size (world units), spread the
-- cone half-angle (radians), color/intensity the warm lamp, gap the lamp offset
-- from the vehicle centre. Missing missions fall back to LightFX defaults.
local NIGHT_PARAMS = {
    ["3"] = {
        ambient   = { 0.46, 0.49, 0.60 },
        headlight = { reach = 42, radius = 38, spread = 0.6,
                      color = { 1.0, 0.92, 0.72 }, intensity = 1.2, gap = 6 },
    },
}

local World = Class()

-- A stage holds thousands of static props, so per-tick scans go through these
-- load-time lookups instead of the full entity lists.
--
-- Decals and objects are y-sorted once at load and never re-sorted; only route
-- units, hangar tanks and wandering soldiers move afterwards. A y-range query therefore
-- binary-searches the load-time y of the static entries and checks the few
-- mobile ones separately. ys[i] is list[i]'s load-time y; movers holds the
-- ascending list indices of the mobile entries.
local function build_y_index(list)
    local ys, movers = {}, {}
    for i, e in ipairs(list) do
        ys[i] = e.y
        e.mobile = (e.route_points or e.hideable or e.wanders) and true or false
        if e.mobile then movers[#movers + 1] = i end
    end
    return { ys = ys, movers = movers }
end

-- First and last list index whose load-time y lies in [y0, y1] (i0 > i1 if none).
local function y_span(ys, y0, y1)
    local lo, hi = 1, #ys + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if ys[mid] < y0 then lo = mid + 1 else hi = mid end
    end
    local i0 = lo
    hi = #ys + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if ys[mid] <= y1 then lo = mid + 1 else hi = mid end
    end
    return i0, lo - 1
end

-- Two-part objects folded at load: a co-located top sprite riding a hull. top is
-- matched by asset filename; hull by kind or asset; spin (deg/s) makes the top
-- rotate on its own (radar dish), nil means the AI aims it (tank turret).
local TURRET_DEFS = {
    { top_match = "tanktop%.bin$",  hull_kind  = "tank" },
    { top_match = "^tankt2%.bin$",  hull_kind  = "tank" },
    { top_match = "^radarsp%.bin$", hull_asset = "radar.bin", spin = 110 },
}

-- Hangar assets that hide a co-located tank: the hut renders above the tank and
-- shields it until the tank rides out to fire (see World:_link_hangar_tanks).
local HIDE_TANK_HANGARS = { ["shut.bin"] = true, ["jhanger.bin"] = true }

-- Stage class kinds of the people objectives (loader jump table 0x1f5818).
local KIND_POW_MARKER = 9    -- powhere.bin flag over a building holding people
local KIND_PERSON     = 11   -- a person placed on the stage (the crash-site crews)
local KIND_PAD        = 14   -- lh.bin / landhere.bin landing pad

-- Pad class behaviour: people run out of the linked building to the vehicle.
-- Any other value makes it an agent drop pad (counted at 0x1f6501).
local PAD_PICKUP = 1

-- The class every walking person is spawned from (0x203b80), and the spinning
-- body one leaves when shot (0x2039e0): the same sheet, from frame 128.
local WALKER_CLASS = 20

function World:init()
    self.stage       = nil   -- decoded JSON table
    self.stage_name  = nil
    self.time        = 0     -- simulation clock: accumulated fixed dt since the stage loaded
    self.rng         = Rng:new(0)   -- simulation randomness; reseeded per phase
    self.debris      = Debris:new(self)   -- explosion shards (presentation, engine/game/debris.lua)
    self.stages      = {}    -- sorted list of available stage names
    self.stage_index = 1
    self.images      = {}    -- class index+1 -> {img, ox, oy} or nil
    self.entities    = {}    -- all Entity instances
    self.decals      = {}    -- Entity instances with kind == 15, y-sorted
    self.objects     = {}    -- all other Entity instances, y-sorted
    self.decal_index  = nil  -- y lookup over decals (see build_y_index)
    self.object_index = nil  -- y lookup over objects
    self.combatants  = {}    -- entities that can target and fire on the player
    self.hittable    = {}    -- entities with a hit radius, in entity order
    self.updaters    = {}    -- entities with hit points, a route or a turret, in entity order
    self.awake       = {}    -- other entities while an effect plays on them (World:wake)
    self.droppers    = {}    -- entities that may drop a power-up on death, in entity order
    self.max_collision_radius = 0   -- largest solid collision radius, bounds World:blocked
    Entity.load_types("data/entity_types.json")
    -- Hand fixes over the original stage data (see World:_override).
    local raw = love.filesystem.read("data/overrides.json")
    self.overrides = raw and json.decode(raw) or {}
    self.overrides.assets = self.overrides.assets or {}
    self.overrides.stages = self.overrides.stages or {}
    -- The original's enemy rules: firing (EnemyFire) and how its units move.
    local rules = love.filesystem.read("data/enemy_weapons.json")
    if not rules then error("missing data/enemy_weapons.json") end
    self.enemy_rules = json.decode(rules)
    self:_discover()
end

-- A hand fix from data/overrides.json for one entity field: the current stage's
-- entry for the sprite file wins, then the entry for the sprite file in every
-- stage; nil when neither sets the field. Fields: explosion, drop (a pickup
-- kind, true for a random pickup, false for none).
function World:_override(asset_file, field)
    local stage = self.overrides.stages[self.stage_name]
    local entry = stage and stage[asset_file]
    if entry and entry[field] ~= nil then return entry[field] end
    entry = self.overrides.assets[asset_file]
    if entry then return entry[field] end
end

-- The original's power-up drop for a structure class (death handler 0x1fea2f):
-- "medal" for the forced drop (behaviour 1), false when the class has no drop
-- entry, else true (a random pickup). nil for other kinds and for stage exports
-- that predate the class fields.
function World:_class_drop(cls)
    if cls.kind_name ~= "structure" or cls.drop == nil then return nil end
    if cls.behaviour == 1 then return "medal" end
    return cls.drop >= 0
end

-- The original's blast for a structure class (death handler 0x1fea54): the
-- ring blast for destroy targets and forced-drop classes, the small one for a
-- class with a drop entry, the fire puff for the rest. nil for other kinds and
-- for stage exports that predate the class fields.
function World:_class_explosion(cls)
    if cls.kind_name ~= "structure" or cls.drop == nil then return nil end
    if cls.is_target or cls.behaviour == 1 then return "medium" end
    return cls.drop >= 0 and "small" or "fire"
end

function World:_discover()
    self.stages = {}
    for _, item in ipairs(love.filesystem.getDirectoryItems("assets")) do
        local name = item:match("^(stage%d+)%.json$")
        if name then self.stages[#self.stages + 1] = name end
    end
    table.sort(self.stages)
    if #self.stages == 0 then
        error("no assets/stageXX.json found - run tools/build_pack.py first")
    end
end

-- Missions present in the pack: 2 in the shareware release, 5 registered.
function World:mission_count()
    local count = 0
    for _, name in ipairs(self.stages) do
        count = math.max(count, (tonumber(name:match("^stage(%d)")) or 0) + 1)
    end
    return count
end

function World:load(name)
    local data = love.filesystem.read("assets/" .. name .. ".json")
    if not data then error("stage not found: " .. name) end
    self.stage      = json.decode(data)
    self.stage_name = name
    self.time       = 0   -- a fresh stage restarts the simulation clock
    for i, s in ipairs(self.stages) do
        if s == name then self.stage_index = i end
    end

    self.images = {}
    local cache = {}
    local function load_img(file)
        local path = "assets/" .. name .. "/" .. file
        if not cache[path] and love.filesystem.getInfo(path) then
            cache[path] = love.graphics.newImage(path)
            cache[path]:setFilter("nearest", "nearest")
        end
        return cache[path]
    end
    for i, c in ipairs(self.stage.classes) do
        if c.render then
            local img = load_img(c.render.image)
            if img then
                local entry = { img = img, ox = c.render.ox, oy = c.render.oy }
                -- Unit kinds (soldiers) carry a sibling dead-pose frame, exported as
                -- {stem}_f{frame_base + dead_frame_offset}.png; load it as the corpse.
                local dead_frame_offset = Entity.type_for(c.kind_name).dead_frame_offset
                if dead_frame_offset then
                    local dframe = math.max(0, c.frame_base or 0) + dead_frame_offset
                    local dfile  = c.render.image:gsub("_f%d+%.png$", "_f" .. dframe .. ".png")
                    entry.dead = load_img(dfile)
                end
                self.images[i] = entry
            end
        end
    end

    -- Destruction-crater art is per-mission: each world ships its own HOLE4038
    -- variant, exported into that mission's phase-0 dir. Pick it by the stage's
    -- mission digit, falling back to mission 0 for worlds without their own.
    self.crater_img = self:_load_crater(name)

    -- A tank is stored as two co-located entities: the hull (kind "tank") and a
    -- separate top on top of a hull (tank turret, radar dish). Classify each class
    -- as a turret-top (-> its TURRET_DEF) or a hull candidate so we can fold them.
    local top_class  = {}   -- class index -> turret def
    local hull_class = {}   -- class index -> true
    -- Objective classes (see objectives block in the stage JSON): destroy targets
    -- carry the is_target flag; the people objectives go by class kind.
    local target_class        = {}
    local rescue_zone_class   = {}
    local rescue_people_class = {}
    -- Landing pads. The class names the entity each one belongs to (parent_class,
    -- an index into the stage's entity list, resolved by the original at 0x1f68f0)
    -- and, by its behaviour, whether people are picked up or an agent dropped.
    local pad_class           = {}
    for _, c in ipairs(self.stage.classes) do
        local a     = c.asset and self.stage.assets[c.asset + 1]
        local fname = a and a.file and a.file:lower()
        for _, def in ipairs(TURRET_DEFS) do
            if fname and def.top_match and fname:match(def.top_match) then
                top_class[c.index] = def
            end
            if (def.hull_kind and c.kind_name == def.hull_kind)
            or (def.hull_asset and fname == def.hull_asset) then
                hull_class[c.index] = true
            end
        end
        if c.is_target then target_class[c.index] = true end
        if c.kind == KIND_POW_MARKER and fname and fname:match("powhere") then
            rescue_zone_class[c.index] = true
        elseif c.kind == KIND_PERSON then
            rescue_people_class[c.index] = true
        elseif c.kind == KIND_PAD then
            pad_class[c.index] = true
        end
    end

    self.entities      = {}
    self.decals        = {}
    self.objects       = {}
    self.combatants    = {}
    self.mines         = {}   -- enemy proximity mines (EnemyFire:mine)
    self.homing_jam    = { ground = 0, air = 0 }   -- radars / radio towers lost this phase
    -- Trivia of the phase for the crash picture (EXTRA crash_stats): written by
    -- the simulation through World:count, never read back by it.
    self.tally         = { pixels = 0, shots = 0, hits = 0, rounds = 0, trees = 0, expired = 0 }
    self.targets       = {}   -- destroy-objective entities (class is_target)
    self.rescue_zones  = {}   -- powhere.bin markers over the buildings holding people
    self.rescue_people = {}   -- {ent, home}: people standing by the wreck they wait at
    self.land_zones    = {}   -- {ent, building}: pickup pads (owned by RescueSystem)
    self.saboteur_pads = {}   -- {ent, building}: agent drop pads (owned by SaboteurSystem)
    self.home_entity   = nil  -- friendly base pad (basecirc.bin, or h.bin): spawn + return point
    self.debris:reset()
    self.ground_fx     = {}   -- dust left on the ground when a shard lands {anim, x, y}
    self.heli_spawns   = {}   -- {x, y, behaviour, respawn, leash} enemy helicopter posts (not drawn)
    self.route_states  = {}   -- route index -> {halts, finished}, shared by the units on it
    self.route_units   = {}   -- route units that give way to a player on the ground
    self.air_units     = {}   -- live enemy helicopters (owned by the heli system)

    -- First pass: build every entity and index hulls by exact position.
    local created  = {}
    local hull_at  = {}
    local movement = self.enemy_rules.movement
    local wander   = self.enemy_rules.soldier.wander
    for id, raw in ipairs(self.stage.entities) do
        local cls    = self.stage.classes[raw.class + 1]
        local entity = Entity:new(id, raw, cls)
        entity.world         = self   -- backref so a dying building can spawn world shrapnel
        entity.kind_name     = cls.kind_name
        -- People held inside (class +0x0c), walked out by the RescueSystem.
        if cls.kind_name == "structure" and (cls.pows or 0) > 0 then entity.pows = cls.pows end
        entity.base_building = math.floor((cls.flags or 0) / BASE_FLAG) % 2 == 1
        -- The main base building ships with no toughness (it could never be
        -- hit); friendly fire makes it a sturdy target instead of a one-hit kill.
        if entity.base_building and entity.max_hp <= 0 then
            local hp = entity.type_data.base_hit_points or BASE_HIT_POINTS
            entity.hp, entity.max_hp = hp, hp
        end
        if math.floor((cls.flags or 0) / RADAR_FLAG) % 2 == 1 then
            entity.homing_jam = "ground"
        elseif math.floor((cls.flags or 0) / TOWER_FLAG) % 2 == 1 then
            entity.homing_jam = "air"
        end
        -- The class behaviour is a gun's firing routine and a soldier's weapon;
        -- a soldier-kind class with the mine behaviour is a proximity mine.
        if cls.kind_name == "flak_turret" then
            entity.fire_routine = cls.behaviour or 0
        elseif cls.kind_name == "soldier" or cls.kind_name == "soldier_aggressive" then
            if cls.behaviour == MINE_BEHAVIOUR then
                entity.mine      = true
                entity.type_data = Entity.type_for("mine")
            else
                entity.fire_mode = cls.behaviour or 0
                entity.wanders   = wander[tostring(entity.fire_mode)] ~= nil
            end
        end
        -- For a hull or a truck the class behaviour is how it moves.
        local modes = movement[cls.kind_name]
        entity.move_mode = modes and modes[tostring(cls.behaviour or 0)] or nil
        -- Craters are for large static buildings only. Keying on kind "structure"
        -- excludes vehicles/turrets (tank, truck, flak), and the size gate excludes
        -- small machinery filed under "structure" (jeeps, ammo packs).
        local r = self.images[raw.class + 1]
        if cls.kind_name == "structure" and r and r.img then
            local w, h = r.img:getDimensions()
            if math.max(w, h) >= 28 then
                entity.crater_eligible = true
                entity.crater_src      = self.crater_img
            end
        end
        -- Per-sprite enemy weapon override (e.g. gun1 fires rockets, sguntop fires fire).
        local af = cls.asset and self.stage.assets[cls.asset + 1]
        if af and af.file then
            local fn = af.file:lower()
            entity.asset_file    = fn
            entity.explosion     = self:_override(fn, "explosion") or self:_class_explosion(cls)
            local drop = self:_override(fn, "drop")
            if drop == nil then drop = self:_class_drop(cls) end
            if type(drop) == "string" then
                entity.drop_kind = drop
            else
                entity.drop_random = drop   -- nil: no class data, the size rule decides
            end
            -- Friendly base / spawn pad. Every stage marks it with basecirc.bin at a
            -- fixed spot (~2180,2171); the home one is the first basecirc (later ones
            -- sit under landhere/lh objective zones). Missions 0 and 3 also stamp an
            -- h.bin heliport on the same spot, which takes precedence when present.
            -- helipad/landhere/lh are objective drop zones, not the home.
            if fn == "h.bin" then
                self.home_entity = entity
            elseif fn == "basecirc.bin" and not self.home_entity then
                self.home_entity = entity
            end
        end
        -- Resolve patrol waypoints (route index is 0-based into stage.routes).
        if entity.route ~= nil and self.stage.routes then
            local route = self.stage.routes[entity.route + 1]
            entity.route_points = route and route.points or nil
            if entity.route_points then
                local state = self.route_states[entity.route] or { halts = 0, finished = false }
                self.route_states[entity.route] = state
                entity.route_state = state
            end
        end
        created[id] = entity
        if hull_class[raw.class] then
            hull_at[raw.x .. "," .. raw.y] = entity
        end
    end

    -- The structure a pad or a placed person belongs to, or nil when the class
    -- names none (a stage built without the link leaves them plain scenery).
    local function linked_structure(cls)
        local e = created[(cls.parent_class or -1) + 1]
        return e and e.kind_name == "structure" and e or nil
    end

    -- Second pass: fold each turret onto its co-located hull (dropping the turret
    -- as a standalone entity); everything else joins the dense entity list and the
    -- draw/combat lists. self.entities must stay hole-free for ipairs consumers.
    for id, raw in ipairs(self.stage.entities) do
        local entity = created[id]
        local cls    = self.stage.classes[raw.class + 1]
        local tdef   = top_class[raw.class]
        local hull   = tdef and hull_at[raw.x .. "," .. raw.y]
        local r      = tdef and self.images[raw.class + 1]
        if hull and r then
            -- Fold the turret onto its co-located hull, dropping it as a standalone entity.
            hull:attach_turret({ img = r.img, ax = -r.ox, ay = -r.oy }, tdef.spin, cls)
            hull.fire_routine = cls.behaviour or 0   -- the tank fires what its turret does
        elseif cls.kind_name == "enemy_helicopter" then
            -- Enemy helicopters are not placed units: each marks a spawn point for the
            -- airborne heli system and is never drawn or hit in place.
            self.heli_spawns[#self.heli_spawns + 1] = { x = raw.x, y = raw.y, behaviour = cls.behaviour,
                respawn = cls.field_2c, leash = cls.field_2e }
        elseif pad_class[raw.class] and cls.behaviour == PAD_PICKUP and linked_structure(cls) then
            -- A pickup pad is drawn and removed by the RescueSystem, not the world.
            self.land_zones[#self.land_zones + 1] = { ent = entity, building = linked_structure(cls) }
        else
            self.entities[#self.entities + 1] = entity
            local list = cls.kind == 15 and self.decals or self.objects
            list[#list + 1] = entity
            if target_class[raw.class] then
                self.targets[#self.targets + 1] = entity
                entity.objective = true   -- white dot on the radar, glint in the world
            end
            if rescue_zone_class[raw.class] then
                self.rescue_zones[#self.rescue_zones + 1] = entity
                entity.objective   = true
                entity.rescue_zone = true   -- the flag stands over its building (Renderer)
                -- The marker is a child of the entity stored just before it (0x1f5fc7).
                local building = created[id - 1]
                if building and building.pows then building.pow_marker = entity end
            end
            if rescue_people_class[raw.class] and linked_structure(cls) then
                self.rescue_people[#self.rescue_people + 1] = { ent = entity, home = linked_structure(cls) }
                entity.objective = true
            end
            -- Any other linked pad is an agent drop pad. It stays an ordinary object
            -- (drawn by the renderer) until the SaboteurSystem claims it, hiding and
            -- redrawing it with a fade.
            if pad_class[raw.class] and linked_structure(cls) then
                self.saboteur_pads[#self.saboteur_pads + 1] = { ent = entity, building = linked_structure(cls) }
            end
            if entity:is_combatant() then
                self.combatants[#self.combatants + 1] = entity
            end
            if entity.mine then self.mines[#self.mines + 1] = entity end
            if entity.route_points and entity.move_mode and entity.move_mode.yields then
                self.route_units[#self.route_units + 1] = entity
            end
        end
    end
    -- Pair each hangar tank with the hut over it before the draw order is fixed,
    -- so the hut's sort_bias can lift it above its tank.
    self:_link_hangar_tanks()

    local by_y = function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        -- Stable tiebreak for entities at one spot; sort_bias lifts a hangar hut
        -- past its tank so it always draws on top.
        return a.id + (a.sort_bias or 0) < b.id + (b.sort_bias or 0)
    end
    table.sort(self.decals,  by_y)
    table.sort(self.objects, by_y)
    self.decal_index  = build_y_index(self.decals)
    self.object_index = build_y_index(self.objects)

    -- Subsets for the per-tick scans. Entity:_start_death drops a power-up only
    -- from drop_kind, drop_random or crater_eligible entities, all fixed at load.
    self.hittable, self.droppers, self.updaters, self.awake = {}, {}, {}, {}
    self.max_collision_radius = 0
    for _, e in ipairs(self.entities) do
        local td = e.type_data
        if td and (td.hit_radius or 0) > 0 then self.hittable[#self.hittable + 1] = e end
        if e.drop_kind or e.drop_random or e.crater_eligible then self.droppers[#self.droppers + 1] = e end
        e.prop = not (e.max_hp > 0 or e.route_points or e.has_turret)
        if not e.prop then self.updaters[#self.updaters + 1] = e end
    end
    for _, e in ipairs(self.objects) do
        local td = e.type_data
        if td and td.solid then
            self.max_collision_radius = math.max(self.max_collision_radius, td.collision_radius or 8)
        end
    end

    self:_fit_wrap_period()
    Log.info("world", "loaded %s: %d entities", name, #self.entities)
end

-- Set up every hangar tank: a hull whose class behaviour is a ride
-- (data/enemy_weapons.json "movement"). It slides out of its hut along a fixed
-- heading and back in; combat drives the ride (_update_hangar). The hut over it
-- shields the tank while it is inside and is drawn above it; the hut's own
-- destructibility is unchanged.
function World:_link_hangar_tanks()
    for _, tank in ipairs(self.entities) do
        local mode = tank.move_mode
        if mode and mode.ride_heading then
            local hut
            for _, e in ipairs(self.entities) do
                if e.asset_file and HIDE_TANK_HANGARS[e.asset_file]
                and math.abs(e.x - tank.x) < 24 and math.abs(e.y - tank.y) < 24 then
                    hut = e
                    break
                end
            end
            self:_setup_hangar(tank, hut, mode)
        end
    end
end

function World:_setup_hangar(tank, hut, mode)
    local rules = self.enemy_rules
    if hut then
        tank.hideout  = hut
        -- Draw the hut just after (above) its tank at the same spot.
        hut.sort_bias = (tank.id - hut.id) + 0.5
    end

    -- The hull keeps its facing: it only slides out and back, it never turns.
    -- The gun is parked until the tank is half way out.
    local rad = (mode.ride_heading - 90) * math.pi / 180
    tank.hide_angle    = mode.ride_facing
    tank.hide_axis     = { x = math.cos(rad), y = math.sin(rad) }
    tank.hide_home     = { x = tank.x, y = tank.y }
    tank.hide_speed    = mode.ride_step * rules.tick_rate
    tank.hide_extend   = mode.ride_step * rules.movement.ride.ticks
    tank.hide_pos      = 0
    tank.ride_dir      = 0
    tank.aim_angle     = rules.movement.ride.park
    tank.hidden        = true
    tank.hide_shielded = hut ~= nil
    tank.hideable      = true
end

-- Some stages (mission 0 phases 0-2) inset their content ~48px from the world
-- edges: the field spans e.g. [48, 4047] inside a 4096 world. Wrapped at 4096
-- that leaves a bare band straddling each seam. The field width is the natural
-- wrap period (the right edge continues into the left: 4047 + 1 == 48 mod 4000),
-- so shrink world_size to the field extent and every system that wraps on it
-- (player movement, World:delta, Camera:tiles, the renderer passes) lines up and
-- the seam disappears. Full-bleed stages already reach the edges and keep 4096.
function World:_fit_wrap_period()
    local s = self.stage.world_size
    local lo_x, lo_y, hi_x, hi_y = s, s, 0, 0
    local function bounds(list)
        for _, e in ipairs(list) do
            if e.x < lo_x then lo_x = e.x end
            if e.x > hi_x then hi_x = e.x end
            if e.y < lo_y then lo_y = e.y end
            if e.y > hi_y then hi_y = e.y end
        end
    end
    bounds(self.decals); bounds(self.objects)
    if hi_x <= lo_x or hi_y <= lo_y then return end

    -- Use the smaller axis extent so the period never exceeds the content on
    -- either axis (a too-large period reopens a gap; a smaller one only overlaps).
    local period = math.min(hi_x - lo_x + 1, hi_y - lo_y + 1)
    if period < s - 32 then
        self.stage.world_size = period
    end
end

-- Crater sprite for the stage's mission. HOLE4038 is exported per mission into
-- assets/stage{M}0/; missions without their own variant reuse mission 0's.
function World:_load_crater(name)
    local mission = name:match("^stage(%d)")
    local function try(m)
        local path = "assets/stage" .. m .. "0/hole_f16.png"
        if love.filesystem.getInfo(path) then
            local img = love.graphics.newImage(path)
            img:setFilter("nearest", "nearest")
            return img
        end
    end
    return (mission and try(mission)) or try("0")
end

function World:load_index(idx)
    self:load(self.stages[idx])
end

-- Shortest signed per-axis delta (a - b) on the seamlessly wrapped (toroidal)
-- map, so distance checks keep working across the map edges. b (or a) may sit
-- outside [0, world_size); the modulo folds it back.
function World:delta(ax, ay, bx, by)
    local s  = self.stage.world_size
    local dx = (ax - bx) % s
    if dx > s * 0.5 then dx = dx - s end
    local dy = (ay - by) % s
    if dy > s * 0.5 then dy = dy - s end
    return dx, dy
end

-- Asset (.bin) filename backing a class index, or nil. Shared by the debug
-- inspector and the mission system for matching entities by sprite.
function World:asset_file(class_idx)
    local cls = self.stage.classes[class_idx + 1]
    local a   = cls and cls.asset and self.stage.assets[cls.asset + 1]
    return a and a.file or nil
end

-- Clip of the people walking on this stage: the sheet of the stage's walker
-- class in this mission's palette ("newdude3"), else that sheet from mission 0
-- for a pack exported before the per-mission clips. suffix "_dead" names the
-- body of one shot down.
function World:walker_clip(suffix)
    local file = self:asset_file(WALKER_CLASS)
    local stem = file and file:lower():match("^(%w+)%.bin$") or "pow"
    local m    = self.stage_name and self.stage_name:match("^stage(%d)") or "0"
    suffix = suffix or ""
    for _, name in ipairs({ stem .. m .. suffix, stem .. "0" .. suffix }) do
        local clip = Animation.clip(name)
        if clip and not clip:is_empty() then return name end
    end
    return stem .. m .. suffix
end

-- The phase objective block exported into the stage JSON, or nil. Drives the
-- objective banner (see Renderer:objective_status).
function World:objectives()
    return self.stage and self.stage.objectives
end

-- World position the player spawns at: the friendly base pad (basecirc.bin, or
-- the h.bin heliport stamped on it in missions 0/3), otherwise the world center.
function World:player_start()
    if self.home_entity then return self.home_entity.x, self.home_entity.y end
    local c = self.stage.world_size / 2
    return c, c
end

-- Restart the simulation randomness from a known seed. Called at the start of
-- every phase (and by replay playback with the recorded seed), so two runs of the
-- same stage with the same inputs roll the same numbers.
function World:reset_rng(seed)
    self.rng = Rng:new(seed or 0)
    self.time = 0
end

-- Position of the friendly base pad, or nil if the stage has none. The mission
-- system uses this as the return-to-base landing point.
function World:home_base()
    local e = self.home_entity
    if not e then return nil end
    return e.x, e.y
end

local function blocks(world, e, x, y, radius, ignore)
    if e == ignore or e.dormant or not e:is_alive() then return false end
    local td = e.type_data
    if not (td and td.solid) then return false end
    local dx, dy = world:delta(e.x, e.y, x, y)
    local rr = radius + (td.collision_radius or 8)
    return dx * dx + dy * dy < rr * rr
end

-- True if a circle at (x, y) with the given radius overlaps a solid entity.
-- Decals (roads, pads, ground specks) are never solid. Used for vehicle
-- collision and to veto helicopter landings over obstacles.
function World:blocked(x, y, radius, ignore)
    local objects = self.objects
    local index   = self.object_index
    local ys      = index.ys
    local n       = #ys
    if n == 0 then return false end

    -- The first blocking object in list order, as a full scan would return. Each
    -- wrapped copy of the query band maps to a disjoint, ascending index range.
    local s     = self.stage.world_size
    local reach = radius + self.max_collision_radius + 1
    local best
    for k = math.floor((ys[1] - y - reach) / s), math.ceil((ys[n] - y + reach) / s) do
        local i0, i1 = y_span(ys, y + k * s - reach, y + k * s + reach)
        for i = i0, i1 do
            local e = objects[i]
            if not e.mobile and blocks(self, e, x, y, radius, ignore) then best = i; break end
        end
        if best then break end
    end
    for _, i in ipairs(index.movers) do
        if best and i > best then break end
        if blocks(self, objects[i], x, y, radius, ignore) then best = i; break end
    end
    if best then return true, objects[best] end
    return false
end

-- Call fn(ctx, e, a, b) in list order for every entry of list (decals or
-- objects, with their index) that may lie within y [y0, y1]: the static entries
-- whose load-time y does, plus every mobile entry. fn does its own exact test.
function World.each_in_y(list, index, y0, y1, fn, ctx, a, b)
    local movers = index.movers
    local m, nm  = 1, #movers
    local i0, i1 = y_span(index.ys, y0, y1)
    for i = i0, i1 do
        while m <= nm and movers[m] < i do
            fn(ctx, list[movers[m]], a, b)
            m = m + 1
        end
        local e = list[i]
        if not e.mobile then fn(ctx, e, a, b) end
    end
    for k = m, nm do fn(ctx, list[movers[k]], a, b) end
end

-- EXTRA (explosive_trees): a tank driving into a tree pops it in a small blast
-- and clears it, rather than being stopped dead. Removes the tree from collision
-- and rendering, and spawns the burst effect and a small light.
-- Add to one of the phase's tally counters (World.tally).
function World:count(key, amount)
    self.tally[key] = self.tally[key] + (amount or 1)
end

function World:crush_tree(e)
    self:count("trees")
    e.state = "dead"
    e.hp    = 0
    if self.combat then self.combat:add_effect("explosion_small", e.x, e.y) end
    if self.lightfx then self.lightfx:explosion(e.x, e.y, "flak") end
end

-- Throw a burst of shards from (x, y): `burst` names an entry of
-- data/debris.json (a wreck, a building, a bomb blast, ...). opts.dx / opts.dy
-- aim a directional burst, opts.count sets its piece count. A one-way
-- forwarder like the lights: the shards are presentation and draw no numbers
-- from world.rng.
function World:spawn_debris(x, y, burst, opts)
    self.debris:burst(burst, x, y, opts)
end

-- A dust puff settling on the ground where a shard landed.
function World:add_ground_dust(x, y)
    local m    = self.stage_name and self.stage_name:match("^stage(%d)")
    local anim = Animation.new(DUST_CLIP .. (m or "0"))
    if anim:is_done() then anim = Animation.new(DUST_CLIP .. "0") end
    if anim:is_done() then return end
    self.ground_fx[#self.ground_fx + 1] = { anim = anim, x = x, y = y }
end

-- A prop (no hit points, route or turret) has nothing to update until an
-- explosion, animation, hit smoke or corpse slide starts on it; Entity calls
-- this then. An
-- entity update only touches its own state and a prop draws no random numbers,
-- so updating props after the updaters matches a full pass in entity order.
function World:wake(e)
    if e.prop and not e.awake then
        e.awake = true
        self.awake[#self.awake + 1] = e
    end
end

function World:update(dt)
    self.time = self.time + dt
    for _, e in ipairs(self.updaters) do
        e:update(dt)
    end
    if self.awake[1] then
        local still = {}
        for _, e in ipairs(self.awake) do
            e:update(dt)
            if e.state == "exploding" or e.state == "animating" or e._hit_smokes[1]
            or (e._death_push and e._death_t < 1) then
                still[#still + 1] = e
            else
                e.awake = nil
            end
        end
        self.awake = still
    end

    self.debris:update(dt)

    -- Ground dust plays once then clears.
    if #self.ground_fx > 0 then
        local live = {}
        for _, fx in ipairs(self.ground_fx) do
            fx.anim:update(dt)
            if not fx.anim:is_done() then live[#live + 1] = fx end
        end
        self.ground_fx = live
    end
end

-- Clip of an explosion size on this stage: the clip's own variant for the
-- mission when the pack has it (the building blast is drawn per mission, see
-- `missions` in data/animations.json), else the shared clip.
function World:explosion_clip(size)
    local name = "explosion_" .. size
    local clip = Animation.clip(name)
    local m    = self.stage_name and self.stage_name:match("^stage(%d)")
    local own  = clip and clip.missions and clip.missions[m]
    local alt  = own and Animation.clip(own)
    if alt and not alt:is_empty() then return own end
    return name
end

function World:ground_color()
    local m = self.stage_name and self.stage_name:match("^stage(%d)")
    return MISSION_GROUND[m] or DEFAULT_GROUND
end

-- Whether aircraft cast ground shadows on this stage (off on night missions).
function World:shadows_enabled()
    local m = self.stage_name and self.stage_name:match("^stage(%d)")
    return not NIGHT_MISSIONS[m]
end

-- Night missions render under a dark palette, so the player vehicle swaps to its
-- palette-matched night sprite set (see Player:_clip).
function World:is_night()
    local m = self.stage_name and self.stage_name:match("^stage(%d)")
    return NIGHT_MISSIONS[m] == true
end

-- Night lighting params for the active stage, or nil on day stages. Falls back
-- to a generic night look when a night mission defines no explicit entry.
function World:night_params()
    if not self:is_night() then return nil end
    local m = self.stage_name and self.stage_name:match("^stage(%d)")
    return NIGHT_PARAMS[m]
end

-- Forwarders so combat / entity code can drive LightFX and ImpactFX (set at
-- wiring time) through the world they already hold, without depending on the
-- app or the effect systems directly. No-ops until they are attached.
function World:explosion_light(x, y, size)
    if self.lightfx then self.lightfx:explosion(x, y, size) end
    if self.impactfx then self.impactfx:explosion(x, y, size) end
end

function World:muzzle_light(x, y)
    if self.lightfx then self.lightfx:muzzle(x, y) end
end

function World:weapon_fired(x, y, weapon_name, shooter)
    if self.impactfx then self.impactfx:fire(x, y, weapon_name) end
    if self.detailfx then self.detailfx:fire(x, y, weapon_name, shooter) end
end

-- A player round struck a target (DetailFX shell_impact); an impact explosion
-- lights and sounds like any other of its size.
function World:projectile_impact(x, y, weapon_name)
    local clip = self.detailfx and self.detailfx:impact(x, y, weapon_name)
    local size = clip and clip:match("^explosion_(%a+)")
    if size then
        self:explosion_light(x, y, size)
        self:sound("explosion." .. size, x, y)
    end
end

-- An entity died with the given explosion size (a smoking wreck, DetailFX).
function World:wreck(x, y, explosion)
    if self.detailfx then self.detailfx:wreck(x, y, explosion) end
end

function World:player_death_light(x, y)
    if self.lightfx then self.lightfx:player_death(x, y) end
    if self.impactfx then self.impactfx:player_death(x, y) end
end

-- A damaged enemy (entity or helicopter) and a hit on a player vehicle.
function World:hit_flash(target)
    if self.impactfx then self.impactfx:hit(target) end
end

function World:player_hit(x, y, player)
    if self.impactfx then self.impactfx:player_hit(x, y, player) end
end

-- Same forwarder shape for audio: simulation code names an event and where it
-- happened, the sound system decides which listener hears it, how loud and from
-- which side. A no-op until the sound system is attached, and never read back
-- into the simulation.
function World:sound(event, x, y, opts)
    if self.sound_sys then self.sound_sys:emit(event, x, y, opts) end
end

-- A radio callout. Not placed in the world: it comes over the headset.
function World:say(event, variant)
    if self.sound_sys then self.sound_sys:say(event, variant) end
end

-- Situational callouts (engine/game/sound.lua decides whether a line plays).
function World:weapon_selected(p)
    if self.sound_sys then self.sound_sys:weapon_selected(p) end
end

function World:dry_fire(p)
    if self.sound_sys then self.sound_sys:dry_fire(p) end
end

function World:pickup_taken(p, kind)
    if self.sound_sys then self.sound_sys:pickup_taken(p, kind) end
end

function World:heli_damaged(before, after)
    if self.sound_sys then self.sound_sys:heli_damaged(before, after) end
end

return World
