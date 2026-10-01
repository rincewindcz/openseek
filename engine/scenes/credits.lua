-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Font       = require "engine.core.font"
local Assets     = require "engine.core.assets"
local InfoScreen = require "engine.ui.info_screen"
local json       = require "lib.json"

-- Credits scene: the CREDITS backdrop with the flying-in CREDITS title, the
-- credits entries, and an EXIT button bottom-right. data/credits.json places
-- each entry in the 320x240 design space and names its style: a heading over a
-- name (large for openSEEK, small for the original team, in the fonts of the
-- original credits) or a single label line. Reached from the main menu's
-- CREDITS entry via replace(); EXIT returns to the menu the same way. After
-- the ending, enter(on_exit) is given where EXIT goes instead.
local Credits = Class(Scene)

Credits.ui_pointer = true

local DATA_PATH     = "data/credits.json"
local FALLBACK_FONT = "hichars"   -- a pack exported before credchars existed
local WHITE         = { 1, 1, 1 }

local function font(name)
    if not name or not Assets.exists("fonts/" .. name .. ".json") then name = FALLBACK_FONT end
    return Font.get(name)
end

function Credits:init(app)
    Scene.init(self, app)
    self.screen = InfoScreen:new("CREDITS", "credits_title")
    self.screen.on_exit = function()
        if self.on_exit then self.on_exit() else self.app.scenes:replace("main_menu") end
    end

    local raw  = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    local data = raw and json.decode(raw) or {}
    self.styles = {}
    for name, s in pairs(data.styles or {}) do
        self.styles[name] = {
            heading_font = s.heading_font and font(s.heading_font),
            name_font    = s.name_font and font(s.name_font),
            font         = s.font and font(s.font),
            name_dy      = s.name_dy or 0,
            color        = s.color or WHITE,
        }
    end
    self.entries = data.entries or {}

    self.screen.on_draw_content = function(_, fade) self:_draw_entries(fade) end
end

function Credits:_draw_entries(fade)
    for _, e in ipairs(self.entries) do
        local s = self.styles[e.style]
        if s then
            local color = { s.color[1], s.color[2], s.color[3], fade }
            if e.text and s.font then s.font:print(e.text, e.x, e.y, { color = color }) end
            if e.heading and s.heading_font then
                s.heading_font:print(e.heading, e.x, e.y, { color = color })
            end
            if e.name and s.name_font then
                s.name_font:print(e.name, e.x, e.y + s.name_dy, { color = color })
            end
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function Credits:enter(on_exit)
    self.on_exit = on_exit
    self.screen:open()
end

function Credits:leave()             self.screen:close()         end
function Credits:update(dt)          self.screen:update(dt)      end
function Credits:draw()              self.screen:draw()          end
function Credits:keypressed(key)     self.screen:keypressed(key) end
function Credits:mousemoved(x, y)    self.screen:hover(x, y)     end
function Credits:mousepressed(x, y)  self.screen:press(x, y)     end
function Credits:mousereleased(x, y) self.screen:release(x, y)   end

return Credits
