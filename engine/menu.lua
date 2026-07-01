local Class = require "engine.class"

-- Main menu, styled after the original MAINP.BIN screen (NEW GAME / RESUME /
-- OPTIONS / CREDITS / HIGH SCORES / LOAD / SAVE / ORDER INFO / EXIT over the
-- MAINP backdrop, with a triangular cursor next to the highlighted entry).
-- Purely presentational: Menu:keypressed returns the id of a confirmed entry
-- and the caller (main.lua) decides what that means.
--
-- Entry labels and the selection arrow are the original's own pre-rendered
-- art (MAINMEN.BIN word sprites plus the arrow cropped from MAINMENU.BMP,
-- see tools/export_mainmen.py), not live-drawn: exported truecolor straight
-- through the captured runtime menu palette, so they match the original screen
-- pixel for pixel.
local Menu = Class()

-- Design canvas (the original screen is 320x240); every offset below is in
-- these coordinates, scaled to fit the window like Screen / EndStats. Only
-- the foreground (labels + arrow) uses this letterboxed space -- the
-- backdrop is stretched to fully cover the real window instead (see draw()).
local DW, DH = 320, 240

local ROW_X   = 60      -- label left edge
local ROW_Y0  = 38      -- first row top
local ROW_DY  = 20      -- row pitch
local DIM_ALPHA = 0.35  -- disabled-entry alpha

local ARROW_H   = 13    -- fallback if arrow.png is missing
local ARROW_GAP = 8     -- gap between the arrow tip and the label
local ARROW_SPEED = 12  -- higher = snappier tween between rows

local Menu_DEFAULT_ENTRIES = {
  { id = "new_game",   label = "NEW GAME" },
  { id = "resume",     label = "RESUME",     enabled = false },
  { id = "options",    label = "OPTIONS" },
  { id = "credits",    label = "CREDITS" },
  { id = "hiscores",   label = "HIGH SCORES" },
  { id = "load",       label = "LOAD",       enabled = false },
  { id = "save",       label = "SAVE",       enabled = false },
  { id = "order_info", label = "ORDER INFO", enabled = false, gap_after = 8 },
  { id = "exit",       label = "EXIT" },
}

function Menu:init(entries)
  -- Copy so each instance owns its entries (enabled/y are mutated in place)
  -- rather than sharing / clobbering the module-level defaults.
  self.entries = {}
  for i, e in ipairs(entries or Menu_DEFAULT_ENTRIES) do
    self.entries[i] = { id = e.id, label = e.label, enabled = e.enabled, gap_after = e.gap_after }
  end
  self.cursor  = 1
  self.t       = 0
  self.active  = false

  local y = ROW_Y0
  for _, e in ipairs(self.entries) do
    e.y = y
    local ok, img = pcall(love.graphics.newImage, "assets/mainmen/" .. e.id .. ".png")
    if ok then
      img:setFilter("nearest", "nearest")
      e.img = img
    else
      print("menu: missing assets/mainmen/" .. e.id .. ".png")
    end
    e.mid_y = y + (img and img:getHeight() or ARROW_H) / 2
    y = y + ROW_DY + (e.gap_after or 0)
  end
  self.arrow_y = self.entries[1] and self.entries[1].mid_y or ROW_Y0

  local ok, img = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
  if ok then
    img:setFilter("nearest", "nearest")
    self.bg = img
  else
    print("menu: missing assets/fullscreen/MAINP.png")
    self.bg = nil
  end

  local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
  if aok then
    arrow:setFilter("nearest", "nearest")
    self.arrow = arrow
  else
    print("menu: missing assets/mainmen/arrow.png")
    self.arrow = nil
  end
end

function Menu:is_active() return self.active end

-- Opens on whatever entry is currently under the cursor, sliding onto the
-- nearest enabled one if it isn't selectable any more (e.g. RESUME just got
-- disabled because the game the menu was opened over no longer exists).
function Menu:open()
  self.active = true
  self.t = 0
  if self.entries[self.cursor] and self.entries[self.cursor].enabled == false then
    self:_move(1)
  end
  local e = self.entries[self.cursor]
  self.arrow_y = e and e.mid_y or ROW_Y0  -- snap on open, tween on navigation
end

function Menu:close()
  self.active = false
end

function Menu:set_enabled(id, enabled)
  for _, e in ipairs(self.entries) do
    if e.id == id then e.enabled = enabled end
  end
  if not self.active then return end
  if self.entries[self.cursor] and self.entries[self.cursor].enabled == false then
    self:_move(1)
  end
end

function Menu:_move(dir)
  local n = #self.entries
  local i = self.cursor
  for _ = 1, n do
    i = ((i - 1 + dir) % n) + 1
    if self.entries[i].enabled ~= false then
      self.cursor = i
      return
    end
  end
end

-- Returns the id of a confirmed entry (Enter/Space on an enabled row), else
-- nil. Navigation keys are consumed internally and also return nil.
function Menu:keypressed(key)
  if not self.active then return nil end
  if key == "up" then
    self:_move(-1)
  elseif key == "down" then
    self:_move(1)
  elseif key == "return" or key == "space" or key == "kpenter" then
    local e = self.entries[self.cursor]
    if e and e.enabled ~= false then return e.id end
  end
  return nil
end

function Menu:update(dt)
  if not self.active then return end
  self.t = self.t + dt
  local e = self.entries[self.cursor]
  if e then
    -- Exponential ease toward the selected row instead of an instant jump.
    local k = 1 - math.exp(-ARROW_SPEED * dt)
    self.arrow_y = self.arrow_y + (e.mid_y - self.arrow_y) * k
  end
end

-- Original gold arrow sprite, right edge ARROW_GAP left of the label column,
-- tweened to self.arrow_y (see update()).
function Menu:_draw_arrow(g)
  if not self.arrow then return end
  local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
  g.setColor(1, 1, 1, 1)
  g.draw(self.arrow, ROW_X - ARROW_GAP - aw, self.arrow_y - ah / 2)
end

function Menu:draw()
  local g      = love.graphics
  local sw, sh = g.getDimensions()

  -- Backdrop: always stretched to fully cover the window (no letterbox bars),
  -- plus a slow breathing zoom that only ever zooms in so it can never expose
  -- an edge.
  if self.bg then
    local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
    local bw, bh  = sw * breathe, sh * breathe
    g.setColor(1, 1, 1, 1)
    g.draw(self.bg, (sw - bw) / 2, (sh - bh) / 2, 0,
      bw / self.bg:getWidth(), bh / self.bg:getHeight())
  else
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, sw, sh)
  end

  -- Foreground (labels + cursor) stays in the fixed 320x240 design space so
  -- proportions don't skew with the window's aspect ratio.
  local sc = math.min(sw / DW, sh / DH)
  g.push()
  g.translate((sw - DW * sc) / 2, (sh - DH * sc) / 2)
  g.scale(sc, sc)

  for i, e in ipairs(self.entries) do
    if e.img then
      local a = (e.enabled == false) and DIM_ALPHA or 1
      g.setColor(1, 1, 1, a)
      g.draw(e.img, ROW_X, e.y)
    end
    if i == self.cursor then
      self:_draw_arrow(g)
    end
  end

  g.pop()
  g.setColor(1, 1, 1, 1)
end

return Menu
