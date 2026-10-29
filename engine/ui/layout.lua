-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Shared design space and letterbox transform for the non-game UI screens.
-- Menus lay out in the original 320x240 screen space and scale to the window.
local Layout = {}

Layout.DESIGN_W = 320
Layout.DESIGN_H = 240

local SIDE_WEIGHT = 4     -- cost of a pixel off the line of a focus move against one along it
local MAX_SLOPE   = 0.25  -- pixels off the line per pixel along it a focus move may turn

local DIRECTIONS = {
    up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

-- Gap between the spans [a0, a1) and [b0, b1); 0 when they overlap.
local function gap(a0, a1, b0, b1)
    return math.max(0, b0 - a1, a0 - b1)
end

-- Letterbox fit of the design canvas into the window. Returns the uniform
-- scale and the x/y offset that centers the scaled canvas.
function Layout.fit(screen_w, screen_h, design_w, design_h)
    design_w = design_w or Layout.DESIGN_W
    design_h = design_h or Layout.DESIGN_H
    local scale = math.min(screen_w / design_w, screen_h / design_h)
    return scale,
        (screen_w - design_w * scale) / 2,
        (screen_h - design_h * scale) / 2
end

-- The widget a keyboard focus move from rect `from` lands on: of the zones
-- ({ x, y, w, h }) accept passes (all when nil), one whose centre lies ahead
-- of from's in direction key ("up" / "down" / "left" / "right") and whose
-- edge gap across the move is at most MAX_SLOPE of the gap along it, ranked by
-- the gap along plus the weighted gap across, so a widget in line beats a
-- nearer diagonal one. nil when nothing lies that way.
function Layout.nearest(zones, from, key, accept)
    local dir = DIRECTIONS[key]
    if not dir then return nil end
    local cx, cy = from.x + from.w / 2, from.y + from.h / 2
    local best, best_cost
    for _, z in ipairs(zones) do
        local ahead = (z.x + z.w / 2 - cx) * dir[1] + (z.y + z.h / 2 - cy) * dir[2]
        if z ~= from and ahead > 0 and (not accept or accept(z)) then
            local gap_x = gap(from.x, from.x + from.w, z.x, z.x + z.w)
            local gap_y = gap(from.y, from.y + from.h, z.y, z.y + z.h)
            local along, across = gap_y, gap_x
            if dir[1] ~= 0 then along, across = gap_x, gap_y end
            local cost = along + across * SIDE_WEIGHT
            if across <= along * MAX_SLOPE and (not best_cost or cost < best_cost) then
                best, best_cost = z, cost
            end
        end
    end
    return best
end

return Layout
