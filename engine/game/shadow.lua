-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Ground shadows of aircraft (and, with soft shadows on, their rotors, damage
-- smoke, and missiles with their trails). The sun is fixed at the top-left of the unrotated
-- world, so shadows fall toward the bottom-right; because the world rotates in
-- game mode the shadow swings around the aircraft as the player turns. A shadow
-- is the aircraft body sprite drawn as a flat black silhouette (its own alpha as
-- the mask) on the ground, slid out and faded in proportion to altitude so a
-- landed flyer casts none. Night missions disable shadows (World:shadows_enabled).
local Shadow = {}

-- World-space cast direction (bottom-right), normalized.
Shadow.DIR_X  = 0.7071
Shadow.DIR_Y  = 0.7071
Shadow.ALPHA  = 0.4    -- silhouette opacity at full altitude
Shadow.SMOKE_ALPHA = 0.3   -- smoke puff silhouettes, thinner than a solid body
Shadow.ROTOR_ALPHA = 0.3   -- spinning rotor blades, blurred into a faint disc
Shadow.OFFSET = 12     -- offset at full altitude (world px; scaled by draw size for screen-space callers)

-- Draw an image as a flat black silhouette. Caller restores the draw color.
function Shadow.draw(img, x, y, rot, sx, sy, ox, oy, alpha)
    if not img then return end
    love.graphics.setColor(0, 0, 0, alpha)
    love.graphics.draw(img, x, y, rot, sx, sy, ox, oy)
end

return Shadow
