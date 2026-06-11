local Class = require "engine.class"

local Player = Class()

-- degrees/sec
Player.TURN_RATE     = 120
-- px/sec^2
Player.ACCEL         = 90
Player.DECEL         = 140   -- natural slowdown
Player.BRAKE         = 200   -- active braking (reverse key)
-- px/sec
Player.MAX_FWD       = 180
Player.MAX_REV       = 70
-- strafe speed (no acceleration, immediate)
Player.STRAFE_SPEED  = 100
-- fuel drain per second while airborne and moving
Player.FUEL_DRAIN    = 1.5   -- out of 100

function Player:init(x, y)
  self.x        = x or 2048
  self.y        = y or 2048
  self.angle    = 0      -- degrees, 0 = north, CW positive
  self.speed    = 0      -- px/sec, + forward, - reverse
  self.strafe   = 0      -- px/sec, + right, - left (set per-frame)
  self.airborne = false
  self.altitude = 0      -- 0 = grounded
  self.fuel     = 100
  self.max_fuel = 100
  self.armor    = 100
  self.max_armor = 100
  self.world_size = 4096
end

function Player:update(dt)
  self:_apply_input(dt)
  if self.airborne then
    self:_move(dt)
    self:_burn_fuel(dt)
  end
end

function Player:_apply_input(dt)
  local kb = love.keyboard.isDown

  -- rotation (always allowed for targeting)
  local rotate = 0
  if kb("a") or kb("left")  then rotate = rotate - 1 end
  if kb("d") or kb("right") then rotate = rotate + 1 end

  -- strafe: hold Left-Shift + left/right
  local strafing = kb("lshift") or kb("rshift")
  if strafing then
    self.strafe = 0
    if kb("a") or kb("left")  then self.strafe = -Player.STRAFE_SPEED end
    if kb("d") or kb("right") then self.strafe =  Player.STRAFE_SPEED end
    rotate = 0   -- strafe suppresses rotation
  else
    self.strafe = 0
    self.angle  = self.angle + rotate * Player.TURN_RATE * dt
    self.angle  = self.angle % 360
  end

  if not self.airborne then return end

  -- throttle
  if kb("w") or kb("up") then
    self.speed = math.min(self.speed + Player.ACCEL * dt, Player.MAX_FWD)
  elseif kb("s") or kb("down") then
    self.speed = math.max(self.speed - Player.BRAKE * dt, -Player.MAX_REV)
  else
    -- natural slowdown
    if self.speed > 0 then
      self.speed = math.max(0, self.speed - Player.DECEL * dt)
    elseif self.speed < 0 then
      self.speed = math.min(0, self.speed + Player.DECEL * dt)
    end
  end
end

function Player:_move(dt)
  local rad = (self.angle - 90) * math.pi / 180
  -- forward/backward along facing direction
  self.x = self.x + math.cos(rad) * self.speed * dt
  self.y = self.y + math.sin(rad) * self.speed * dt
  -- strafe: perpendicular to facing
  local sr = rad + math.pi / 2
  self.x = self.x + math.cos(sr) * self.strafe * dt
  self.y = self.y + math.sin(sr) * self.strafe * dt
  -- clamp to world
  self.x = math.max(0, math.min(self.world_size, self.x))
  self.y = math.max(0, math.min(self.world_size, self.y))
end

function Player:_burn_fuel(dt)
  local moving = math.abs(self.speed) > 5 or math.abs(self.strafe) > 5
  if moving then
    self.fuel = math.max(0, self.fuel - Player.FUEL_DRAIN * dt)
  end
end

function Player:take_off()
  if self.airborne then return end
  self.airborne = true
  self.speed    = 0
  self.strafe   = 0
end

function Player:land()
  if not self.airborne then return end
  self.airborne = false
  self.speed    = 0
  self.strafe   = 0
end

function Player:take_damage(amount)
  self.armor = math.max(0, self.armor - amount)
end

-- Camera rotation angle in radians (negate player angle to rotate world).
function Player:camera_angle()
  return -self.angle * math.pi / 180
end

-- Draw the player marker at screen center (call in screen space, after camera pop).
function Player:draw()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  local cx, cy = sw / 2, sh / 2

  -- body: pointing up (north on screen)
  if self.airborne then
    g.setColor(0.25, 0.9, 0.35)
  else
    g.setColor(0.9, 0.7, 0.2)   -- gold when landed
  end
  -- teardrop shape: nose at top, wider at bottom
  g.polygon("fill",
    cx,      cy - 16,   -- nose
    cx - 10, cy + 4,    -- left wing
    cx,      cy + 8,    -- tail center
    cx + 10, cy + 4     -- right wing
  )
  g.setColor(0, 0, 0, 0.5)
  g.setLineWidth(1)
  g.polygon("line",
    cx,      cy - 16,
    cx - 10, cy + 4,
    cx,      cy + 8,
    cx + 10, cy + 4
  )

  -- status text (minimal HUD placeholder)
  local kb = love.keyboard.isDown
  g.setColor(0.6, 0.6, 0.6, 0.85)
  g.print(string.format(
    "spd %3.0f  hdg %3.0f  fuel %2.0f%%  [%s]",
    self.speed, self.angle, self.fuel,
    self.airborne and "airborne" or "landed"
  ), cx - 160, cy + 26)

  g.setColor(1, 1, 1)
end

return Player
