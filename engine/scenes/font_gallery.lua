local Class = require "engine.core.class"
local Scene = require "engine.core.scene"
local Font  = require "engine.core.font"

-- Test overlay scene: renders every original bitmap font (assets/fonts/, from
-- tools/export_fonts.py) so glyph decode, mapping, and runtime tinting can be
-- eyeballed. Mask fonts are drawn tinted gold; truecolor fonts keep their own
-- palette.
local FontGallery = Class(Scene)

local FONT_SAMPLE = "ABCDEFGHIJKLM NOPQRSTUVWXYZ 0123456789 .,:!?-+"
local FONT_GOLD   = { 1.0, 0.78, 0.20 }

function FontGallery:keypressed(key)
    if key == "f9" or key == "escape" then self.app.scenes:switch("main_menu") end
end

function FontGallery:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0.06, 0.06, 0.09, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(0.6, 0.9, 1, 1)
    g.print("FONT GALLERY  -  original bitmap fonts, mask fonts tinted gold.   F9 / Esc: close", 10, 8)

    local y     = 40
    local scale = 2
    for _, name in ipairs(Font.NAMES) do
        local font = Font.get(name)
        g.setColor(0.55, 0.6, 0.7, 1)
        g.print(name, 10, y)
        local x = 130
        if font.word then
            font:print_word(x, y, { scale = scale, color = FONT_GOLD })
        else
            font:print(FONT_SAMPLE, x, y, { scale = scale, color = FONT_GOLD })
        end
        y = y + font.line_height * scale + 16
    end
    g.setColor(1, 1, 1)
end

return FontGallery
