-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local Scene = require "engine.core.scene"
local Menu  = require "engine.ui.menu"

-- NEW GAME mode picker, in the main menu's style: a solo or a two-player
-- split-screen campaign, both continuing to the vehicle select screen. Reached
-- by replacing the main menu (a running game underneath stays suspended until
-- a run actually starts); CANCEL and Esc put the main menu back.
local NewGame = Class(Scene)

NewGame.ui_pointer = true

local ENTRIES = {
    { id = "solo",   label = "SOLO CAMPAIGN" },
    { id = "coop",   label = "LOCAL COOP", gap_after = 8 },
    { id = "cancel", label = "CANCEL" },
}

function NewGame:init(app)
    Scene.init(self, app)
    self.menu = Menu:new(ENTRIES)
    self.menu.on_select = function(id) self:_select(id) end
end

function NewGame:enter()  self.menu:open()  end
function NewGame:leave()  self.menu:close() end

function NewGame:_select(id)
    local scenes = self.app.scenes
    if id == "solo" or id == "coop" then
        scenes:replace("vehicle_select", { players = (id == "coop") and 2 or 1, return_to = "new_game" })
    else
        scenes:replace("main_menu")
    end
end

function NewGame:keypressed(key)
    if key == "escape" then self.app.scenes:replace("main_menu"); return end
    self.menu:keypressed(key)
end

function NewGame:update(dt)          self.menu:update(dt)  end
function NewGame:draw()              self.menu:draw()      end
function NewGame:mousemoved(x, y)    self.menu:hover(x, y) end
function NewGame:mousepressed(x, y)  self.menu:press(x, y) end
function NewGame:mousereleased(x, y) self.menu:release(x, y) end

return NewGame
