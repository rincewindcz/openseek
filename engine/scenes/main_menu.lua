-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class    = require "engine.core.class"
local Scene    = require "engine.core.scene"
local Menu     = require "engine.ui.menu"
local Savegame = require "engine.game.savegame"
local Campaign = require "engine.game.campaign"
local Sound    = require "engine.game.sound"

-- Main menu scene. Switched to after the title card, or pushed over a running
-- gameplay scene (Esc in game), in which case RESUME pops back to the game.
-- Otherwise RESUME reopens the campaign autosave at its briefing.
local MainMenu = Class(Scene)

-- The web build's FULLSCREEN entry asks the hosting page (tools/web/seek.js) to
-- toggle fullscreen with this stdout line, since the page letterboxes the canvas.
local PAGE_FULLSCREEN = "OSPAGE-FULLSCREEN"

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
    self.menu:set_enabled("resume", self.over_game or Savegame.has_autosave())
    self.menu:set_enabled("load", Savegame.any())
    self.menu:open()
end

-- Runs a confirmed menu entry, fired by the menu once its confirm flash/fade
-- has played (see engine/ui/menu.lua). The info screens hold the menu black
-- behind them and fade it back in when dismissed.
function MainMenu:_select(id)
    local app = self.app
    if id == "new_game" then
        -- Solo or co-op, then the vehicle select screen, which starts the run.
        app.scenes:replace("new_game")
    elseif id == "resume" then
        if self.over_game then
            app.scenes:pop()
        elseif not Campaign.resume(app, Savegame.read_autosave()) then
            Savegame.clear_autosave()   -- unreadable: drop it and disable RESUME
            self:_open()
        end
    elseif id == "credits" then
        app.scenes:replace("credits")
    elseif id == "hiscores" then
        app.scenes:replace("hiscores")
    elseif id == "load" then
        app.scenes:replace("saves", { mode = "load", return_to = "main_menu" })
    elseif id == "options" then
        app.scenes:replace("advanced_settings")
    elseif id == "advanced" then
        app.scenes:replace("advanced_menu")    -- mission picker, replays, editor
    elseif id == "exit" then
        love.event.quit()
    elseif id == "fullscreen" then
        print(PAGE_FULLSCREEN)
        self:_open()
    end
end

function MainMenu:keypressed(key)
    -- Esc backs out to the running game if there is one (same as RESUME);
    -- otherwise it is swallowed so the menu stays up front.
    if key == "escape" then
        if self.over_game then self.app.scenes:pop() end
        return
    end
    -- The F8/F9 dev galleries stay reachable from the fresh menu of a developer
    -- run (--dev); they switch back to the menu when closed.
    if (key == "f8" or key == "f9") and self.app.dev and not self.over_game then
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
