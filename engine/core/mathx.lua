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

-- A polyline of { x, y } points on a map wrapping every `size` pixels, each
-- point moved by whole periods to lie the short way from the one before it,
-- so a line crossing the seam runs across it instead of the long way round.
-- The first point stays; returns a new list.
function Mathx.unwrap(points, size)
    local out = {}
    for i, p in ipairs(points) do
        local last = out[i - 1]
        if last then
            local dx = (p[1] - last[1]) % size
            local dy = (p[2] - last[2]) % size
            if dx > size * 0.5 then dx = dx - size end
            if dy > size * 0.5 then dy = dy - size end
            out[i] = { last[1] + dx, last[2] + dy }
        else
            out[i] = { p[1], p[2] }
        end
    end
    return out
end

return Mathx
