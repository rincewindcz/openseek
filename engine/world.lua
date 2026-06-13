local Class  = require "engine.class"
local json   = require "lib.json"
local Entity = require "engine.entity"

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
  for i, c in ipairs(self.stage.classes) do
    if c.render then
      local path = "assets/" .. name .. "/" .. c.render.image
      if not cache[path] and love.filesystem.getInfo(path) then
        cache[path] = love.graphics.newImage(path)
        cache[path]:setFilter("nearest", "nearest")
      end
      self.images[i] = cache[path] and
        { img = cache[path], ox = c.render.ox, oy = c.render.oy }
        or nil
    end
  end

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

  -- First pass: build every entity and index hulls by exact position.
  local created = {}
  local hull_at = {}
  for id, raw in ipairs(self.stage.entities) do
    local cls    = self.stage.classes[raw.class + 1]
    local entity = Entity:new(id, raw, cls)
    -- Craters are for large static buildings only. Keying on kind "structure"
    -- excludes vehicles/turrets (tank, truck, flak), and the size gate excludes
    -- small machinery filed under "structure" (jeeps, ammo packs).
    local r = self.images[raw.class + 1]
    if cls.kind_name == "structure" and r and r.img then
      local w, h = r.img:getDimensions()
      if math.max(w, h) >= 28 then entity.crater_eligible = true end
    end
    -- Per-sprite enemy weapon override (e.g. gun1 fires rockets, sguntop fires fire).
    local af = cls.asset and self.stage.assets[cls.asset + 1]
    if af and af.file then
      local fn = af.file:lower()
      entity.weapon    = self.weapon_overrides[fn]
      entity.drop_kind = self.building_drops[fn]
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
end

function World:load_index(idx)
  self:load(self.stages[idx])
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
        local dx = e.x - x
        local dy = e.y - y
        local rr = radius + cr
        if dx * dx + dy * dy < rr * rr then
          return true, e
        end
      end
    end
  end
  return false
end

function World:update(dt)
  for _, e in ipairs(self.entities) do
    e:update(dt)
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
