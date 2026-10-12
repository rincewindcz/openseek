-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local StrictMath = require "lib.strict_math"

-- Math helpers shared across the engine.
local Mathx = {}

-- Heading in the game angle convention (degrees, 0 = north, clockwise
-- positive) toward a world-space delta.
function Mathx.heading_deg(dx, dy)
    return (StrictMath.deg(StrictMath.atan2(dy, dx)) + 90) % 360
end

return Mathx
