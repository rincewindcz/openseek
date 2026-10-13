-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local Scene = require "engine.core.scene"
local Menu  = require "engine.ui.menu"

-- ADVANCED submenu: the entries that are not part of a normal run (the mission
-- / phase picker, the player-made maps with their editor, the replay browser),
-- kept off the main menu so it stays short. Same Menu widget and backdrop as
-- the main menu; BACK returns to it. Not to be confused with
-- advanced_settings, which is the OPTIONS page. The map editor is a mouse and
-- keyboard tool, so the web and phone builds leave EDITOR out.
local AdvancedMenu = Class(Scene)

AdvancedMenu.ui_pointer = true

local DESKTOP = { Linux = true, Windows = true, ["OS X"] = true }

local ENTRIES = {
    { id = "mission", label = "MISSION" },
    { id = "maps",    label = "EDITOR" },
    { id = "replays", label = "REPLAYS", gap_after = 8 },
    { id = "back",    label = "BACK" },
}

function AdvancedMenu:init(app)
    Scene.init(self, app)
    local entries = {}
    for _, entry in ipairs(ENTRIES) do
        if entry.id ~= "maps" or (DESKTOP[love.system.getOS()] and not app.touch_emulation) then
            entries[#entries + 1] = entry
        end
    end
    self.menu = Menu:new(entries)
    self.menu.on_select = function(id) self:_select(id) end
end

function AdvancedMenu:enter()  self.menu:open()  end
function AdvancedMenu:leave()  self.menu:close() end

function AdvancedMenu:_select(id)
    local app = self.app
    if id == "mission" then
        app.scenes:replace("mission_select")
    elseif id == "maps" then
        app.scenes:switch("map_select", { return_to = "advanced_menu" })
    elseif id == "replays" then
        app.scenes:replace("replay_select", { return_to = "advanced_menu" })
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
