-- Shared mouse/touch pointer for the non-game screens (main menu, mission menu,
-- and any other letterboxed UI). Draws the original SELPOINT cursor at the OS
-- pointer, and converts window pixels into the fixed 320x240 design space so the
-- menus can hit-test their widgets against exactly the transform they draw with.
--
-- This is a plain singleton module (one pointer for the whole app), not a Class.
local Pointer = {}

local DW, DH = 320, 240

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
    print("pointer: missing assets/hud/selpoint_f00.png")
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
-- (sc = min(sw/DW, sh/DH), centered). Returns design x, y and the scale.
function Pointer.to_design(x, y, dw, dh)
  dw, dh = dw or DW, dh or DH
  local sw, sh = love.graphics.getDimensions()
  local sc = math.min(sw / dw, sh / dh)
  return (x - (sw - dw * sc) / 2) / sc, (y - (sh - dh * sc) / 2) / sc, sc
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
  dw, dh = dw or DW, dh or DH
  local g = love.graphics
  local sw, sh = g.getDimensions()
  local sc = math.min(sw / dw, sh / dh)
  g.setColor(1, 1, 1, 1)
  g.draw(cursor, Pointer.x, Pointer.y, 0, sc, sc)
end

return Pointer
