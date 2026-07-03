local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Font       = require "engine.core.font"
local Layout     = require "engine.ui.layout"
local InfoScreen = require "engine.ui.info_screen"

-- Credits scene: the CREDITS backdrop with the flying-in CREDITS title, the
-- authoring lines, and an EXIT button bottom-right. Reached from the main menu's
-- CREDITS entry via replace(); EXIT returns to the menu the same way.
local Credits = Class(Scene)

Credits.ui_pointer = true

local DW = Layout.DESIGN_W
local NAME_COLOR = { 1, 0.8, 0.2 }   -- high-score gold

function Credits:init(app)
    Scene.init(self, app)
    self.screen = InfoScreen:new("CREDITS", "credits_title")
    self.screen.on_exit = function() self.app.scenes:replace("main_menu") end

    self.heading_font = Font.get("mainmen")   -- menu word art (uppercase only)
    self.name_font    = Font.get("hichars")   -- high-score font

    -- mainmen has no lowercase glyphs, so the heading is drawn upper case.
    self.heading = "OPENSEEK PROGRAMMING"
    self.name    = "Michal Genserek"

    self.screen.on_draw_content = function(_, fade)
        self.heading_font:print(self.heading,
            (DW - self.heading_font:width(self.heading)) / 2, 118,
            { color = { 1, 1, 1, fade } })
        self.name_font:print(self.name,
            (DW - self.name_font:width(self.name)) / 2, 142,
            { color = { NAME_COLOR[1], NAME_COLOR[2], NAME_COLOR[3], fade } })
    end
end

function Credits:enter()             self.screen:open()          end
function Credits:leave()             self.screen:close()         end
function Credits:update(dt)          self.screen:update(dt)      end
function Credits:draw()              self.screen:draw()          end
function Credits:keypressed(key)     self.screen:keypressed(key) end
function Credits:mousemoved(x, y)    self.screen:hover(x, y)     end
function Credits:mousepressed(x, y)  self.screen:press(x, y)     end
function Credits:mousereleased(x, y) self.screen:release(x, y)   end

return Credits
