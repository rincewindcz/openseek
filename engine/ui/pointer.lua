-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Shared mouse/touch pointer for the non-game screens (main menu, mission menu,
-- and any other letterboxed UI). Draws the original SELPOINT cursor at the OS
-- pointer, and converts window pixels into the fixed 320x240 design space so the
-- menus can hit-test their widgets against exactly the transform they draw with.
--
-- This is a plain singleton module (one pointer for the whole app), not a Class.
local Layout = require "engine.ui.layout"
local Log    = require "engine.core.log"

local Pointer = {}

local cursor  -- nil = not loaded yet, false = missing

-- Current pointer position in window pixels, whether the last input came from a
-- touch (so we suppress the cursor sprite, the finger is the pointer), and
-- whether we've seen any real input yet (avoid drawing a stale 0,0 cursor).
Pointer.x, Pointer.y = 0, 0
Pointer.touch = false
Pointer.seen  = false

local function load()
    if cursor ~= nil then return end
    local ok, i = pcall(love.graphics.newImage, "assets/hud/selpoint_f00.png")
    if ok then
        i:setFilter("nearest", "nearest")
        cursor = i
    else
        Log.warn("pointer", "missing assets/hud/selpoint_f00.png")
        cursor = false
    end
end

-- Record a pointer move (mouse or touch). touch=true suppresses the cursor sprite.
function Pointer.moved(x, y, touch)
    Pointer.x, Pointer.y = x, y
    Pointer.touch = touch or false
    Pointer.seen  = true
end

-- window px -> letterboxed design space, matching the menus' draw transform
-- (Layout.fit, centered). Returns design x, y and the scale.
function Pointer.to_design(x, y, dw, dh)
    local screen_w, screen_h = love.graphics.getDimensions()
    local scale, ox, oy = Layout.fit(screen_w, screen_h, dw, dh)
    return (x - ox) / scale, (y - oy) / scale, scale
end

-- Design-space position of the current pointer (convenience for hover updates).
function Pointer.design(dw, dh)
    return Pointer.to_design(Pointer.x, Pointer.y, dw, dh)
end

-- Draw the cursor at the OS pointer, scaled to match the menu art. Hotspot is the
-- sprite's top-left. Skipped for touch input and before the first real move.
function Pointer.draw(dw, dh)
    load()
    if not cursor or not Pointer.seen or Pointer.touch then return end
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local scale = Layout.fit(screen_w, screen_h, dw, dh)
    g.setColor(1, 1, 1, 1)
    g.draw(cursor, Pointer.x, Pointer.y, 0, scale, scale)
end

return Pointer
