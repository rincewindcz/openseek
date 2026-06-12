local Class = require "engine.class"
local json  = require "lib.json"

local entity_types = {}  -- keyed by kind_name, loaded once

local Entity = Class()

local DEATH_PUSH  = 5     -- px a unit corpse slides in the shot direction
local DEATH_SLIDE = 0.12  -- seconds for the corpse slide to settle
local DROP_CHANCE = 0.5   -- chance a destroyed large building drops a power-up

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

  -- Two-part enemy (tank): a separate turret entity is folded onto the hull at
  -- load (see World:load / attach_turret). The turret tracks and fires while the
  -- hull stays put, and must be destroyed before the hull can be damaged.
  self.has_turret   = false
  self.turret_alive = false
  self.turret_fx    = nil   -- one-shot explosion played when the turret blows

  -- Enemy AI: turret/facing heading toward the player and a reload timer
  self.aim_angle    = 0
  self.reload       = 0

  -- Damage visual effects
  self._damage_smokes = {}   -- {anim, ox, oy} — persistent looping smoke per HP tier
  self._hit_smokes    = {}   -- {anim, ox, oy} — one-shot SMOKE2 on hit

  -- Corpse slide (units only): current draw offset and its animation state
  self.death_ox = 0
  self.death_oy = 0
end

-- Entity is hittable and should be drawn while idle/animating/patrol/attack.
-- Exploding entities are "logically gone" — projectiles pass through them.
function Entity:is_alive()
  return self.state ~= "dead" and self.state ~= "exploding"
end

function Entity:take_damage(amount, dx, dy)
  if not self:is_alive() then return end
  -- While the turret stands it absorbs all incoming damage; the hull is only
  -- vulnerable once the turret is gone.
  if self.turret_alive then
    self.turret_hp = self.turret_hp - amount
    if self.turret_hp <= 0 then
      self.turret_hp = 0
      self:_destroy_turret()
    end
    return
  end
  self.hp = self.hp - amount
  if self.hp <= 0 then
    self.hp = 0
    self:_start_death(dx, dy)
  end
end

-- Fold a co-located turret entity onto this hull. render = {img, ax, ay} drawn
-- by the renderer, rotated to aim_angle about (ax, ay).
function Entity:attach_turret(render)
  self.turret_render = render
  self.has_turret    = true
  self.turret_alive  = true
  self.turret_max_hp = (self.type_data and self.type_data.turret_hp)
    or math.max(1, math.floor((self.max_hp or 1) * 0.5))
  self.turret_hp = self.turret_max_hp
end

function Entity:_destroy_turret()
  local Animation = require "engine.animation"
  self.turret_alive = false
  local ex = (self.type_data and self.type_data.turret_explosion) or "medium"
  local fx = Animation.new("explosion_" .. ex)
  self.turret_fx = (not fx:is_done()) and fx or nil
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

function Entity:_start_death(dx, dy)
  local Animation = require "engine.animation"
  local explosion = (self.type_data and self.type_data.explosion) or "none"
  self.anim  = Animation.new("explosion_" .. explosion)
  self.state = self.anim:is_done() and "dead" or "exploding"
  -- Unit corpses (soldiers) get nudged in the direction of the killing shot.
  if dx and dy and self.type_data and self.type_data.sprite then
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0 then
      self._death_push = { x = dx / len * DEATH_PUSH, y = dy / len * DEATH_PUSH }
      self._death_t    = 0
    end
  end
  -- Only large static buildings leave a crater (set on the entity at load).
  if self.crater_eligible then
    local clip = Animation.clip("crater")
    self.crater_img = clip and clip.frames[1] or nil
    -- ...and sometimes drop a power-up for the player to grab.
    if math.random() < DROP_CHANCE then self.drop_powerup = true end
  end
  -- Clear smoke effects when dying
  self._damage_smokes = {}
  self._hit_smokes    = {}
end

function Entity:update(dt)
  -- Corpse slide settles over a fraction of a second (ease-out).
  if self._death_push and self._death_t < 1 then
    self._death_t = math.min(1, self._death_t + dt / DEATH_SLIDE)
    local f = 1 - (1 - self._death_t) ^ 2
    self.death_ox = self._death_push.x * f
    self.death_oy = self._death_push.y * f
  end

  -- Turret destruction effect plays while the hull is still alive.
  if self.turret_fx then
    self.turret_fx:update(dt)
    if self.turret_fx:is_done() then self.turret_fx = nil end
  end

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
