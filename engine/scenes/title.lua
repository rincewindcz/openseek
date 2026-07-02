local Class = require "engine.core.class"
local Scene = require "engine.core.scene"

-- Boot scene: the TITLE card fading in over black. Draws an opaque fill every
-- frame so the overview never flashes during the intro; done or Esc drops
-- into the main menu.
local Title = Class(Scene)

function Title:enter()
    local app = self.app
    local function to_menu() app.scenes:switch("main_menu") end
    app.screen:show("TITLE", {
        fade_in   = 0.6,
        hold      = 2.0,
        fade_out  = 0.6,
        on_done   = to_menu,
        on_cancel = to_menu,
    })
end

function Title:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(1, 1, 1)
end

return Title
