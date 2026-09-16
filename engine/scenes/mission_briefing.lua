-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local MissionMenu = require "engine.ui.mission_menu"
local EquipScreen = require "engine.ui.equip_screen"

-- Pre-mission briefing scene wrapping the MISSION/PHASE menu (the menu itself
-- is the briefing). PLAY opens the vehicle equip screen (or drops straight
-- into the game when the equip art is not exported); SHOP opens the weapon
-- shop; SAVE / LOAD open the slot screen (engine/scenes/saves.lua), which is
-- also where a loaded run comes back to; EXIT backs out to the main menu.
local MissionBriefing = Class(Scene)

MissionBriefing.ui_pointer = true

function MissionBriefing:init(app)
    Scene.init(self, app)
    self.menu = MissionMenu:new()
    self.menu.on_select = function(id) self:_select(id) end
end

function MissionBriefing:enter(stage_name)
    local world = self.app.world
    self.menu:open(stage_name or world.stage_name or world.stages[1])
end

function MissionBriefing:leave()
    self.menu:close()
end

function MissionBriefing:_select(id)
    if id == "play" then
        -- Launching a real mission (new game / mission select both funnel here)
        -- turns on the lives + game-over flow; the overview toggle can still
        -- disable it. The sandbox is left deathless.
        self.app.settings.death_enabled = true
        if EquipScreen.available() then
            self.app.scenes:switch("equip", self.app.world.stage_name)
        else
            self.app.scenes:switch("gameplay")
        end
    elseif id == "shop" then
        self.app.scenes:switch("shop", self.app.world.stage_name)
    elseif id == "save" or id == "load" then
        -- The briefing is the one point where a run is between phases, so it is
        -- what a slot stores and what a loaded slot reopens.
        self.app.scenes:switch("saves", { mode = id, return_to = "mission_briefing",
            stage = self.app.world.stage_name })
    elseif id == "exit" then
        self.app.scenes:switch("main_menu")
    end
end

function MissionBriefing:update(dt)          self.menu:update(dt)     end
function MissionBriefing:draw()              self.menu:draw()         end
function MissionBriefing:keypressed(key)     self.menu:keypressed(key) end
function MissionBriefing:mousemoved(x, y)    self.menu:hover(x, y)    end
function MissionBriefing:mousepressed(x, y)  self.menu:press(x, y)    end
function MissionBriefing:mousereleased(x, y) self.menu:release(x, y)  end

return MissionBriefing
