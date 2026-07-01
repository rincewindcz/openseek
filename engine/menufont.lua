local Class = require "engine.class"

-- Proportional font sliced from the original main-menu word art: each glyph is
-- one letter cut out of MAINMEN's pre-rendered entries (tools/export_mainmen.py
-- -> assets/mainmen/font/<LETTER>.png), so text drawn with it matches the
-- baked entries pixel for pixel. Only the letters that appear in the original
-- menu words exist (A C D E F G H I L M N O P R S T U V W X); the rest are
-- absent, so compose new labels from those. Uppercase only.
local MenuFont = Class()

local LETTER_SPACING = 1   -- px between glyphs, matching the original 1px gap
local SPACE_WIDTH    = 20  -- + the trailing letter spacing == the original 21px
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

function MenuFont:init()
  self.glyphs = {}
  self.height = 0
  for i = 1, #ALPHABET do
    local ch = ALPHABET:sub(i, i)
    local ok, img = pcall(love.graphics.newImage, "assets/mainmen/font/" .. ch .. ".png")
    if ok then
      img:setFilter("nearest", "nearest")
      self.glyphs[ch] = img
      self.height = math.max(self.height, img:getHeight())
    end
  end
end

function MenuFont:has(ch)
  return self.glyphs[ch] ~= nil
end

-- Width in design px of text drawn with draw(); unknown glyphs are skipped.
function MenuFont:width(text)
  local w = 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == " " then
      w = w + SPACE_WIDTH
    else
      local g = self.glyphs[ch]
      if g then w = w + g:getWidth() + LETTER_SPACING end
    end
  end
  return w
end

function MenuFont:draw(text, x, y, alpha)
  local g = love.graphics
  g.setColor(1, 1, 1, alpha or 1)
  local pen = x
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == " " then
      pen = pen + SPACE_WIDTH
    else
      local img = self.glyphs[ch]
      if img then
        g.draw(img, pen, y)
        pen = pen + img:getWidth() + LETTER_SPACING
      end
    end
  end
  g.setColor(1, 1, 1, 1)
end

return MenuFont
