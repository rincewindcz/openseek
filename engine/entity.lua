local Class = require "engine.class"
local json  = require "lib.json"

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

function Entity:init(id, stage_ent, stage_cls)
  self.id           = id
  self.class_idx    = stage_ent.class
  self.x            = stage_ent.x
  self.y            = stage_ent.y
  self.angle        = 0
  self.hp           = stage_cls.hit_points
  self.max_hp       = stage_cls.hit_points
  self.state        = "idle"
  self.state_before = nil
  self.route        = stage_ent.route
  self.route_pt     = 1
  self.type_data    = Entity.type_for(stage_cls.kind_name)
  self.anim         = nil

  -- Damage visual effects
  self._damage_smokes = {}   -- {anim, ox, oy} — persistent looping smoke per HP tier
  self._hit_smokes    = {}   -- {anim, ox, oy} — one-shot SMOKE2 on hit
end

-- Entity is hittable and should be drawn while idle/animating/patrol/attack.
-- Exploding entities are "logically gone" — projectiles pass through them.
function Entity:is_alive()
  return self.state ~= "dead" and self.state ~= "exploding"
end

function Entity:take_damage(amount)
  if not self:is_alive() then return end
  self.hp = self.hp - amount
  if self.hp <= 0 then
    self.hp = 0
    self:_start_death()
  end
end

-- Spawn a one-shot SMOKE2 hit effect at the entity's position with a small random offset.
function Entity:on_hit()
  if not self:is_alive() then return end
  local Animation = require "engine.animation"
  local anim = Animation.new("smoke2")
  if anim:is_done() then return end  -- clip not found / empty
  self._hit_smokes[#self._hit_smokes + 1] = {
    anim = anim,
    ox   = (math.random() - 0.5) * 12,
    oy   = (math.random() - 0.5) * 12,
  }
end

function Entity:play_anim(clip_name)
  local Animation = require "engine.animation"
  local anim = Animation.new(clip_name)
  if anim.clip:is_empty() then return end
  anim:reset()
  self.anim         = anim
  self.state_before = (self.state ~= "animating") and self.state or self.state_before
  self.state        = "animating"
end

function Entity:_start_death()
  local Animation = require "engine.animation"
  local explosion = (self.type_data and self.type_data.explosion) or "none"
  self.anim  = Animation.new("explosion_" .. explosion)
  self.state = self.anim:is_done() and "dead" or "exploding"
  -- Large entities leave a persistent crater decal once destroyed.
  if self.type_data and self.type_data.crater then
    local clip = Animation.clip("crater")
    self.crater_img = clip and clip.frames[1] or nil
  end
  -- Clear smoke effects when dying
  self._damage_smokes = {}
  self._hit_smokes    = {}
end

function Entity:update(dt)
  -- Explosion / overlay animation
  if (self.state == "exploding" or self.state == "animating") and self.anim then
    self.anim:update(dt)
    if self.anim:is_done() then
      if self.state == "exploding" then
        self.state = "dead"
      else
        self.state = self.state_before or "idle"
        self.state_before = nil
      end
    end
  end

  if not self:is_alive() then return end

  -- Persistent damage smoke: threshold by HP percentage
  if self.max_hp > 0 then
    local pct    = self.hp / self.max_hp
    local target = 0
    if pct < 0.6 then target = 1 end
    if pct < 0.4 then target = 2 end
    if pct < 0.2 then target = 3 end

    while #self._damage_smokes < target do
      local Animation = require "engine.animation"
      local anim = Animation.new("smoke")
      self._damage_smokes[#self._damage_smokes + 1] = {
        anim = anim,
        ox   = (math.random() - 0.5) * 20,
        oy   = (math.random() - 0.5) * 20,
      }
    end
    while #self._damage_smokes > target do
      table.remove(self._damage_smokes)
    end

    for _, se in ipairs(self._damage_smokes) do
      se.anim:update(dt)
      if se.anim:is_done() then
        se.anim:reset()
        se.ox = (math.random() - 0.5) * 20
        se.oy = (math.random() - 0.5) * 20
      end
    end
  end

  -- One-shot hit smokes
  local live = {}
  for _, hs in ipairs(self._hit_smokes) do
    hs.anim:update(dt)
    if not hs.anim:is_done() then live[#live + 1] = hs end
  end
  self._hit_smokes = live
end

-- Returns rotation in radians for g.draw().
function Entity:draw_angle_rad(angle_steps)
  if angle_steps <= 1 then return 0 end
  return (self.angle - 90) * math.pi / 180
end

return Entity
