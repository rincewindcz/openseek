-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Config     = require "engine.core.config"
local InputFrame = require "engine.core.input_frame"

-- The mouse as a virtual stick, the way the original read it
-- (Config.mouse_control, single player only): the pointer's offset from the
-- vehicle on screen is the stick. Sideways turns at an analog rate, ahead of
-- the vehicle drives and behind it reverses; the left button fires and the
-- right one is STRAFE. An instance answers held(action) and turn() like the
-- touch controls and the gamepad, so InputSource.Local samples it once per
-- tick. The middle button and the wheel are edge actions the scene queues.
local MouseStick = Class()

local RANGE           = 0.25   -- pointer travel to full deflection, in window heights
local DEAD_ZONE       = 0.1
local DRIVE_THRESHOLD = 0.4

local BUTTONS = { fire = 1, modifier = 2 }

-- The button that takes off and lands.
MouseStick.TAKEOFF_BUTTON = 3

function MouseStick:init(camera)
    self.camera  = camera
    self.blocked = false   -- set by the scene while something else owns the pointer
end

function MouseStick:active()
    return Config.mouse_control and not self.blocked
end

-- Stick deflection in [-1, 1] per axis, y positive behind the vehicle.
function MouseStick:_offset()
    local cx, cy = self.camera:screen_center()
    local x, y   = love.mouse.getPosition()
    local _, h   = love.graphics.getDimensions()
    local range  = RANGE * h / Config.mouse_sensitivity
    return math.max(-1, math.min(1, (x - cx) / range)), math.max(-1, math.min(1, (y - cy) / range))
end

function MouseStick:held(action)
    if not self:active() then return false end
    local button = BUTTONS[action]
    if button then return love.mouse.isDown(button) end
    local x, y = self:_offset()
    if action == "up"    then return y < -DRIVE_THRESHOLD end
    if action == "down"  then return y >  DRIVE_THRESHOLD end
    if action == "left"  then return x < -DEAD_ZONE end
    if action == "right" then return x >  DEAD_ZONE end
    return false
end

-- Analog turn in InputFrame steps, or nil inside the dead zone.
function MouseStick:turn()
    if not self:active() then return nil end
    return InputFrame.turn_steps(self:_offset(), DEAD_ZONE)
end

return MouseStick
