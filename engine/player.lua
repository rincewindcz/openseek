local Class = require "engine.class"

local Player = Class()

-- ── class-level constants ──────────────────────────────────────────────────────
Player.TURN_RATE     = 120    -- deg/sec
Player.ACCEL         = 90     -- px/sec^2 forward
Player.DECEL         = 140    -- px/sec^2 natural slowdown
Player.BRAKE         = 200    -- px/sec^2 active braking (S key)
Player.MAX_FWD       = 180    -- px/sec
Player.MAX_REV       = 70     -- px/sec
Player.STRAFE_SPEED  = 100    -- px/sec (constant, no accel)
Player.FUEL_DRAIN    = 2.0    -- units/sec while airborne (regardless of movement)
Player.TAKEOFF_TIME  = 0.65   -- seconds altitude 0 -> 1
Player.LAND_TIME     = 0.50   -- seconds altitude 1 -> 0

function Player:init(x, y)
  self.x          = x or 2048
  self.y          = y or 2048
  self.angle      = 0       -- degrees, 0 = north, CW positive
  self.speed      = 0       -- px/sec (+forward, -reverse)
  self.strafe     = 0       -- px/sec (+right, -left) set each frame
  self.land_state = "grounded"   -- grounded | taking_off | airborne | landing
  self.altitude   = 0.0     -- 0 = ground, 1 = fully airborne

  -- fuel / armor (current values)
  self.fuel       = 100
  self.armor      = 100

  -- vehicle load config (0-200, default 100 = balanced)
  -- higher load_fuel  -> larger fuel tank but slower
  -- higher load_armor -> more armor but slower
  self.load_fuel  = 100
  self.load_armor = 100

  self.world_size = 4096
  self.weapon_idx = 0    -- current weapon (0-based index into weapons list)

  self:_apply_config()
end

-- Recompute max_fuel, max_armor, speed_factor from current load settings.
-- Call after changing load_fuel or load_armor.
function Player:_apply_config()
  -- max values: 40-160 range, 100 at balanced load
  self.max_fuel  = 40 + self.load_fuel  * 0.6
  self.max_armor = 40 + self.load_armor * 0.6
  -- speed_factor: 1.0 when loads sum to 200 (balanced 100+100),
  -- slower with heavier loads, faster with lighter
  local total    = self.load_fuel + self.load_armor   -- 0-400
  self.speed_factor = math.max(0.25, math.min(2.0, 2.0 - total / 200.0))
  -- clamp current fuel/armor to new maxima
  self.fuel  = math.min(self.fuel,  self.max_fuel)
  self.armor = math.min(self.armor, self.max_armor)
end

-- ── update ────────────────────────────────────────────────────────────────────

function Player:update(dt)
  self:_update_altitude(dt)
  self:_apply_input(dt)
  if self.land_state == "airborne" then
    self:_move(dt)
  end
  if self.land_state ~= "grounded" then
    self:_drain_fuel(dt)
  end
end

function Player:_update_altitude(dt)
  if self.land_state == "taking_off" then
    self.altitude = math.min(1.0, self.altitude + dt / Player.TAKEOFF_TIME)
    if self.altitude >= 1.0 then
      self.altitude   = 1.0
      self.land_state = "airborne"
    end
  elseif self.land_state == "landing" then
    self.altitude = math.max(0.0, self.altitude - dt / Player.LAND_TIME)
    -- damp speed during descent
    self.speed = self.speed * math.max(0, 1 - dt * 3)
    if self.altitude <= 0.0 then
      self.altitude   = 0.0
      self.land_state = "grounded"
      self.speed      = 0
      self.strafe     = 0
    end
  end
end

function Player:_apply_input(dt)
  local kb = love.keyboard.isDown

  local rotate  = 0
  if kb("a") or kb("left")  then rotate = rotate - 1 end
  if kb("d") or kb("right") then rotate = rotate + 1 end

  local strafing = kb("lshift") or kb("rshift")
  if strafing then
    self.strafe = 0
    if kb("a") or kb("left")  then self.strafe = -Player.STRAFE_SPEED end
    if kb("d") or kb("right") then self.strafe =  Player.STRAFE_SPEED end
    -- suppress rotation while strafing
  else
    self.strafe = 0
    if rotate ~= 0 then
      self.angle = (self.angle + rotate * Player.TURN_RATE * dt) % 360
    end
  end

  -- throttle only when fully airborne
  if self.land_state ~= "airborne" then return end

  local max_fwd = Player.MAX_FWD * self.speed_factor
  local max_rev = Player.MAX_REV * self.speed_factor

  if kb("w") or kb("up") then
    self.speed = math.min(self.speed + Player.ACCEL * self.speed_factor * dt, max_fwd)
  elseif kb("s") or kb("down") then
    self.speed = math.max(self.speed - Player.BRAKE * dt, -max_rev)
  else
    if self.speed > 0 then
      self.speed = math.max(0, self.speed - Player.DECEL * dt)
    elseif self.speed < 0 then
      self.speed = math.min(0, self.speed + Player.DECEL * dt)
    end
  end
end

function Player:_move(dt)
  local rad = (self.angle - 90) * math.pi / 180
  self.x = self.x + math.cos(rad) * self.speed * dt
  self.y = self.y + math.sin(rad) * self.speed * dt
  -- strafe: perpendicular (90 deg right of facing)
  local sr = rad + math.pi / 2
  self.x = self.x + math.cos(sr) * self.strafe * dt
  self.y = self.y + math.sin(sr) * self.strafe * dt
  -- clamp to world
  self.x = math.max(0, math.min(self.world_size, self.x))
  self.y = math.max(0, math.min(self.world_size, self.y))
end

function Player:_drain_fuel(dt)
  self.fuel = math.max(0, self.fuel - Player.FUEL_DRAIN * dt)
end

-- ── state transitions ─────────────────────────────────────────────────────────

function Player:take_off()
  if self.land_state ~= "grounded" then return end
  self.land_state = "taking_off"
end

function Player:land()
  if self.land_state ~= "airborne" then return end
  self.land_state = "landing"
end

function Player:refuel(amount)
  self.fuel = math.min(self.max_fuel, self.fuel + (amount or self.max_fuel))
end

function Player:repair(amount)
  self.armor = math.min(self.max_armor, self.armor + (amount or self.max_armor))
end

-- ── queries ───────────────────────────────────────────────────────────────────

function Player:is_dead()
  return self.armor <= 0 or self.fuel <= 0
end

-- Camera rotation angle in radians (negate player heading to spin world).
function Player:camera_angle()
  return -self.angle * math.pi / 180
end

-- ── draw ─────────────────────────────────────────────────────────────────────

function Player:draw()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  local cx, cy = sw / 2, sh / 2

  -- body: teardrop pointing up (north = forward on screen)
  local state_color = {
    grounded   = { 0.85, 0.70, 0.15 },
    taking_off = { 0.50, 0.90, 0.35 },
    airborne   = { 0.25, 0.90, 0.35 },
    landing    = { 0.50, 0.70, 0.30 },
  }
  local c = state_color[self.land_state] or { 0.5, 0.5, 0.5 }
  g.setColor(c[1], c[2], c[3])
  g.polygon("fill",
    cx,      cy - 16,
    cx - 10, cy + 4,
    cx,      cy + 8,
    cx + 10, cy + 4
  )
  g.setColor(0, 0, 0, 0.5)
  g.setLineWidth(1)
  g.polygon("line", cx, cy - 16, cx - 10, cy + 4, cx, cy + 8, cx + 10, cy + 4)

  -- altitude indicator: small bar below marker
  if self.land_state ~= "grounded" then
    local bw = 20
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", cx - bw/2, cy + 14, bw, 4)
    g.setColor(c[1], c[2], c[3])
    g.rectangle("fill", cx - bw/2, cy + 14, bw * self.altitude, 4)
  end

  g.setColor(1, 1, 1)
end

return Player
