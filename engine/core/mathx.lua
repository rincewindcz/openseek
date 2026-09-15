-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Math helpers shared across the engine.
local Mathx = {}

-- LuaJIT (LOVE) has math.atan2; Lua 5.3+ folds it into math.atan(y, x).
Mathx.atan2 = math.atan2 or math.atan

-- Heading in the game angle convention (degrees, 0 = north, clockwise
-- positive) toward a world-space delta.
function Mathx.heading_deg(dx, dy)
    return (math.deg(Mathx.atan2(dy, dx)) + 90) % 360
end

return Mathx
