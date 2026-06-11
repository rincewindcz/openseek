local Class     = require "engine.class"
local json      = require "lib.json"

local entity_types = {}  -- keyed by kind_name, loaded once

local Entity = Class()

function Entity.load_types(path)
  local data = love.filesystem.read(path)
  if not data then error("missing " .. path) end
  entity_types = json.decode(data)
end

function Entity.type_for(kind_name)
  return entity_types[kind_name] or {}
end

-- stage_ent: raw entity from stage JSON {class, x, y, route}
-- stage_cls: matching class record from stage JSON
function Entity:init(id, stage_ent, stage_cls)
  self.id        = id
  self.class_idx = stage_ent.class
  self.x         = stage_ent.x
  self.y         = stage_ent.y
  self.angle     = 0            -- degrees, 0=north CW
  self.hp        = stage_cls.hit_points
  self.max_hp    = stage_cls.hit_points
  self.state     = "idle"       -- idle | patrol | attack | dead | exploding
  self.route     = stage_ent.route  -- nil if absent
  self.route_pt  = 1
  self.type_data = Entity.type_for(stage_cls.kind_name)
  self.anim      = nil          -- AnimState, set when needed
end

function Entity:is_alive()
  return self.state ~= "dead"
end

function Entity:take_damage(amount)
  if not self:is_alive() then return end
  self.hp = self.hp - amount
  if self.hp <= 0 then
    self.hp = 0
    self:_start_death()
  end
end

function Entity:_start_death()
  -- Require Animation lazily to avoid a circular dependency at load time.
  local Animation = require "engine.animation"
  local explosion = (self.type_data and self.type_data.explosion) or "none"
  local clip_name = "explosion_" .. explosion
  self.anim  = Animation.new(clip_name)
  self.state = self.anim:is_done() and "dead" or "exploding"
end

function Entity:update(dt)
  if self.state == "exploding" and self.anim then
    self.anim:update(dt)
    if self.anim:is_done() then
      self.state = "dead"
    end
  end
end

-- Returns rotation in radians for g.draw().
-- Non-rotating sprites (angle_steps <= 1): 0.
-- Rotating sprites: (entity.angle - 90) deg converts to radians,
-- because the exported PNG is the exact 90-deg frame.
function Entity:draw_angle_rad(angle_steps)
  if angle_steps <= 1 then
    return 0
  end
  return (self.angle - 90) * math.pi / 180
end

return Entity
