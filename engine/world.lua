local Class     = require "engine.class"
local json      = require "lib.json"
local Entity    = require "engine.entity"
local Animation = require "engine.animation"

-- Tumbling iron/metal shrapnel flung out by an explosion (buildings and bombs).
-- The clips loop, so each piece is bounded by its own ttl. When a piece lands a
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

local World = Class()

-- Two-part objects folded at load: a co-located top sprite riding a hull. top is
-- matched by asset filename; hull by kind or asset; spin (deg/s) makes the top
-- rotate on its own (radar dish), nil means the AI aims it (tank turret).
local TURRET_DEFS = {
  { top_match = "tanktop%.bin$",  hull_kind  = "tank" },
  { top_match = "^radarsp%.bin$", hull_asset = "radar.bin", spin = 110 },
}

function World:init()
  self.stage       = nil   -- decoded JSON table
  self.stage_name  = nil
  self.stages      = {}    -- sorted list of available stage names
  self.stage_index = 1
  self.images      = {}    -- class index+1 -> {img, ox, oy} or nil
  self.entities    = {}    -- all Entity instances
  self.decals      = {}    -- Entity instances with kind == 15, y-sorted
  self.objects     = {}    -- all other Entity instances, y-sorted
  self.combatants  = {}    -- entities that can target and fire on the player
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
        local off = Entity.type_for(c.kind_name).dead_frame_offset
        if off then
          local dframe = math.max(0, c.frame_base or 0) + off
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
    end
  end

  self.entities      = {}
  self.decals        = {}
  self.objects       = {}
  self.combatants    = {}
  self.targets       = {}   -- destroy-objective entities (class is_target)
  self.rescue_zones  = {}   -- powhere.bin landing markers (kind 9)
  self.rescue_people = {}   -- pow.bin / people.bin civilians to rescue (kind 11)
  self.home_entity   = nil  -- friendly base pad (basecirc.bin, or h.bin): spawn + return point
  self.debris        = {}   -- flying explosion shrapnel {anim, x, y, vx, vy, age, ttl}
  self.ground_fx     = {}   -- dust left on the ground when shrapnel lands {anim, x, y}

  -- First pass: build every entity and index hulls by exact position.
  local created = {}
  local hull_at = {}
  for id, raw in ipairs(self.stage.entities) do
    local cls    = self.stage.classes[raw.class + 1]
    local entity = Entity:new(id, raw, cls)
    entity.world = self   -- backref so a dying building can spawn world shrapnel
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
      local r = self.stage.routes[entity.route + 1]
      entity.route_points = r and r.points or nil
    end
    created[id] = entity
    if hull_class[raw.class] then
      hull_at[raw.x .. "," .. raw.y] = entity
    end
  end

  -- Second pass: fold each turret onto its co-located hull (dropping the turret
  -- as a standalone entity); everything else joins the dense entity list and the
  -- draw/combat lists. self.entities must stay hole-free for ipairs consumers.
  for id, raw in ipairs(self.stage.entities) do
    local entity = created[id]
    local cls    = self.stage.classes[raw.class + 1]
    local tdef = top_class[raw.class]
    if tdef then
      local hull = hull_at[raw.x .. "," .. raw.y]
      local r    = self.images[raw.class + 1]
      if hull and r then
        hull:attach_turret({ img = r.img, ax = -r.ox, ay = -r.oy }, tdef.spin)
        goto continue
      end
    end
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
    local td = entity.type_data
    if td and td.weapon and (td.detection_radius or 0) > 0 then
      self.combatants[#self.combatants + 1] = entity
    end
    ::continue::
  end
  local by_y = function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    if a.x ~= b.x then return a.x < b.x end
    return a.id < b.id  -- stable tiebreaker for entities at identical positions
  end
  table.sort(self.decals,  by_y)
  table.sort(self.objects, by_y)

  self:_fit_wrap_period()
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

-- Position of the friendly base pad, or nil if the stage has none. The mission
-- system uses this as the return-to-base landing point.
function World:home_base()
  local e = self.home_entity
  if not e then return nil end
  return e.x, e.y
end

-- True if a circle at (x, y) with the given radius overlaps a solid entity.
-- Decals (roads, pads, ground specks) are never solid. Used for vehicle
-- collision and to veto helicopter landings over obstacles.
function World:blocked(x, y, radius, ignore)
  for _, e in ipairs(self.objects) do
    if e ~= ignore and e:is_alive() then
      local td = e.type_data
      if td and td.solid then
        local cr = td.collision_radius or 8
        local dx, dy = self:delta(e.x, e.y, x, y)
        local rr = radius + cr
        if dx * dx + dy * dy < rr * rr then
          return true, e
        end
      end
    end
  end
  return false
end

-- Fling a burst of tumbling iron/metal shrapnel from (x, y), e.g. a building or
-- bomb blowing up. spread scales the scatter radius (default tight).
function World:spawn_debris(x, y, n, spread)
  n = n or (4 + math.random(0, 3))
  spread = spread or 1
  for _ = 1, n do
    local anim = Animation.new(DEBRIS_CLIPS[math.random(#DEBRIS_CLIPS)])
    if not anim:is_done() then
      local a  = math.random() * 2 * math.pi
      local sp = (40 + math.random() * 80) * spread
      self.debris[#self.debris + 1] = {
        anim = anim, x = x, y = y,
        vx = math.cos(a) * sp, vy = math.sin(a) * sp,
        age = 0, ttl = 0.6 + math.random() * 0.6,
      }
    end
  end
end

-- A dust puff settling on the ground where a shrapnel piece landed.
function World:add_ground_dust(x, y)
  local anim = Animation.new(DUST_CLIPS[math.random(#DUST_CLIPS)])
  if anim:is_done() then return end
  self.ground_fx[#self.ground_fx + 1] = { anim = anim, x = x, y = y }
end

function World:update(dt)
  for _, e in ipairs(self.entities) do
    e:update(dt)
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
      if d.age < d.ttl then
        live[#live + 1] = d
      else
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

function World:title()
  return string.format("Seek & Destroy - %s (%d entities)",
    self.stage_name, #self.stage.entities)
end

return World
