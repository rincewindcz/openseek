local Class     = require "engine.core.class"
local Scene     = require "engine.core.scene"
local Animation = require "engine.core.animation"

-- Test overlay scene: plays every clip in data/animations.json at once in a
-- labelled grid so new effects (e.g. the iron/metal debris) can be eyeballed.
-- Non-looping clips are restarted when they finish so they keep playing.
local AnimGallery = Class(Scene)

function AnimGallery:enter()
    if self.items then return end   -- built lazily, once
    self.items = {}
    for _, name in ipairs(Animation.clip_names()) do
        self.items[#self.items + 1] = { name = name, state = Animation.new(name) }
    end
end

function AnimGallery:update(dt)
    for _, it in ipairs(self.items) do
        it.state:update(dt)
        if it.state:is_done() then it.state:reset() end
    end
end

function AnimGallery:keypressed(key)
    if key == "f8" or key == "escape" then self.app.scenes:switch("main_menu") end
end

function AnimGallery:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0.06, 0.06, 0.09, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(0.6, 0.9, 1, 1)
    g.print("ANIMATION GALLERY  -  every clip in data/animations.json, looping.   F8 / Esc: close", 10, 8)

    local items = self.items or {}
    local cols  = 8
    local rows  = math.max(1, math.ceil(#items / cols))
    local top   = 30
    local cw, ch = screen_w / cols, (screen_h - top) / rows
    for i, it in ipairs(items) do
        local r  = math.floor((i - 1) / cols)
        local c  = (i - 1) % cols
        local cx = c * cw + cw / 2
        local cy = top + r * ch + (ch - 16) / 2
        g.setColor(1, 1, 1, 0.05)
        g.rectangle("line", c * cw + 2, top + r * ch + 2, cw - 4, ch - 4)
        local img = it.state:current_image()
        if img then
            local iw, ih = img:getDimensions()
            local s = math.max(1, math.min(6, math.min((cw - 16) / iw, (ch - 30) / ih)))
            g.setColor(1, 1, 1, 1)
            g.draw(img, cx, cy, 0, s, s, iw / 2, ih / 2)
        end
        g.setColor(0.8, 0.85, 0.9, 1)
        g.print(it.name, cx - g.getFont():getWidth(it.name) / 2, top + r * ch + ch - 15)
    end
    g.setColor(1, 1, 1)
end

return AnimGallery
