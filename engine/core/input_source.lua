-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local InputFrame = require "engine.core.input_frame"

-- Where a player's per-tick input frames come from. A gameplay scene builds one
-- source per player slot and asks each for the current tick's frame; the
-- simulation never touches the keyboard itself. Swapping the source is what turns
-- live play into playback, and is where a network peer will plug in.
local InputSource = {}

-- Live input. bindings maps an action to a key name or a list of key names
-- (any held counts), so it takes either the rebindable single-player map
-- (engine/core/input.lua) or a co-op player's fixed key set. devices lists what
-- else drives the player, each answering held(action) and turn(): the touch
-- controls (engine/ui/touch_controls.lua), a gamepad (engine/core/gamepad.lua),
-- the mouse stick (engine/core/mouse_stick.lua).
local LocalSource = Class()
InputSource.Local = LocalSource

function LocalSource:init(bindings, devices)
    self.bindings = bindings or {}
    self.devices  = devices or {}
    self.pending  = {}   -- edge actions queued by keypressed, drained next tick
end

function LocalSource:_down(action)
    for _, device in ipairs(self.devices) do
        if device:held(action) then return true end
    end
    local binding = self.bindings[action]
    if not binding then return false end
    if type(binding) == "table" then
        for _, key in ipairs(binding) do
            if love.keyboard.isDown(key) then return true end
        end
        return false
    end
    return love.keyboard.isDown(binding)
end

-- Queue an edge action (from love.keypressed) onto the next tick's frame, so a
-- key press lands on a tick boundary instead of between two of them.
function LocalSource:queue(event)
    self.pending[#self.pending + 1] = event
end

function LocalSource:frame(_tick)
    local mask = 0
    for _, action in ipairs(InputFrame.HELD) do
        if self:_down(action) then mask = mask + InputFrame.BIT[action] end
    end
    -- The first device steering by an analog amount sets the turn rate.
    local turn
    for _, device in ipairs(self.devices) do
        turn = turn or device:turn()
    end
    local events = self.pending
    self.pending = {}
    return InputFrame.new(mask, events, turn)
end

-- Recorded input. provider is anything answering frame_for(tick, slot), i.e. a
-- loaded Replay. Ticks past the end of the recording return an empty frame, so a
-- replay that outlives its input simply stops steering.
local ReplaySource = Class()
InputSource.Replay = ReplaySource

function ReplaySource:init(provider, slot)
    self.provider = provider
    self.slot     = slot
end

function ReplaySource:queue(_event) end   -- live keys are ignored during playback

function ReplaySource:frame(tick)
    return self.provider:frame_for(tick, self.slot) or InputFrame.EMPTY
end

return InputSource
