local Class     = require "engine.class"
local Animation = require "engine.animation"

local atan2 = math.atan2 or math.atan

-- Each spawned heli gets exactly one of these, picked at random. air_to_air uses
-- its locking level so the missile homes (the original game's heli weapon);
-- machine_gun is the per-mission tracer streak.
local WEAPON_POOL = {
  { weapon = "chaingun",    level = 1 },
  { weapon = "rockets",     level = 1 },
  { weapon = "air_to_air",  level = 2 },
  { weapon = "machine_gun", level = 1 },
}

local SPEED      = 165    -- forward cruise (px/s); slower than the player so it can be engaged
local TURN_RATE  = 170    -- deg/s heading slew
local ORBIT_R    = 230    -- radius it tries to circle the player at
local ATTACK_R   = 360    -- range within which it will fire
local FIRE_CONE  = 34     -- deg; the nose must be this close to the player to shoot
local HIT_RADIUS = 13
local MAX_HP     = 60
local SPAWN_DELAY = 2.5   -- gap between spawns while below the cap
local DYING_TIME = 1.1    -- fall/burn time before the wreck blows, like the player heli
local BLAST_R    = 70
local BLAST_DMG  = 40
local SPRITE_ROT = 0      -- extra rotation if the badheli frame 0 is not nose-north

local HeliSystem = Class()

function HeliSystem:init(world, combat)
  self.world  = world
  self.combat = combat
  self.helis  = {}
  self.spawns = {}
  self.sprite = nil
  self.max    = 0
  self.timer  = SPAWN_DELAY
end

-- Read the stage's spawn markers and the badheli render image. Called on each
-- stage load / player spawn.
function HeliSystem:reset()
  self.helis  = {}
  self.spawns = self.world.heli_spawns or {}
  self.max    = #self.spawns
  self.timer  = SPAWN_DELAY
  self.world.air_units = self.helis
  self.sprite = nil
  for _, c in ipairs(self.world.stage.classes) do
    if c.kind_name == "enemy_helicopter" then
      local r = self.world.images[c.index + 1]
      if r and r.img then self.sprite = r.img; break end
    end
  end
end

function HeliSystem:clear()
  self.helis = {}
  self.max   = 0
  self.world.air_units = self.helis
end

function HeliSystem:_fire_interval(h)
  local w = self.combat.weapons[h.weapon]
  if not w then return 1 end
  local lvl = (w.levels and w.levels[h.level]) or w
  return 1 / (lvl.fire_rate or w.fire_rate or 2)
end

function HeliSystem:_view_radius()
  local cam = self.combat.camera
  local vw, vh = cam:dims()
  return math.max(vw, vh) / cam:zoom() / 2
end

function HeliSystem:_spawn_one(player)
  if #self.spawns == 0 or not self.sprite then return end
  -- Prefer a marker currently off-screen so the heli flies in from outside view.
  local vr = self:_view_radius() * 1.1
  local choices = {}
  for _, s in ipairs(self.spawns) do
    local dx, dy = self.world:delta(s.x, s.y, player.x, player.y)
    if dx * dx + dy * dy > vr * vr then choices[#choices + 1] = s end
  end
  if #choices == 0 then choices = self.spawns end
  local s    = choices[math.random(#choices)]
  local pick = WEAPON_POOL[math.random(#WEAPON_POOL)]
  local dx, dy = self.world:delta(player.x, player.y, s.x, s.y)
  local h = {
    x = s.x, y = s.y,
    heading = (math.deg(atan2(dy, dx)) + 90) % 360,
    hp = MAX_HP, max_hp = MAX_HP,
    weapon = pick.weapon, level = pick.level,
    dir = (math.random() < 0.5) and 1 or -1,
    phase = math.random() * math.pi * 2,
    reload = 0.4,
    smoke = {}, smoke_t = 0,
    hit_radius = HIT_RADIUS,
    state = "alive",
  }
  self.helis[#self.helis + 1] = h
end

-- Player projectile landed on this heli (called from CombatSystem:_check_hit).
function HeliSystem:hit(h, dmg, shooter)
  if h.state ~= "alive" then return end
  h.hp = h.hp - dmg
  if h.hp <= 0 then
    h.hp    = 0
    h.state = "dying"
    h.die_t = 0
    if shooter then shooter.score = (shooter.score or 0) + 70 end
  end
end

function HeliSystem:update(dt)
  if self.max == 0 then return end

  local live = 0
  for _, h in ipairs(self.helis) do if h.state ~= "removed" then live = live + 1 end end
  self.timer = self.timer - dt
  if live < self.max and self.timer <= 0 then
    local p = self.combat.player
    if p and not p.death and (p.armor or 0) > 0 then
      self:_spawn_one(p)
      self.timer = SPAWN_DELAY
    end
  end

  local keep = {}
  for _, h in ipairs(self.helis) do
    self:_update_heli(h, dt)
    if h.state ~= "removed" then keep[#keep + 1] = h end
  end
  self.helis = keep
  self.world.air_units = self.helis
end

function HeliSystem:_advance(h, dt, factor)
  local rad  = (h.heading - 90) * math.pi / 180
  local step = SPEED * (factor or 1) * dt
  local s    = self.world.stage.world_size
  h.x = (h.x + math.cos(rad) * step) % s
  h.y = (h.y + math.sin(rad) * step) % s
end

function HeliSystem:_update_heli(h, dt)
  self:_update_smoke(h, dt)
  if h.state == "dying" then return self:_update_dying(h, dt) end

  local p = self.combat:_nearest_player(h.x, h.y)
  if not p then self:_advance(h, dt); return end

  local dx, dy   = self.world:delta(p.x, p.y, h.x, h.y)   -- player relative to heli
  local dist     = math.sqrt(dx * dx + dy * dy)
  local toplayer = (math.deg(atan2(dy, dx)) + 90) % 360

  -- Far: head straight at the player. Near: circle, sweeping the nose between
  -- nearly tangential and pointing at the player so it lines up to shoot.
  local target
  if dist > ORBIT_R * 1.25 then
    target = toplayer
  else
    h.phase = h.phase + dt * 1.7
    local offset = 55 + 50 * math.sin(h.phase)   -- 5..105 deg off the player
    target = (toplayer + h.dir * offset) % 360
  end

  local diff = ((target - h.heading + 180) % 360) - 180
  local step = TURN_RATE * dt
  if math.abs(diff) <= step then h.heading = target
  else h.heading = (h.heading + (diff > 0 and step or -step)) % 360 end

  self:_advance(h, dt)

  h.reload = h.reload - dt
  local face = math.abs(((toplayer - h.heading + 180) % 360) - 180)
  if dist <= ATTACK_R and face <= FIRE_CONE and h.reload <= 0 then
    self.combat:tick_swing(h, h.weapon)
    self.combat:fire(h.x, h.y, h.heading, h.weapon, h, h.level, ATTACK_R * 1.2)
    h.reload = self:_fire_interval(h)
  end
end

-- Downed heli: like the player's, it falls (spins, shrinks, trailing fire/smoke)
-- then blows up with the shared explosion, shrapnel/dust, and a small blast.
function HeliSystem:_update_dying(h, dt)
  h.die_t = h.die_t + dt
  h.spin  = (h.spin or 0) + dt * 320
  h.fall  = math.min(1, (h.fall or 0) + dt / DYING_TIME)
  self:_advance(h, dt, 0.5)
  h.fire_t = (h.fire_t or 0) - dt
  if h.fire_t <= 0 then
    h.fire_t = 0.12
    h.smoke[#h.smoke + 1] = {
      x = h.x + (math.random() - 0.5) * 16, y = h.y + (math.random() - 0.5) * 16,
      vx = 0, vy = 0, ttl = 0.6,
      anim = Animation.new(math.random() < 0.5 and "fire" or "smoke"),
    }
  end
  if h.die_t >= DYING_TIME then
    self.combat:add_effect("explosion_large", h.x, h.y, {})
    self.world:spawn_debris(h.x, h.y, 5 + math.random(0, 3), 1.3)
    self:_blast(h)
    h.state = "removed"
    self.timer = math.min(self.timer, SPAWN_DELAY)
  end
end

function HeliSystem:_blast(h)
  for _, p in ipairs(self.combat.players) do
    if p and (p.armor or 0) > 0 and not p.death and not p.unlimited then
      local dx, dy = self.world:delta(p.x, p.y, h.x, h.y)
      if dx * dx + dy * dy < BLAST_R * BLAST_R then
        p.armor = math.max(0, p.armor - BLAST_DMG)
      end
    end
  end
end

function HeliSystem:_update_smoke(h, dt)
  local live = {}
  for _, s in ipairs(h.smoke) do
    s.age = (s.age or 0) + dt
    s.x = s.x + (s.vx or 0) * dt
    s.y = s.y + (s.vy or 0) * dt
    s.anim:update(dt)
    if not (s.anim:is_done() or (s.ttl and s.age >= s.ttl)) then live[#live + 1] = s end
  end
  h.smoke = live
  if h.state ~= "alive" then return end

  -- Damage smoke ramps with lost armor, like the player vehicle, drifting along
  -- the heading at a fraction of cruise speed so it streams behind.
  local pct    = h.hp / h.max_hp
  local target = 0
  if pct < 0.6  then target = 1 end
  if pct < 0.35 then target = 2 end
  if pct < 0.2  then target = 3 end
  local n = 0
  for _, s in ipairs(h.smoke) do if s.dmg then n = n + 1 end end
  if n < target then
    h.smoke_t = h.smoke_t - dt
    if h.smoke_t <= 0 then
      h.smoke_t = 0.06 + math.random() * 0.1
      local rad   = (h.heading - 90) * math.pi / 180
      local drift = (0.3 + math.random() * 0.4) * SPEED
      h.smoke[#h.smoke + 1] = {
        x = h.x + (math.random() - 0.5) * 14, y = h.y + (math.random() - 0.5) * 14,
        vx = math.cos(rad) * drift, vy = math.sin(rad) * drift,
        dmg = true, anim = Animation.new("smoke"),
      }
    end
  end
end

function HeliSystem:draw()
  if #self.helis == 0 or not self.sprite then return end
  local g   = love.graphics
  local cam = self.combat.camera
  local iw, ih = self.sprite:getDimensions()
  g.push()
  cam:apply()
  for _, t in ipairs(cam:tiles()) do
    g.push()
    g.translate(t.ox, t.oy)
    for _, h in ipairs(self.helis) do
      for _, s in ipairs(h.smoke) do
        local img = s.anim:current_image()
        if img then
          local sw, sh = img:getDimensions()
          g.setColor(1, 1, 1, 0.85)
          g.draw(img, s.x, s.y, 0, 1, 1, sw / 2, sh / 2)
        end
      end
      if h.state ~= "removed" then
        local rot = (h.heading + (h.spin or 0) + SPRITE_ROT) * math.pi / 180
        local sc  = 1 - 0.5 * (h.fall or 0)
        g.setColor(1, 1, 1)
        g.draw(self.sprite, h.x, h.y, rot, sc, sc, iw / 2, ih / 2)
      end
    end
    g.pop()
  end
  g.setColor(1, 1, 1)
  g.pop()
end

return HeliSystem
