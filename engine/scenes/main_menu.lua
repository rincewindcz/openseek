-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local Scene   = require "engine.core.scene"
local Menu    = require "engine.ui.menu"
local Loadout = require "engine.game.loadout"
local Score   = require "engine.game.score"
local Sound   = require "engine.game.sound"
local Log     = require "engine.core.log"

-- Main menu scene. Switched to after the title card, or pushed over a running
-- gameplay scene (Esc in game), in which case RESUME pops back to the game.
local MainMenu = Class(Scene)

MainMenu.ui_pointer = true

function MainMenu:init(app)
    Scene.init(self, app)
    self.menu = Menu:new()
    self.menu.on_select = function(id) self:_select(id) end
end

function MainMenu:enter()
    -- Pushed over a game = RESUME available; switched to = a fresh menu.
    self.over_game = self.app.scenes:depth() > 1
    if not self.over_game then Sound.play_music("menu") end
    self:_open()
end

function MainMenu:leave()
    self.menu:close()
end

function MainMenu:_open()
    self.menu:set_enabled("resume", self.over_game)
    self.menu:open()
end

-- Runs a confirmed menu entry, fired by the menu once its confirm flash/fade
-- has played (see engine/ui/menu.lua). The info screens hold the menu black
-- behind them and fade it back in when dismissed.
function MainMenu:_select(id)
    local app = self.app
    if id == "new_game" then
        -- Start a fresh campaign run at the first stage: play through every phase
        -- and mission in order, accumulating one running score across the run.
        local first        = app.world.stages[1]
        Log.info("game", "new campaign from %s", first)
        app.campaign       = true
        app.run_score      = 0
        app.run_lives      = Score.START_LIVES
        app.run_bonus_life = Score.BONUS_LIFE_STEP
        app.loadout        = Loadout:new()   -- fresh weapon inventory for the run
        app.world:load(first)
        app.after_stage_load()
        app.scenes:switch("mission_briefing", first)
        app.screen:show_mission(tonumber(first:match("^stage(%d)")))
    elseif id == "resume" then
        if self.over_game then app.scenes:pop() end
    elseif id == "credits" then
        app.scenes:replace("credits")
    elseif id == "hiscores" then
        app.scenes:replace("hiscores")
    elseif id == "options" then
        app.scenes:replace("advanced_settings")
    elseif id == "mission" then
        app.scenes:replace("mission_select")   -- debug mission/phase picker
    elseif id == "editor" then
        -- Drop into the overview (dev/editor) view. TODO: real level editor.
        app.scenes:switch("overview")
    elseif id == "exit" then
        love.event.quit()
    end
end

function MainMenu:keypressed(key)
    -- Esc backs out to the running game if there is one (same as RESUME);
    -- otherwise it is swallowed so the menu stays up front.
    if key == "escape" then
        if self.over_game then self.app.scenes:pop() end
        return
    end
    -- The F8/F9 dev galleries stay reachable from the fresh menu; they switch
    -- back to the menu when closed.
    if (key == "f8" or key == "f9") and not self.over_game then
        self.app.scenes:switch(key == "f8" and "anim_gallery" or "font_gallery")
        return
    end
    self.menu:keypressed(key)   -- confirmed entries dispatch via menu.on_select
end

function MainMenu:update(dt)         self.menu:update(dt)  end
function MainMenu:draw()             self.menu:draw()      end
function MainMenu:mousemoved(x, y)   self.menu:hover(x, y) end
function MainMenu:mousepressed(x, y) self.menu:press(x, y) end
function MainMenu:mousereleased(x, y) self.menu:release(x, y) end

return MainMenu
