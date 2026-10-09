-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Text held to a fixed width, for values the player types at any length (save
-- slot names, high score names). The text is clipped to the width and shifted
-- left by an offset: `tail` keeps its end in view (the caret of a field being
-- typed into), `swing` pans a text that does not fit to its end and back, so
-- the whole value can be read.
local ScrollText = {}

local SWING_SPEED = 30    -- design px per second
local SWING_HOLD  = 1.2   -- seconds at rest on either end

-- The offset showing the end of the text.
function ScrollText.tail(font, text, width)
    return math.max(0, math.ceil(font:width(text) - width))
end

-- The offset t seconds into the pan; 0 for a text that fits.
function ScrollText.swing(font, text, width, t)
    local over = math.ceil(font:width(text) - width)
    if over <= 0 then return 0 end
    local travel = over / SWING_SPEED
    local phase  = t % (2 * (SWING_HOLD + travel))
    if phase < SWING_HOLD then return 0 end
    phase = phase - SWING_HOLD
    if phase < travel then return math.floor(phase * SWING_SPEED) end
    phase = phase - travel
    if phase < SWING_HOLD then return over end
    return over - math.floor((phase - SWING_HOLD) * SWING_SPEED)
end

-- Print text at (x, y) of the current transform, shifted left by `offset` and
-- clipped to `width`. opts as Font:print.
function ScrollText.print(font, text, x, y, width, offset, opts)
    if offset <= 0 and font:width(text) <= width then
        font:print(text, x, y, opts)
        return
    end
    local g = love.graphics
    local left, top      = g.transformPoint(x, y - font.line_height)
    local right, bottom  = g.transformPoint(x + width, y + 2 * font.line_height)
    local sx, sy, sw, sh = g.getScissor()
    g.intersectScissor(math.floor(left), math.floor(top),
        math.ceil(right - left), math.ceil(bottom - top))
    font:print(text, x - offset, y, opts)
    if sx then g.setScissor(sx, sy, sw, sh) else g.setScissor() end
end

return ScrollText
