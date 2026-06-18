local Class     = require "engine.class"
local Animation = require "engine.animation"
local Config    = require "engine.config"

local Player = Class()

-- sprite frame constants (0-indexed, matching exported assets)
local PIT_NEUTRAL = 7    -- choppit1 neutral frame
local PIT_FRAMES  = 15
local BNK_NEUTRAL = 4    -- chopbnk1 neutral frame
local BNK_MAX_R   = 7    -- chopbnk1 max-right frame used
local DRP_FRAMES  = 6    -- chopdrp1 total frames
local STRAFE_THR  = 5    -- |strafe| threshold to switch bank/pitch mode
local ROTOR_MIN_S = 0.65  -- rotor scale factor when grounded (scales up to 1 airborne)

function Player:init(x, y)
  self.x          = x or 2048
  self.y          = y or 2048
  self.angle      = 0
  self.speed      = 0
  self.strafe     = 0
  self.land_state = "grounded"
  self.altitude   = 0.0

  self.fuel       = 100
  self.armor      = 100
  self.load_fuel  = 100
  self.load_armor = 100

  self.world_size   = 4096
  self.weapon_idx   = 0       -- HUD sprite index (0-based)
  self.weapon_icon  = 0       -- WEAPONS.BIN frame for the current weapon
  self.vehicle      = "chopper"
  self.weapon_name  = "chaingun"
  self.weapon_level = 1
  self.fire_timer   = 0

  self.ammo         = {}      -- weapon_name -> rounds left (absent = infinite)
  self.unlimited    = false   -- god mode: skip ammo/fuel/armor consumption
  self.medals       = 0
  self.pows         = 0       -- people (POWs/allies) currently carried
  self.score        = 0       -- own kill/rescue score (co-op split screen)
  self.death        = nil     -- death sequence state (set by start_death)

  self.turret_offset    = 0    -- tank turret heading relative to the hull (deg)
  self.turret_rate      = 140
  self.collision_radius = 8
  self.world            = nil  -- set in game mode for collision queries
  self.camera           = nil  -- set in game mode for screen placement

  -- Movement key bindings. A binding is a key name or a list of names (any
  -- held counts). The single-player default accepts WASD and the arrows; split
  -- screen assigns each player a distinct set. fire / weapon / action keys are
  -- read by main.lua, not here.
  self.controls = {
    up    = { "w", "up" },    down  = { "s", "down" },
    left  = { "a", "left" },  right = { "d", "right" },
    modifier = { "lshift", "rshift" },
  }

  -- vehicle params (defaults; overridden by load_vehicle_def)
  self.sprite_scale = 3
  self.rotor_y_off  = 0
  self.rotor_fps    = 40
  self.turn_rate    = 160
  self.accel        = 280
  self.decel        = 320
  self.brake        = 480
  self.max_fwd      = 260
  self.max_rev      = 100
  self.strafe_speed = 140
  self.strafe_accel = 400
  self.fuel_drain   = 1.3
  self.takeoff_time = 0.65
  self.land_time    = 0.50

  self._smoke_puffs = {}     -- {x, y, anim} — world-space smoke left behind as a trail
  self._smoke_timer = 0
  self._hit_fx      = {}     -- {anim, age, ttl} — scorch bursts on top of the vehicle when hit

  self.home_x     = nil      -- friendly base / heliport spawn; parking here refuels
  self.home_y     = nil
  self.home_r     = 48
  self.refuel_mode = "continuous"  -- "continuous" (refuel_rate/sec) or "instant" (original)
  self.refuel_rate = 25      -- fuel/sec restored while parked on the base

  self.turn_cursor = 0       -- HUD accel box: a small lateral nudge while the hull turns

  self._tank_anim    = Animation.new("tankbgrn")
  self._rotor_spin   = 0          -- spin phase within an 8-frame group (continuous)
  self._rotor_clip   = "bladep"   -- bladep (pitch) or bladeb (bank)
  self._rotor_group  = 0          -- active 8-frame group, by pitch/bank position

  self:_apply_config()
end

function Player:load_vehicle_def(def)
  self.sprite_scale = def.sprite_scale   or self.sprite_scale
  self.rotor_y_off  = def.rotor_y_offset or self.rotor_y_off
  self.rotor_fps    = def.rotor_fps      ~= nil and def.rotor_fps or self.rotor_fps
  self.turn_rate    = def.turn_rate      or self.turn_rate
  self.accel        = def.accel          or self.accel
  self.decel        = def.decel          or self.decel
  self.brake        = def.brake          or self.brake
  self.max_fwd      = def.max_fwd        or self.max_fwd
  self.max_rev      = def.max_rev        or self.max_rev
  self.strafe_speed = def.strafe_speed   or self.strafe_speed
  self.strafe_accel = def.strafe_accel   or self.strafe_accel
  self.fuel_drain   = def.fuel_drain     or self.fuel_drain
  self.takeoff_time = def.takeoff_time   or self.takeoff_time
  self.land_time    = def.land_time      or self.land_time
  self.turret_rate      = def.turret_rate      or self.turret_rate
  self.collision_radius = def.collision_radius or self.collision_radius
end

function Player:is_flyer()
  return self.vehicle ~= "tank"
end

-- Heading projectiles travel along: the turret for tanks, the hull otherwise.
function Player:fire_angle()
  if self.vehicle == "tank" then return self.angle + self.turret_offset end
  return self.angle
end

-- ── ammo ──────────────────────────────────────────────────────────────────────

-- Seed per-weapon ammo to full from the weapon table. Weapons without an
-- ammo_max (chaingun) stay absent and read as infinite.
function Player:seed_ammo(weapons)
  self.ammo      = {}
  self._ammo_max = {}
  for name, w in pairs(weapons) do
    if w.ammo_max then
      self.ammo[name]      = w.ammo_max
      self._ammo_max[name] = w.ammo_max
    end
  end
end

function Player:has_ammo(name)
  return self.unlimited or self.ammo[name] == nil or self.ammo[name] > 0
end

function Player:consume_ammo(name, cost)
  if self.unlimited or self.ammo[name] == nil then return end
  self.ammo[name] = math.max(0, self.ammo[name] - (cost or 1))
end

function Player:add_ammo(name, amount)
  if self.ammo[name] == nil then return end  -- not an ammo-tracked weapon
  local cap = self._ammo_max and self._ammo_max[name] or self.ammo[name] + amount
  self.ammo[name] = math.min(cap, self.ammo[name] + amount)
end

function Player:_apply_config()
  self.max_fuel  = 40 + self.load_fuel  * 0.6
  self.max_armor = 40 + self.load_armor * 0.6
  local total = self.load_fuel + self.load_armor
  self.speed_factor = math.max(0.25, math.min(2.0, 2.0 - total / 200.0))
  self.fuel  = math.min(self.fuel,  self.max_fuel)
  self.armor = math.min(self.armor, self.max_armor)
end

-- ── update ────────────────────────────────────────────────────────────────────

function Player:update(dt)
  if self.death then return self:_update_death(dt) end
  self:_update_altitude(dt)
  self:_apply_input(dt)
  if self.land_state == "airborne" or not self:is_flyer() then
    self:_move(dt)
  end
  if self.land_state ~= "grounded"
  or (not self:is_flyer() and math.abs(self.speed) > 1) then
    self:_drain_fuel(dt)
  end
  self:_update_anims(dt)
  self:_update_damage_smoke(dt)
  self:_update_hit_fx(dt)
  self:_update_base_refuel(dt)
  if self.fire_timer > 0 then
    self.fire_timer = self.fire_timer - dt
  end
end

-- Scorch bursts (fire / smoke) that play on top of the vehicle when an enemy
-- round connects. Looping clips (fire) expire on their ttl; one-shot clips when
-- their animation ends.
function Player:add_hit_fx(clip, ttl)
  self._hit_fx[#self._hit_fx + 1] = {
    anim = Animation.new(clip), age = 0, ttl = ttl,
    ox = (math.random() - 0.5) * 24, oy = (math.random() - 0.5) * 24,
  }
end

function Player:_update_hit_fx(dt)
  if #self._hit_fx == 0 then return end
  local live = {}
  for _, fx in ipairs(self._hit_fx) do
    fx.anim:update(dt)
    fx.age = fx.age + dt
    local expired = (fx.ttl and fx.age >= fx.ttl) or fx.anim:is_done()
    if not expired then live[#live + 1] = fx end
  end
  self._hit_fx = live
end

-- Parking on the friendly base (the spawn heliport) tops the fuel back up.
function Player:_update_base_refuel(dt)
  if not (self.home_x and self:is_stationary()) then return end
  local dx, dy
  if self.world then
    dx, dy = self.world:delta(self.x, self.y, self.home_x, self.home_y)
  else
    dx, dy = self.x - self.home_x, self.y - self.home_y
  end
  if dx * dx + dy * dy <= self.home_r * self.home_r then
    if self.refuel_mode == "instant" then
      self.fuel = self.max_fuel
    else
      self:refuel(self.refuel_rate * dt)
    end
  end
end

-- Smoke intensity scales with armor loss: ~2-3 puffs under 60% armor, ~5-7 under
-- 40%, ~8-12 under 20%. Puffs spawn one at a time with a randomized delay so the
-- animations are out of phase, and each picks (once) whether it sits in front of
-- or behind the vehicle, so the trail reads as volume instead of a flat layer.
function Player:_update_damage_smoke(dt)
  local maxa = self.max_armor or 100
  local pct  = maxa > 0 and (self.armor / maxa) or 1
  local target = 0
  if pct < 0.6 then target = 3  end
  if pct < 0.4 then target = 7  end
  if pct < 0.2 then target = 12 end

  local live = {}
  for _, pf in ipairs(self._smoke_puffs) do
    pf.anim:update(dt)
    pf.x = pf.x + pf.vx * dt
    pf.y = pf.y + pf.vy * dt
    if not pf.anim:is_done() then live[#live + 1] = pf end
  end
  self._smoke_puffs = live

  if #self._smoke_puffs < target then
    self._smoke_timer = self._smoke_timer - dt
    if self._smoke_timer <= 0 then
      self._smoke_timer = 0.04 + math.random() * 0.10
      -- Puffs drift along the vehicle's heading at a fraction of its current
      -- speed so the trail streams out behind a moving vehicle instead of
      -- hanging stationary in the air.
      local rad   = (self.angle - 90) * math.pi / 180
      local sr    = rad + math.pi / 2
      local vx    = math.cos(rad) * self.speed + math.cos(sr) * self.strafe
      local vy    = math.sin(rad) * self.speed + math.sin(sr) * self.strafe
      local drift = 0.25 + math.random() * 0.5
      self._smoke_puffs[#self._smoke_puffs + 1] = {
        x     = self.x + (math.random() - 0.5) * 30,
        y     = self.y + (math.random() - 0.5) * 30,
        vx    = vx * drift,
        vy    = vy * drift,
        front = math.random() < 0.5,
        anim  = Animation.new("smoke"),
      }
    end
  end
end

-- World-space smoke trail behind the vehicle (drawn before the player sprite).
function Player:draw_world()
  self:_draw_smoke_layer(false)
end

-- Smoke that sits on top of the vehicle (drawn after the player sprite).
function Player:draw_world_front()
  self:_draw_smoke_layer(true)
  self:_draw_hit_fx()
end

function Player:_draw_hit_fx()
  if not self.camera or #self._hit_fx == 0 then return end
  local g = love.graphics
  g.push()
  self.camera:apply()
  for _, t in ipairs(self.camera:tiles()) do
    g.push()
    g.translate(t.ox, t.oy)
    for _, fx in ipairs(self._hit_fx) do
      local img = fx.anim:current_image()
      if img then
        local w, h = img:getDimensions()
        g.setColor(1, 1, 1)
        g.draw(img, self.x + fx.ox, self.y + fx.oy, 0, 1, 1, w / 2, h / 2)
      end
    end
    g.pop()
  end
  g.setColor(1, 1, 1)
  g.pop()
end

function Player:_draw_smoke_layer(front)
  if not self.camera or #self._smoke_puffs == 0 then return end
  local g = love.graphics
  g.push()
  self.camera:apply()
  for _, t in ipairs(self.camera:tiles()) do
    g.push()
    g.translate(t.ox, t.oy)
    for _, pf in ipairs(self._smoke_puffs) do
      if pf.front == front then
        local img = pf.anim:current_image()
        if img then
          local w, h = img:getDimensions()
          g.setColor(1, 1, 1, 0.8)
          g.draw(img, pf.x, pf.y, 0, 1.2, 1.2, w / 2, h / 2)
        end
      end
    end
    g.pop()
  end
  g.setColor(1, 1, 1)
  g.pop()
end

-- ── death sequence ────────────────────────────────────────────────────────────

local FALL_TIME  = 1.25  -- seconds for a downed chopper to drop from full altitude
local TANK_BURN  = 1.6   -- seconds the tank burns before the turret blows
local BLAST_R    = 90    -- radius of the player's death explosion damage
local BLAST_DMG  = 140   -- damage dealt to nearby entities by that explosion

-- The player's death explosion damages everything around the wreck, like a bomb.
function Player:_death_blast()
  if not self.world then return end
  local r2 = BLAST_R * BLAST_R
  for _, e in ipairs(self.world.entities) do
    if e:is_alive() and e.type_data and (e.type_data.hit_radius or 0) > 0 then
      local dx, dy = self.world:delta(e.x, e.y, self.x, self.y)
      if dx * dx + dy * dy < r2 then
        e:take_damage(BLAST_DMG, dx, dy)
      end
    end
  end
end

-- Begin the death sequence: a chopper falls and explodes on the ground; a tank
-- burns with explosions and smoke, then its turret blows. Idempotent.
function Player:start_death()
  if self.death then return end
  self.speed  = 0
  self.strafe = 0
  if self:is_flyer() then
    self.land_state = "landing"   -- drop frames driven by altitude
    self.death = { phase = "fall", t = 0, fx = {} }
  else
    self.death = { phase = "burn", t = 0, spawn = 0, fx = {}, turret_exploded = false }
  end
end

function Player:death_done()
  return self.death ~= nil and self.death.phase == "done"
end

function Player:_update_death(dt)
  local d = self.death
  d.t = d.t + dt
  for i = #d.fx, 1, -1 do
    d.fx[i].anim:update(dt)
    if d.fx[i].anim:is_done() then table.remove(d.fx, i) end
  end
  if self:is_flyer() then
    self:_update_death_chopper(dt, d)
  else
    self:_update_death_tank(dt, d)
  end
end

function Player:_update_death_chopper(dt, d)
  if d.phase == "fall" then
    self:_update_anims(dt)   -- rotor keeps spinning on the way down
    self.altitude = math.max(0, self.altitude - dt / FALL_TIME)
    if self.altitude <= 0 then
      d.phase = "boom"
      d.boom  = Animation.new("explosion_large")
      self:_death_blast()
    end
  elseif d.phase == "boom" then
    if d.boom then
      d.boom:update(dt)
      if d.boom:is_done() then d.phase = "done" end
    else
      d.phase = "done"
    end
  end
end

function Player:_update_death_tank(dt, d)
  if d.phase == "burn" then
    d.spawn = d.spawn - dt
    if d.spawn <= 0 then
      d.spawn = 0.16
      local clip = (math.random() < 0.5) and "explosion_medium" or "smoke"
      d.fx[#d.fx + 1] = {
        anim = Animation.new(clip),
        ox   = (math.random() - 0.5) * 44,
        oy   = (math.random() - 0.5) * 36,
      }
    end
    if d.t >= TANK_BURN then
      d.phase           = "turret"
      d.turret_exploded = true
      d.fx[#d.fx + 1]   = { anim = Animation.new("explosion_large"), ox = 0, oy = -4 }
      self:_death_blast()
    end
  elseif d.phase == "turret" then
    if d.t >= TANK_BURN + 0.6 and #d.fx == 0 then d.phase = "done" end
  end
end

function Player:_update_altitude(dt)
  if not self:is_flyer() then return end
  if self.land_state == "taking_off" then
    local tt = self.takeoff_time > 0 and self.takeoff_time or 0.01
    self.altitude = math.min(1.0, self.altitude + dt / tt)
    if self.altitude >= 1.0 then
      self.altitude   = 1.0
      self.land_state = "airborne"
    end
  elseif self.land_state == "landing" then
    -- Abort the descent and climb back up if the spot is over an obstacle.
    if self.world and self.world:blocked(self.x, self.y, self.collision_radius) then
      self.land_state = "taking_off"
      return
    end
    local lt = self.land_time > 0 and self.land_time or 0.01
    self.altitude = math.max(0.0, self.altitude - dt / lt)
    self.speed = self.speed * math.max(0, 1 - dt * 3)
    if self.altitude <= 0.0 then
      self.altitude   = 0.0
      self.land_state = "grounded"
      self.speed      = 0
      self.strafe     = 0
    end
  end
end

-- True if any key bound to the named action is held.
function Player:_held(action)
  local b = self.controls and self.controls[action]
  if not b then return false end
  if type(b) == "table" then
    for _, k in ipairs(b) do
      if love.keyboard.isDown(k) then return true end
    end
    return false
  end
  return love.keyboard.isDown(b)
end

function Player:_apply_input(dt)
  -- Turn rates are gameplay speeds, so they take the global multiplier (movement
  -- is scaled in _move); acceleration ramps below stay on real dt.
  local tdt = dt * Config.speed_scale
  local rotate   = 0
  if self:_held("left")  then rotate = rotate - 1 end
  if self:_held("right") then rotate = rotate + 1 end

  local modifier = self:_held("modifier")
  local hull_turn = 0

  if self.vehicle == "tank" then
    -- shift + turn rotates the turret; otherwise the hull
    if modifier then
      if rotate ~= 0 then
        self.turret_offset = (self.turret_offset + rotate * self.turret_rate * tdt) % 360
      end
    elseif rotate ~= 0 then
      self.angle = (self.angle + rotate * self.turn_rate * tdt) % 360
      hull_turn = rotate
    end
    self.strafe = 0
  else
    -- chopper: smooth strafe toward target while shift is held
    local strafe_target = 0
    if modifier then
      if self:_held("left")  then strafe_target = -self.strafe_speed end
      if self:_held("right") then strafe_target =  self.strafe_speed end
    end
    local sa = self.strafe_accel > 0 and self.strafe_accel or 9999
    if self.strafe < strafe_target then
      self.strafe = math.min(strafe_target, self.strafe + sa * dt)
    elseif self.strafe > strafe_target then
      self.strafe = math.max(strafe_target, self.strafe - sa * dt)
    end
    -- rotation only when shift is not held
    if not modifier and rotate ~= 0 then
      self.angle = (self.angle + rotate * self.turn_rate * tdt) % 360
      hull_turn = rotate
    end
  end

  -- The accel box dot drifts a little toward the turn while the hull is rotating,
  -- as if turning carried a small lateral acceleration; it eases back to center
  -- when the turn stops.
  self.turn_cursor = self.turn_cursor + (hull_turn - self.turn_cursor) * math.min(1, 5 * dt)

  if self:is_flyer() and self.land_state ~= "airborne" then return end

  local max_fwd = self.max_fwd * self.speed_factor
  local max_rev = self.max_rev * self.speed_factor

  if self:_held("up") then
    self.speed = math.min(self.speed + self.accel * self.speed_factor * dt, max_fwd)
  elseif self:_held("down") then
    self.speed = math.max(self.speed - self.brake * dt, -max_rev)
  else
    if self.speed > 0 then
      self.speed = math.max(0, self.speed - self.decel * dt)
    elseif self.speed < 0 then
      self.speed = math.min(0, self.speed + self.decel * dt)
    end
  end
end

function Player:_move(dt)
  local sdt = dt * Config.speed_scale
  local rad = (self.angle - 90) * math.pi / 180
  local sr  = rad + math.pi / 2
  local dx  = (math.cos(rad) * self.speed + math.cos(sr) * self.strafe) * sdt
  local dy  = (math.sin(rad) * self.speed + math.sin(sr) * self.strafe) * sdt

  if self.world and not self:is_flyer() then
    -- Axis-separated so the tank slides along obstacles instead of sticking.
    local r  = self.collision_radius
    local nx = self.x + dx
    if self.world:blocked(nx, self.y, r) then nx = self.x end
    local ny = self.y + dy
    if self.world:blocked(nx, ny, r) then ny = self.y end
    self.x, self.y = nx, ny
  else
    self.x = self.x + dx
    self.y = self.y + dy
  end

  -- Seamless wrap: leaving one edge re-enters from the opposite one.
  self.x = self.x % self.world_size
  self.y = self.y % self.world_size
end

function Player:_drain_fuel(dt)
  if self.unlimited then return end
  self.fuel = math.max(0, self.fuel - self.fuel_drain * dt)
end

function Player:_update_anims(dt)
  if self.vehicle == "tank" then
    if math.abs(self.speed) > 1 then self._tank_anim:update(dt) end
    return
  end
  -- The rotor sheets are grouped into 8-frame spin cycles, one cycle per pitch
  -- (bladep) or bank (bladeb) position. Pick the group matching the body's
  -- current pitch/bank, then spin only within that group's 8 frames so the blades
  -- rotate smoothly instead of jumping between positions each cycle.
  local bank = self:_using_bank()
  self._rotor_clip = bank and "bladeb" or "bladep"
  local clip   = Animation.clip(self._rotor_clip)
  local groups = clip and math.max(1, math.floor(clip:frame_count() / 8)) or 1
  local level  = bank and self:_bank_level01() or self:_pitch_level01()
  self._rotor_group = math.max(0, math.min(groups - 1, math.floor(level * (groups - 1) + 0.5)))
  if self.rotor_fps > 0 then
    self._rotor_spin = (self._rotor_spin + dt * self.rotor_fps) % 8
  end
end

-- ── state transitions ─────────────────────────────────────────────────────────

function Player:take_off()
  if not self:is_flyer() then return end
  if self.land_state ~= "grounded" then return end
  self.land_state = "taking_off"
end

function Player:land()
  if not self:is_flyer() then return end
  if self.land_state ~= "airborne" then return end
  self.land_state = "landing"
end

function Player:refuel(amount)
  self.fuel = math.min(self.max_fuel, self.fuel + (amount or self.max_fuel))
end

function Player:repair(amount)
  self.armor = math.min(self.max_armor, self.armor + (amount or self.max_armor))
end

-- Settled enough to load/unload people or plant a charge: a chopper must be
-- grounded; a tank must be nearly stopped (manual: land on or stop over a zone).
function Player:is_stationary()
  if self:is_flyer() then return self.land_state == "grounded" end
  return math.abs(self.speed) < 5
end

function Player:is_dead()
  if self.unlimited then return false end
  return self.armor <= 0 or self.fuel <= 0
end

function Player:camera_angle()
  return -self.angle * math.pi / 180
end

-- ── sprite helpers ────────────────────────────────────────────────────────────

function Player:_frames(clip_name)
  local clip = Animation.clip(clip_name)
  return clip and clip.frames or {}
end

function Player:_using_bank()
  return math.abs(self.strafe) > STRAFE_THR
end

-- Normalized pitch/bank position in [0,1] (0.5 = neutral), shared by the body
-- frame and the rotor group so the spinning rotor tracks the hull's tilt.
function Player:_pitch_level01()
  if self.speed >= 0 then
    local t = self.speed / math.max(1, self.max_fwd * self.speed_factor)
    return 0.5 - 0.5 * math.min(1, t)
  end
  local t = (-self.speed) / math.max(1, self.max_rev * self.speed_factor)
  return 0.5 + 0.5 * math.min(1, t)
end

function Player:_bank_level01()
  local t = self.strafe_speed > 0 and (self.strafe / self.strafe_speed) or 0
  return math.max(0, math.min(1, (t + 1) * 0.5))
end

-- Current rotor frame: the active group's base plus the spin phase, wrapped.
function Player:_rotor_image()
  local clip = Animation.clip(self._rotor_clip)
  if not clip or clip:is_empty() then return nil end
  local n   = clip:frame_count()
  local idx = self._rotor_group * 8 + (math.floor(self._rotor_spin) % 8)
  return clip.frames[(idx % n) + 1]
end

function Player:_chopper_body_frame()
  if self.land_state == "landing" or self.land_state == "taking_off"
  or self.land_state == "grounded" then
    local fi = math.floor((1.0 - self.altitude) * (DRP_FRAMES - 1) + 0.5) + 1
    local frames = self:_frames("chopdrp1")
    return frames[math.max(1, math.min(#frames, fi))]
  end

  if self:_using_bank() then
    local t  = self.strafe_speed > 0 and (self.strafe / self.strafe_speed) or 0
    local fi = math.floor(BNK_NEUTRAL + t * BNK_NEUTRAL + 0.5) + 1
    local frames = self:_frames("chopbnk1")
    return frames[math.max(1, math.min(BNK_MAX_R + 1, fi))]
  end

  local n = PIT_NEUTRAL
  local fi
  if self.speed >= 0 then
    local t = self.speed / math.max(1, self.max_fwd * self.speed_factor)
    fi = math.floor(n - n * t + 0.5) + 1
  else
    local t = (-self.speed) / math.max(1, self.max_rev * self.speed_factor)
    fi = math.floor(n + (PIT_FRAMES - 1 - n) * t + 0.5) + 1
  end
  local frames = self:_frames("choppit1")
  return frames[math.max(1, math.min(#frames, fi))]
end

-- ── draw ─────────────────────────────────────────────────────────────────────

function Player:draw()
  local g      = love.graphics
  local cx, cy
  if self.camera then
    cx, cy = self.camera:screen_center()
  else
    local sw, sh = g.getDimensions()
    cx, cy = sw / 2, sh / 2
  end
  local s = self.sprite_scale
  if self.camera then s = s * self.camera:zoom_ratio() end

  g.setColor(1, 1, 1)
  if self.death then
    self:_draw_death(g, cx, cy, s)
  elseif self.vehicle == "tank" then
    self:_draw_tank(g, cx, cy, s)
  else
    self:_draw_chopper(g, cx, cy, s)
  end
  g.setColor(1, 1, 1)
end

function Player:_draw_death(g, cx, cy, s)
  local d = self.death
  if self:is_flyer() then
    if d.phase == "fall" then
      local jx = (math.random() - 0.5) * 12   -- shake while plummeting
      local jy = (math.random() - 0.5) * 12
      self:_draw_chopper(g, cx + jx, cy + jy, s)
    elseif d.phase == "boom" and d.boom then
      local img = d.boom:current_image()
      if img then
        local w, h = img:getDimensions()
        g.draw(img, cx, cy, 0, s, s, w / 2, h / 2)
      end
    end
  else
    self:_draw_tank(g, cx, cy, s)   -- burning hull; turret skipped once exploded
  end
  -- explosions / smoke around the wreck
  for _, e in ipairs(d.fx) do
    local img = e.anim:current_image()
    if img then
      local w, h = img:getDimensions()
      g.setColor(1, 1, 1)
      g.draw(img, cx + e.ox * s, cy + e.oy * s, 0, s, s, w / 2, h / 2)
    end
  end
  g.setColor(1, 1, 1)
end

function Player:_draw_centered(g, img, cx, cy, s)
  if not img then return end
  local w, h = img:getDimensions()
  g.draw(img, cx, cy, 0, s, s, w / 2, h / 2)
end

function Player:_draw_chopper(g, cx, cy, s)
  self:_draw_centered(g, self:_chopper_body_frame(), cx, cy, s)
  local rotor_img = self:_rotor_image()
  local rs = s * (ROTOR_MIN_S + (1 - ROTOR_MIN_S) * self.altitude)
  self:_draw_centered(g, rotor_img, cx, cy + self.rotor_y_off, rs)
end

-- Draw this player as the co-op teammate, seen from another player's camera.
-- Positioned at our world point projected into cam, rotated to our heading in
-- that camera's frame (frame 0 points north; cam.angle re-aligns it). A ring in
-- the player's color makes the teammate easy to spot.
function Player:draw_remote(g, cam, color)
  if self.death then return end
  local sx, sy = cam:project(self.x, self.y)
  local s      = self.sprite_scale
  local base   = self.angle * math.pi / 180 + (cam.angle or 0)

  g.setColor(1, 1, 1)
  if self.vehicle == "tank" then
    local body_frames = self:_frames("tankbgrn")
    local body_img    = body_frames[self._tank_anim.frame] or body_frames[1]
    if body_img then
      local w, h = body_img:getDimensions()
      g.draw(body_img, sx, sy, base, s, s, w / 2, h / 2)
    end
    local turret = self:_frames("tanktop")[1]
    if turret then
      local ax, ay = Animation.frame_anchor("tanktop", 1)
      local trot   = (self.angle + self.turret_offset) * math.pi / 180 + (cam.angle or 0)
      g.draw(turret, sx, sy, trot, s, s, ax, ay)
    end
  else
    local body = self:_chopper_body_frame()
    if body then
      local w, h = body:getDimensions()
      g.draw(body, sx, sy, base, s, s, w / 2, h / 2)
    end
    local rotor = self:_rotor_image()
    if rotor then
      local w, h = rotor:getDimensions()
      local rs   = s * (ROTOR_MIN_S + (1 - ROTOR_MIN_S) * self.altitude)
      g.draw(rotor, sx, sy, base, rs, rs, w / 2, h / 2)
    end
  end

  if color then
    g.setColor(color[1], color[2], color[3], 0.9)
    g.setLineWidth(2)
    g.circle("line", sx, sy, 14 * s / 3 + 6)
    g.setLineWidth(1)
  end
  g.setColor(1, 1, 1)
end

function Player:_draw_tank(g, cx, cy, s)
  local body_frames = self:_frames("tankbgrn")
  local body_img    = body_frames[self._tank_anim.frame] or body_frames[1]
  self:_draw_centered(g, body_img, cx, cy, s)
  if self.death and self.death.turret_exploded then return end
  -- Turret: axis-aligned frame 0 (barrel north), runtime-rotated to the turret
  -- heading relative to the hull. Anchored on its art center to spin in place.
  local img = self:_frames("tanktop")[1]  -- frame 0
  if img then
    local ax, ay = Animation.frame_anchor("tanktop", 1)
    local rot    = self.turret_offset * math.pi / 180
    g.draw(img, cx, cy, rot, s, s, ax, ay)
  end
end

return Player
