-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Config     = require "engine.core.config"
local Input      = require "engine.core.input"
local InputFrame = require "engine.core.input_frame"

-- A gamepad as an input device: any controller SDL has a mapping for (a LOVE
-- Joystick answering isGamepad). An instance answers held(action) and turn()
-- the way the touch controls do, so InputSource.Local samples it once per tick;
-- button presses reach the scenes as padpressed events (main.lua). Pads are
-- numbered in connection order: Gamepad:new(n) reads pad n, Gamepad:new() every
-- pad (single player).
--
-- The left stick steers: sideways turns at an analog rate, forward and back
-- drive. The right stick sideways is STRAFE at an analog rate (the chopper
-- slides, the tank turns its turret) and wins over the left stick. Buttons
-- follow Input.pad_map; the triggers count as the buttons "triggerleft" and
-- "triggerright".
local Gamepad = Class()

local DRIVE_THRESHOLD   = 0.5   -- stick deflection that drives or reverses
local TRIGGER_THRESHOLD = 0.5
local MENU_THRESHOLD    = 0.6   -- left stick deflection that steps a menu
local MENU_RELEASE      = 0.7   -- fraction of MENU_THRESHOLD a tipped stick lets go at

local BUTTONS = {
    a = true, b = true, x = true, y = true, back = true, guide = true, start = true,
    leftstick = true, rightstick = true, leftshoulder = true, rightshoulder = true,
    dpup = true, dpdown = true, dpleft = true, dpright = true,
}
local TRIGGERS = { triggerleft = true, triggerright = true }

-- The d-pad buttons a tipped left stick stands for, per axis: { negative, positive }.
local STICK_BUTTONS = { leftx = { "dpleft", "dpright" }, lefty = { "dpup", "dpdown" } }

-- What a button means to a menu screen, as the key it stands for.
Gamepad.MENU_KEYS = {
    dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
    a = "return", start = "return", b = "escape", back = "escape",
}

-- The button that opens the in-game menu. Not rebindable.
Gamepad.MENU_BUTTON = "start"

local pads       = {}   -- connected gamepads in connection order
local axis_state = {}   -- joystick id .. axis -> the button that axis currently holds

-- Re-read the connected pads. Called at startup and whenever a joystick comes or goes.
function Gamepad.refresh()
    pads = {}
    if not love.joystick then return end
    for _, joystick in ipairs(love.joystick.getJoysticks()) do
        if joystick:isGamepad() then pads[#pads + 1] = joystick end
    end
end

function Gamepad.count()
    return #pads
end

-- The pad number of a joystick, or nil when it is not a connected gamepad.
function Gamepad.index_of(joystick)
    for i, pad in ipairs(pads) do
        if pad == joystick then return i end
    end
    return nil
end

-- Turn an axis move into a button press: a trigger pulled past its threshold, or
-- the left stick tipping into a direction (reported as that d-pad button).
-- Returns the button and whether it came from the stick, or nil.
function Gamepad.axis_pressed(joystick, axis, value)
    local stick = STICK_BUTTONS[axis]
    if not (stick or TRIGGERS[axis]) then return nil end
    local key = joystick:getID() .. axis
    local was = axis_state[key]
    local now
    if stick then
        local limit = was and MENU_THRESHOLD * MENU_RELEASE or MENU_THRESHOLD
        now = (value < -limit and stick[1]) or (value > limit and stick[2]) or nil
    else
        now = value > TRIGGER_THRESHOLD and axis or nil
    end
    axis_state[key] = now
    if now and now ~= was then return now, stick ~= nil end
    return nil
end

-- Share the connected pads among players. wanted lists one choice per player:
-- "auto", "keys", "pad1", "pad2", ... Returns the pad number per player, false
-- for the keyboard alone. A named pad that is not connected, or that an earlier
-- player holds, falls back to the keyboard. The "auto" players take the pads
-- left over; when those run short the later players get them, so with one pad
-- player 1 keeps the keyboard.
function Gamepad.assign(wanted)
    local out, taken, autos = {}, {}, {}
    for i, choice in ipairs(wanted) do
        local n = tonumber(tostring(choice):match("^pad(%d+)$"))
        out[i] = false
        if n and n <= #pads and not taken[n] then
            out[i], taken[n] = n, true
        elseif choice == "auto" then
            autos[#autos + 1] = i
        end
    end
    local free = {}
    for n = 1, #pads do
        if not taken[n] then free[#free + 1] = n end
    end
    local skip = math.max(0, #autos - #free)
    for k = 1, #autos - skip do out[autos[skip + k]] = free[k] end
    return out
end

function Gamepad:init(index)
    self.index = index   -- pad number; nil reads every connected pad
end

local function button_down(pad, name)
    if TRIGGERS[name] then return pad:getGamepadAxis(name) > TRIGGER_THRESHOLD end
    return BUTTONS[name] ~= nil and pad:isGamepadDown(name)
end

-- The sideways deflection that steers and whether it is the right stick's
-- (a strafe). Zero inside the dead zone.
local function steer(pad, dead)
    local right = pad:getGamepadAxis("rightx")
    if math.abs(right) > dead then return right, true end
    local left = pad:getGamepadAxis("leftx")
    if math.abs(left) > dead then return left, false end
    return 0, false
end

local function pad_held(pad, action, dead)
    for _, name in ipairs(Input.pad_map[action] or {}) do
        if button_down(pad, name) then return true end
    end
    if action == "up"   then return pad:getGamepadAxis("lefty") < -DRIVE_THRESHOLD end
    if action == "down" then return pad:getGamepadAxis("lefty") >  DRIVE_THRESHOLD end
    local x, strafe = steer(pad, dead)
    if action == "left"     then return x < 0 end
    if action == "right"    then return x > 0 end
    if action == "modifier" then return strafe end
    return false
end

-- First and last pad number this device reads.
function Gamepad:_range()
    if self.index then return self.index, self.index end
    return 1, #pads
end

function Gamepad:held(action)
    local first, last = self:_range()
    for i = first, last do
        if pads[i] and pad_held(pads[i], action, Config.pad_dead_zone) then return true end
    end
    return false
end

-- Analog turn in InputFrame steps, or nil when no stick is steering.
function Gamepad:turn()
    local first, last = self:_range()
    for i = first, last do
        if pads[i] then
            local step = InputFrame.turn_steps(steer(pads[i], Config.pad_dead_zone), Config.pad_dead_zone)
            if step then return step end
        end
    end
    return nil
end

return Gamepad
