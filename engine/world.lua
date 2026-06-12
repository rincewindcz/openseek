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

  -- Enemy tank classes ship no sprite; give them the shared orange tank art,
  -- anchored on its visible center so it rotates cleanly to its aim.
  local etank = self:_enemy_tank_render()
  if etank then
    for i, c in ipairs(self.stage.classes) do
      if c.kind_name == "tank" and not self.images[i] then
        self.images[i] = etank
      end
    end
  end

  self.entities   = {}
  self.decals     = {}
  self.objects    = {}
  self.combatants = {}
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
    self.entities[id] = entity
    local list = cls.kind == 15 and self.decals or self.objects
    list[#list + 1] = entity
    local td = entity.type_data
    if td and td.weapon and (td.detection_radius or 0) > 0 then
      self.combatants[#self.combatants + 1] = entity
    end
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

-- Shared enemy-tank sprite (frame 15, east-facing) with an art-center anchor so
-- the normal renderer rotates it about its visible middle. Loaded once.
function World:_enemy_tank_render()
  if self._etank ~= nil then return self._etank or nil end
  local path = "assets/stage00/etank_f15.png"
  if not love.filesystem.getInfo(path) then
    self._etank = false
    return nil
  end
  local img = love.graphics.newImage(path)
  img:setFilter("nearest", "nearest")
  local cx, cy = img:getWidth() / 2, img:getHeight() / 2
  local ok, data = pcall(love.image.newImageData, path)
  if ok then
    local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
    for py = 0, data:getHeight() - 1 do
      for px = 0, data:getWidth() - 1 do
        local _, _, _, a = data:getPixel(px, py)
        if a > 0 then
          if px < x0 then x0 = px end
          if px > x1 then x1 = px end
          if py < y0 then y0 = py end
          if py > y1 then y1 = py end
        end
      end
    end
    if x1 >= 0 then cx = (x0 + x1 + 1) / 2; cy = (y0 + y1 + 1) / 2 end
  end
  self._etank = { img = img, ox = -cx, oy = -cy }
  return self._etank
end

-- World position the player spawns at: the friendly heliport pad (h.bin / lh.bin)
-- if the stage has one, otherwise the world center.
function World:player_start()
  for _, e in ipairs(self.entities) do
    local cls = self.stage.classes[e.class_idx + 1]
    local file = cls and cls.asset and self.stage.assets[cls.asset + 1]
    local fname = file and file.file
    if fname == "h.bin" or fname == "lh.bin" then
      return e.x, e.y
    end
  end
  local c = self.stage.world_size / 2
  return c, c
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
