-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Font = require "engine.core.font"

-- Co-op player identity for the screens: each player's colour, and a small
-- "PLAYER n" badge in it for the shared shop / equip screens a co-op run walks
-- through once per player. Draws in the caller's 320x240 design space.
local PlayerTag = {}

PlayerTag.COLORS = { { 0.30, 0.65, 1.0 }, { 1.0, 0.55, 0.15 } }  -- P1 blue, P2 orange

function PlayerTag.color(number)
    return PlayerTag.COLORS[number] or PlayerTag.COLORS[1]
end

function PlayerTag.draw(number, x, y, alpha)
    local g    = love.graphics
    local font = Font.get("keysfont")
    local col  = PlayerTag.color(number)
    local text = "PLAYER " .. number
    local w    = font:width(text) + 8
    local h    = font.line_height + 4
    alpha = alpha or 1
    g.setColor(0, 0, 0, 0.75 * alpha)
    g.rectangle("fill", x, y, w, h)
    g.setColor(col[1], col[2], col[3], alpha)
    g.setLineWidth(1)
    g.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    font:print(text, x + 4, y + 2, { color = { col[1], col[2], col[3], alpha } })
    g.setColor(1, 1, 1, 1)
end

return PlayerTag
