-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- One tick's input for one player: the held-action bitmask, the edge actions
-- that fired during the tick, and an optional analog turn. This is the only way input reaches the simulation,
-- and it is the same value a keyboard, a replay file and (later) a network peer
-- produce, which is what makes a run reproducible.
local InputFrame = {}

-- Held actions, one bit each. This order is the replay wire format: append new
-- actions, never reorder them, or old recordings decode as different input.
InputFrame.HELD = { "up", "down", "left", "right", "modifier", "fire" }

local BIT = {}
for i, action in ipairs(InputFrame.HELD) do BIT[action] = 2 ^ (i - 1) end
InputFrame.BIT = BIT

-- Analog turn resolution: turn is an integer in [-TURN_STEPS, TURN_STEPS], so it
-- is exact in a replay file. nil means digital (left/right bits at full rate).
InputFrame.TURN_STEPS = 32

InputFrame.EMPTY = { mask = 0, events = {} }

function InputFrame.held(frame, action)
    local bit = BIT[action]
    if not (frame and bit) then return false end
    return math.floor(frame.mask / bit) % 2 == 1
end

-- Edge actions a frame may carry: "takeoff", "weapon" (cycle), "god",
-- "pickup_mode", "level", "destruct" (free play: wreck the own vehicle), and
-- "slot:N" (select weapon N). Anything not in this set is
-- ignored on playback, so a newer recording stays loadable.
function InputFrame.new(mask, events, turn)
    return { mask = mask or 0, events = events or {}, turn = turn }
end

-- The analog turn for a stick deflection x in [-1, 1]: zero up to dead_zone,
-- then linear to full. nil when the stick is not steering.
function InputFrame.turn_steps(x, dead_zone)
    local reach = math.abs(x)
    if reach <= dead_zone then return nil end
    local step = math.floor(math.min(1, (reach - dead_zone) / (1 - dead_zone)) * InputFrame.TURN_STEPS + 0.5)
    if step == 0 then return nil end
    return x < 0 and -step or step
end

-- Signed turn rate in [-1, 1] for an analog frame, nil for a digital one.
function InputFrame.turn(frame)
    if not (frame and frame.turn) then return nil end
    return frame.turn / InputFrame.TURN_STEPS
end

return InputFrame
