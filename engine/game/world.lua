local Class     = require "engine.core.class"
local json      = require "lib.json"
local Entity    = require "engine.game.entity"
local Animation = require "engine.core.animation"
local Mathx     = require "engine.core.mathx"
local Rng       = require "engine.core.rng"

-- Tumbling iron/metal shrapnel flung out by an explosion (buildings and bombs).
-- The clips loop, so each piece is bounded by its own lifetime. When a piece lands a
-- dust puff is left on the ground.
local DEBRIS_CLIPS = { "ironsz", "iron2sz", "metal8", "metalrt", "metalsz" }
local DUST_CLIPS   = { "dust0", "dust1", "dust2" }

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
-- Decals and objects are y-sorted once at load and never re-sorted; only tanks
-- (patrol routes, hangar ride-outs) move afterwards. A y-range query therefore
-- binary-searches the load-time y of the static entries and checks the few
-- mobile ones separately. ys[i] is list[i]'s load-time y; movers holds the
-- ascending list indices of the mobile entries.
local function build_y_index(list)
    local ys, movers = {}, {}
    for i, e in ipairs(list) do
        ys[i] = e.y
        e.mobile = (e.route_points or e.hideable) and true or false
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
    { top_match = "^radarsp%.bin$", hull_asset = "radar.bin", spin = 110 },
}

-- Hangar assets that hide a co-located tank: the hut renders above the tank and
-- shields it until the tank rides out to fire (see World:_link_hangar_tanks).
local HIDE_TANK_HANGARS = { ["shut.bin"] = true }

-- A kind-14 landing pad within this of a POWHERE marker is a rescue pad; farther
-- (or on a stage with no POWHERE) it is a saboteur drop pad. Rescue pads sit
-- 38-64px from their marker; saboteur stages carry no POWHERE at all.
local PAD_RESCUE_RADIUS = 80

function World:init()
    self.stage       = nil   -- decoded JSON table
    self.stage_name  = nil
    self.time        = 0     -- simulation clock: accumulated fixed dt since the stage loaded
    self.rng         = Rng:new(0)   -- simulation randomness; reseeded per phase
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
    self.weapon_overrides = {}   -- asset filename -> enemy weapon name
    local raw = love.filesystem.read("data/enemy_overrides.json")
    if raw then self.weapon_overrides = json.decode(raw) end
    self.building_drops = {}     -- asset filename -> forced pickup kind
    local braw = love.filesystem.read("data/building_drops.json")
    if braw then self.building_drops = json.decode(braw) end
    self.fire_rate_overrides = {}  -- stage name -> { asset filename -> shots/sec }
    local fraw = love.filesystem.read("data/enemy_fire_rates.json")
    if fraw then self.fire_rate_overrides = json.decode(fraw) end
    self.muzzle_overrides = {}     -- asset filename -> forward muzzle offset (px)
    local mraw = love.filesystem.read("data/enemy_muzzle.json")
    if mraw then self.muzzle_overrides = json.decode(mraw) end
    self:_discover()
end

function World:_discover()
    self.stages = {}
    for _, item in ipairs(love.filesystem.getDirectoryItems("assets")) do
        local name = item:match("^(stage%d+)%.json$")
        if name then self.stages[#self.stages + 1] = name end
    end
    table.sort(self.stages)
    if #self.stages == 0 then
        error("no assets/stageXX.json found - run tools/export_love2d.py first")
    end
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
    -- carry the is_target flag; rescue stages mark powhere.bin landing zones and
    -- pow.bin / people.bin civilians by sprite.
    local target_class        = {}
    local rescue_zone_class   = {}
    local rescue_people_class = {}
    -- kind-14 "land here" pads (lh.bin / landhere.bin). A pad next to a POWHERE
    -- marker is a rescue landing pad (POWs walk to it); a landhere pad with no
    -- POWHERE nearby is a saboteur drop pad. Classified by position in pass two.
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
        if fname then
            if c.kind == 9 and fname:match("powhere") then
                rescue_zone_class[c.index] = true
            end
            if c.kind == 11 and (fname:match("^pow") or fname:match("people")) then
                rescue_people_class[c.index] = true
            end
            if c.kind == 14 and (fname:match("^lh") or fname:match("^landhere")) then
                pad_class[c.index] = true
            end
        end
    end

    self.entities      = {}
    self.decals        = {}
    self.objects       = {}
    self.combatants    = {}
    self.targets       = {}   -- destroy-objective entities (class is_target)
    self.rescue_zones  = {}   -- powhere.bin landing markers (kind 9)
    self.rescue_people = {}   -- pow.bin / people.bin civilians to rescue (kind 11)
    self.land_zones    = {}   -- rescue landing pads next to a POWHERE marker (owned by RescueSystem)
    self.saboteur_pads = {}   -- landhere.bin drop pads with no POWHERE nearby (owned by SaboteurSystem)
    self.home_entity   = nil  -- friendly base pad (basecirc.bin, or h.bin): spawn + return point
    self.debris        = {}   -- flying explosion shrapnel {anim, x, y, vx, vy, age, lifetime}
    self.ground_fx     = {}   -- dust left on the ground when shrapnel lands {anim, x, y}
    self.heli_spawns   = {}   -- {x, y} spawn markers for enemy helicopters (not drawn)
    self.air_units     = {}   -- live enemy helicopters (owned by the heli system)

    -- First pass: build every entity and index hulls by exact position.
    local created     = {}
    local hull_at     = {}
    local powhere_pos = {}   -- POWHERE marker positions, to classify nearby pads
    for id, raw in ipairs(self.stage.entities) do
        local cls    = self.stage.classes[raw.class + 1]
        local entity = Entity:new(id, raw, cls)
        entity.world     = self   -- backref so a dying building can spawn world shrapnel
        entity.kind_name = cls.kind_name
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
            entity.asset_file = fn
            entity.weapon    = self.weapon_overrides[fn]
            entity.drop_kind = self.building_drops[fn]
            -- Per-stage fire-rate override (e.g. GUN1 fires faster in later phases).
            local fr = self.fire_rate_overrides[self.stage_name]
            entity.fire_rate = fr and fr[fn] or nil
            -- Forward muzzle offset so shots leave the barrel, not the hull center.
            entity.muzzle_offset = self.muzzle_overrides[fn]
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
        end
        created[id] = entity
        if hull_class[raw.class] then
            hull_at[raw.x .. "," .. raw.y] = entity
        end
        if rescue_zone_class[raw.class] then
            powhere_pos[#powhere_pos + 1] = { x = raw.x, y = raw.y }
        end
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
        elseif cls.kind_name == "enemy_helicopter" then
            -- Enemy helicopters are not placed units: each marks a spawn point for the
            -- airborne heli system and is never drawn or hit in place.
            self.heli_spawns[#self.heli_spawns + 1] = { x = raw.x, y = raw.y }
        elseif pad_class[raw.class] and self:_near_any(raw.x, raw.y, powhere_pos, PAD_RESCUE_RADIUS) then
            -- A pad by a POWHERE marker is a rescue landing pad: drawn and removed by
            -- the RescueSystem, not the world.
            self.land_zones[#self.land_zones + 1] = { ent = entity }
        else
            self.entities[#self.entities + 1] = entity
            local list = cls.kind == 15 and self.decals or self.objects
            list[#list + 1] = entity
            if target_class[raw.class] then
                self.targets[#self.targets + 1] = entity
                entity.objective = true   -- white dot on the radar, reticle in the world
            end
            if rescue_zone_class[raw.class] then
                self.rescue_zones[#self.rescue_zones + 1] = entity
                entity.objective = true
            end
            if rescue_people_class[raw.class] then
                self.rescue_people[#self.rescue_people + 1] = entity
                entity.objective = true
            end
            -- A landing pad reached here has no POWHERE nearby, so it is a saboteur drop
            -- pad (lh.bin or landhere.bin). It stays an ordinary object (drawn by the
            -- renderer) until the SaboteurSystem claims it, hiding and redrawing it with
            -- a fade.
            if pad_class[raw.class] then
                self.saboteur_pads[#self.saboteur_pads + 1] = { ent = entity }
            end
            local td = entity.type_data
            if td and td.weapon and (td.detection_radius or 0) > 0 then
                self.combatants[#self.combatants + 1] = entity
            end
        end
    end
    -- Pair each hangar hut with the tank it hides before the draw order is fixed,
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
    -- from drop_kind or crater_eligible entities, both fixed at load.
    self.hittable, self.droppers, self.updaters, self.awake = {}, {}, {}, {}
    self.max_collision_radius = 0
    for _, e in ipairs(self.entities) do
        local td = e.type_data
        if td and (td.hit_radius or 0) > 0 then self.hittable[#self.hittable + 1] = e end
        if e.drop_kind or e.crater_eligible then self.droppers[#self.droppers + 1] = e end
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
end

-- Link each hangar hut to the tank sharing its position: the tank rides out along
-- its track decal to fire and ducks back inside when the player looks its way,
-- shielded and drawn under the hut while hidden. The tank aim/fire and the hut's
-- own destructibility are unchanged; combat drives the ride-out (_update_hangar).
function World:_link_hangar_tanks()
    local huts, tracks = {}, {}
    for _, e in ipairs(self.entities) do
        if e.asset_file and HIDE_TANK_HANGARS[e.asset_file] then huts[#huts + 1] = e end
    end
    for _, d in ipairs(self.decals) do
        if d.asset_file == "tanktrak.bin" then tracks[#tracks + 1] = d end
    end
    for _, hut in ipairs(huts) do
        local tank
        for _, t in ipairs(self.entities) do
            if t ~= hut and t.kind_name == "tank"
            and math.abs(t.x - hut.x) < 24 and math.abs(t.y - hut.y) < 24 then
                tank = t
                break
            end
        end
        if tank then self:_setup_hangar(tank, hut, tracks) end
    end
end

function World:_setup_hangar(tank, hut, tracks)
    tank.hideout   = hut
    hut.hides      = tank
    hut.is_hideout = true
    -- Draw the hut just after (above) its tank at the same spot.
    hut.sort_bias  = (tank.id - hut.id) + 0.5

    -- Ride-out axis: toward the nearest track decal, else default west.
    local ax, ay, best = -1, 0, nil
    for _, tr in ipairs(tracks) do
        local dx, dy = tr.x - tank.x, tr.y - tank.y
        local d2 = dx * dx + dy * dy
        if d2 > 1 and (not best or d2 < best) then best = d2; ax, ay = dx, dy end
    end
    local len = math.sqrt(ax * ax + ay * ay)
    if len > 0 then ax, ay = ax / len, ay / len end

    -- Face the hull along its ride axis (toward the track) and keep it there: the
    -- tank only slides out and back, it never turns. The turret still aims freely.
    tank.hide_angle    = Mathx.heading_deg(ax, ay)
    tank.hide_axis     = { x = ax, y = ay }
    tank.hide_home     = { x = tank.x, y = tank.y }
    tank.hide_extend   = tank.type_data.ride_distance or 44
    tank.hide_pos      = 0
    tank.hidden        = true
    tank.hide_shielded = true
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

-- True if (x, y) lies within radius of any {x, y} point in the list (wrap-aware).
function World:_near_any(x, y, points, radius)
    local rr = radius * radius
    for _, p in ipairs(points) do
        local dx, dy = self:delta(x, y, p.x, p.y)
        if dx * dx + dy * dy <= rr then return true end
    end
    return false
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

-- The phase objective block exported into the stage JSON, or nil. Drives the
-- on-map markers and the objective banner (see Renderer:_draw_objectives).
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
    if e == ignore or not e:is_alive() then return false end
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
function World:crush_tree(e)
    e.state = "dead"
    e.hp    = 0
    if self.combat then self.combat:add_effect("explosion_small", e.x, e.y) end
    if self.lightfx then self.lightfx:explosion(e.x, e.y, "flak") end
end

-- Fling a burst of tumbling iron/metal shrapnel from (x, y), e.g. a building or
-- bomb blowing up. spread scales the scatter radius (default tight).
function World:spawn_debris(x, y, n, spread)
    n = n or (4 + self.rng:random(0, 3))
    spread = spread or 1
    for _ = 1, n do
        local anim = Animation.new(DEBRIS_CLIPS[self.rng:random(#DEBRIS_CLIPS)])
        if not anim:is_done() then
            local a  = self.rng:random() * 2 * math.pi
            local sp = (40 + self.rng:random() * 80) * spread
            self.debris[#self.debris + 1] = {
                anim = anim, x = x, y = y,
                vx = math.cos(a) * sp, vy = math.sin(a) * sp,
                age = 0, lifetime = 0.6 + self.rng:random() * 0.6,
            }
        end
    end
end

-- Fast shrapnel flung along a heading (e.g. METAL8 pieces thrown by an FFR rocket
-- impact, in the missile's travel direction). Unlike spawn_debris these fly fast,
-- fade out over their final frames, and vanish in the air instead of kicking up
-- ground dust.
function World:spawn_directional_debris(x, y, dx, dy, n, clip)
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then dx, dy = 0, -1 else dx, dy = dx / len, dy / len end
    local base = Mathx.atan2(dy, dx)
    for _ = 1, n do
        local anim = Animation.new(clip or "metal8")
        if not anim:is_done() then
            local a  = base + (self.rng:random() - 0.5) * 0.5
            local sp = 280 + self.rng:random() * 180
            self.debris[#self.debris + 1] = {
                anim = anim, x = x, y = y,
                vx = math.cos(a) * sp, vy = math.sin(a) * sp,
                age = 0, lifetime = 0.5 + self.rng:random() * 0.35,
                fade = true, fade_time = 0.22, alpha = 1,
            }
        end
    end
end

-- A dust puff settling on the ground where a shrapnel piece landed.
function World:add_ground_dust(x, y)
    local anim = Animation.new(DUST_CLIPS[self.rng:random(#DUST_CLIPS)])
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

    -- Shrapnel flies on, decelerating; when a piece's life ends it kicks up dust.
    if #self.debris > 0 then
        local live = {}
        for _, d in ipairs(self.debris) do
            d.age = d.age + dt
            d.x   = d.x + d.vx * dt
            d.y   = d.y + d.vy * dt
            local damp = math.max(0, 1 - dt * 2)
            d.vx, d.vy = d.vx * damp, d.vy * damp
            d.anim:update(dt)
            if d.fade then
                d.alpha = math.min(1, (d.lifetime - d.age) / d.fade_time)
            end
            if d.age < d.lifetime then
                live[#live + 1] = d
            elseif not d.fade then
                self:add_ground_dust(d.x, d.y)
            end
        end
        self.debris = live
    end

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

-- Forwarders so combat / entity code can drive LightFX (set at wiring time)
-- through the world they already hold, without depending on the app or the
-- effect system directly. No-ops until LightFX is attached and enabled.
function World:explosion_light(x, y, size)
    if self.lightfx then self.lightfx:explosion(x, y, size) end
end

function World:muzzle_light(x, y)
    if self.lightfx then self.lightfx:muzzle(x, y) end
end

function World:player_death_light(x, y)
    if self.lightfx then self.lightfx:player_death(x, y) end
end

-- Same forwarder shape for audio: simulation code names an event and where it
-- happened, the sound system decides which listener hears it, how loud and from
-- which side. A no-op until the sound system is attached, and never read back
-- into the simulation.
function World:sound(event, x, y, opts)
    if self.sound_sys then self.sound_sys:emit(event, x, y, opts) end
end

-- A radio callout. Not placed in the world: it comes over the headset.
function World:say(event)
    if self.sound_sys then self.sound_sys:say(event) end
end

return World
