local Class     = require "engine.class"
local Animation = require "engine.animation"

local Player = Class()

-- sprite frame constants (0-indexed, matching exported assets)
local PIT_NEUTRAL = 6    -- choppit1 neutral frame
local PIT_FRAMES  = 14
local BNK_NEUTRAL = 3    -- chopbnk1 neutral frame
local BNK_MAX_R   = 6    -- chopbnk1 max-right frame used
local DRP_FRAMES  = 5    -- chopdrp1 total frames
local TOP_FRAME   = 31   -- tanktop axis-aligned south frame
local STRAFE_THR  = 5    -- |strafe| threshold to switch bank/pitch mode

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

  self.world_size = 4096
  self.weapon_idx = 0
  self.vehicle    = "chopper"

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
  self.fuel_drain   = 2.0
  self.takeoff_time = 0.65
  self.land_time    = 0.50

  self._tank_anim    = Animation.new("tankbgrn")
  self._rotor_pitch  = Animation.new("bladep")
  self._rotor_bank   = Animation.new("bladeb")
  self._active_rotor = self._rotor_pitch

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
  self:_update_altitude(dt)
  self:_apply_input(dt)
  if self.land_state == "airborne" then
    self:_move(dt)
  end
  if self.land_state ~= "grounded" then
    self:_drain_fuel(dt)
  end
  self:_update_anims(dt)
end

function Player:_update_altitude(dt)
  if self.land_state == "taking_off" then
    local tt = self.takeoff_time > 0 and self.takeoff_time or 0.01
    self.altitude = math.min(1.0, self.altitude + dt / tt)
    if self.altitude >= 1.0 then
      self.altitude   = 1.0
      self.land_state = "airborne"
    end
  elseif self.land_state == "landing" then
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

function Player:_apply_input(dt)
  local kb = love.keyboard.isDown

  local rotate   = 0
  if kb("a") or kb("left")  then rotate = rotate - 1 end
  if kb("d") or kb("right") then rotate = rotate + 1 end

  local strafing = kb("lshift") or kb("rshift")

  -- smooth strafe toward target
  local strafe_target = 0
  if strafing then
    if kb("a") or kb("left")  then strafe_target = -self.strafe_speed end
    if kb("d") or kb("right") then strafe_target =  self.strafe_speed end
  end
  local sa = self.strafe_accel > 0 and self.strafe_accel or 9999
  if self.strafe < strafe_target then
    self.strafe = math.min(strafe_target, self.strafe + sa * dt)
  elseif self.strafe > strafe_target then
    self.strafe = math.max(strafe_target, self.strafe - sa * dt)
  end

  -- rotation only when shift is not held
  if not strafing and rotate ~= 0 then
    self.angle = (self.angle + rotate * self.turn_rate * dt) % 360
  end

  if self.land_state ~= "airborne" then return end

  local max_fwd = self.max_fwd * self.speed_factor
  local max_rev = self.max_rev * self.speed_factor

  if kb("w") or kb("up") then
    self.speed = math.min(self.speed + self.accel * self.speed_factor * dt, max_fwd)
  elseif kb("s") or kb("down") then
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
  local rad = (self.angle - 90) * math.pi / 180
  self.x = self.x + math.cos(rad) * self.speed * dt
  self.y = self.y + math.sin(rad) * self.speed * dt
  local sr = rad + math.pi / 2
  self.x = self.x + math.cos(sr) * self.strafe * dt
  self.y = self.y + math.sin(sr) * self.strafe * dt
  self.x = math.max(0, math.min(self.world_size, self.x))
  self.y = math.max(0, math.min(self.world_size, self.y))
end

function Player:_drain_fuel(dt)
  self.fuel = math.max(0, self.fuel - self.fuel_drain * dt)
end

function Player:_update_anims(dt)
  if self.vehicle == "tank" then
    if math.abs(self.speed) > 1 then self._tank_anim:update(dt) end
    return
  end
  -- always spin rotor; switch bank/pitch based on strafe state
  local next_rotor = math.abs(self.strafe) > STRAFE_THR
    and self._rotor_bank or self._rotor_pitch
  self._active_rotor = next_rotor
  if self.rotor_fps > 0 then
    self._active_rotor:update(dt * (self.rotor_fps / 40.0))
  end
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

function Player:is_dead()
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
  local sw, sh = g.getDimensions()
  local cx, cy = sw / 2, sh / 2
  local s      = self.sprite_scale

  g.setColor(1, 1, 1)
  if self.vehicle == "tank" then
    self:_draw_tank(g, cx, cy, s)
  else
    self:_draw_chopper(g, cx, cy, s)
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
  local rotor_img = self._active_rotor:current_image()
  self:_draw_centered(g, rotor_img, cx, cy + self.rotor_y_off, s)
end

function Player:_draw_tank(g, cx, cy, s)
  local body_frames = self:_frames("tankbgrn")
  local body_img    = body_frames[self._tank_anim.frame] or body_frames[1]
  self:_draw_centered(g, body_img, cx, cy, s)
  local top_frames = self:_frames("tanktop")
  local top_img    = top_frames[TOP_FRAME + 1]
  self:_draw_centered(g, top_img, cx, cy, s)
end

return Player
