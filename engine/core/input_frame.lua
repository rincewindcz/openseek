-- One tick's input for one player: the held-action bitmask plus the edge actions
-- that fired during the tick. This is the only way input reaches the simulation,
-- and it is the same value a keyboard, a replay file and (later) a network peer
-- produce, which is what makes a run reproducible. See DETERMINISM.md.
local InputFrame = {}

-- Held actions, one bit each. This order is the replay wire format: append new
-- actions, never reorder them, or old recordings decode as different input.
InputFrame.HELD = { "up", "down", "left", "right", "modifier", "fire" }

local BIT = {}
for i, action in ipairs(InputFrame.HELD) do BIT[action] = 2 ^ (i - 1) end
InputFrame.BIT = BIT

InputFrame.EMPTY = { mask = 0, events = {} }

function InputFrame.held(frame, action)
    local bit = BIT[action]
    if not (frame and bit) then return false end
    return math.floor(frame.mask / bit) % 2 == 1
end

-- Edge actions a frame may carry: "takeoff", "weapon" (cycle), "god",
-- "pickup_mode", and "slot:N" (select weapon N). Anything not in this set is
-- ignored on playback, so a newer recording stays loadable.
function InputFrame.new(mask, events)
    return { mask = mask or 0, events = events or {} }
end

return InputFrame
