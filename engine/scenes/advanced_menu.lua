-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local Scene = require "engine.core.scene"
local Menu  = require "engine.ui.menu"

-- ADVANCED submenu: the entries that are not part of a normal run (the mission
-- / phase picker, the overview editor view, the replay browser), kept off the
-- main menu so it stays short. Same Menu widget and backdrop as the main menu;
-- BACK returns to it. Not to be confused with advanced_settings, which is the
-- OPTIONS page. The editor is not ready for players: EDITOR answers with a
-- notice unless the game was started with --dev.
local AdvancedMenu = Class(Scene)

AdvancedMenu.ui_pointer = true

local ENTRIES = {
    { id = "mission", label = "MISSION" },
    { id = "replays", label = "REPLAYS" },
    { id = "editor",  label = "EDITOR",  gap_after = 8 },
    { id = "back",    label = "BACK" },
}

local EDITOR_NOTICE = "EDITOR IS IN DEVELOPMENT"

function AdvancedMenu:init(app)
    Scene.init(self, app)
    self.menu = Menu:new(ENTRIES)
    if not app.dev then self.menu:set_notice("editor", EDITOR_NOTICE) end
    self.menu.on_select = function(id) self:_select(id) end
end

function AdvancedMenu:enter()  self.menu:open()  end
function AdvancedMenu:leave()  self.menu:close() end

function AdvancedMenu:_select(id)
    local app = self.app
    if id == "mission" then
        app.scenes:replace("mission_select")
    elseif id == "replays" then
        app.scenes:replace("replay_select", { return_to = "advanced_menu" })
    elseif id == "editor" then
        app.scenes:switch("overview")
    elseif id == "back" then
        app.scenes:replace("main_menu")
    end
end

function AdvancedMenu:keypressed(key)
    if key == "escape" then
        self.app.scenes:replace("main_menu")
        return
    end
    self.menu:keypressed(key)
end

function AdvancedMenu:update(dt)          self.menu:update(dt)    end
function AdvancedMenu:draw()              self.menu:draw()        end
function AdvancedMenu:mousemoved(x, y)    self.menu:hover(x, y)   end
function AdvancedMenu:mousepressed(x, y)  self.menu:press(x, y)   end
function AdvancedMenu:mousereleased(x, y) self.menu:release(x, y) end

return AdvancedMenu
