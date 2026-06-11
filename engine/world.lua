local Class  = require "engine.class"
local json   = require "json"
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

  self.entities = {}
  self.decals   = {}
  self.objects  = {}
  for id, raw in ipairs(self.stage.entities) do
    local cls    = self.stage.classes[raw.class + 1]
    local entity = Entity:new(id, raw, cls)
    self.entities[id] = entity
    local list = cls.kind == 15 and self.decals or self.objects
    list[#list + 1] = entity
  end
  local by_y = function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end
  table.sort(self.decals,  by_y)
  table.sort(self.objects, by_y)
end

function World:load_index(idx)
  self:load(self.stages[idx])
end

function World:update(dt)
  -- placeholder for future entity simulation
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
