-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class    = require "engine.core.class"
local Scene    = require "engine.core.scene"
local Menu     = require "engine.ui.menu"
local Savegame = require "engine.game.savegame"
local Campaign = require "engine.game.campaign"
local Sound    = require "engine.game.sound"
local CrashFX  = require "engine.ui.crash_fx"
local Vehicles = require "engine.game.vehicles"
local Config   = require "engine.core.config"
local Log      = require "engine.core.log"

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
    if not self.over_game then
        Sound.play_music("menu")
        self.app.play_return = nil   -- no phase is running: nothing to come back from
    end
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
    if self.app.dev and not self.over_game and self:_dev_key(key) then return end
    self.menu:keypressed(key)   -- confirmed entries dispatch via menu.on_select
end

-- The launch keys of a developer run (--dev), on the fresh menu: the loaded
-- stage flown freely, the sandbox, free co-op, the replay panel, the galleries
-- and the ending, each coming back to the menu; V and O set the vehicle and the
-- optional game over of those flights (logged). Returns true for a key taken.
function MainMenu:_dev_key(key)
    local app = self.app
    if key == "f1" then
        -- A single stage outside a run: no equip loadout, the full weapon list.
        app.campaign         = false
        app.settings.loadout = nil
        app.play_return      = nil
        app.screen:show(string.format("STAGE0%d_MPIC", app.world:mission()),
            { fade_in = 0.3, hold = 0.75, fade_out = 0.3, on_done = function() app.scenes:switch("gameplay") end })
    elseif key == "f3" then
        app.settings.loadout = nil
        app.scenes:switch("sandbox")
    elseif key == "f4" then
        app.scenes:switch("replays")
    elseif key == "f7" then
        app.scenes:switch("vehicle_select", { players = 2, free = true, return_to = "main_menu" })
    elseif key == "f8" then
        app.scenes:switch("anim_gallery")
    elseif key == "f9" then
        app.scenes:switch("font_gallery")
    elseif key == "f10" then
        app.scenes:switch("sound_gallery")
    elseif key == "f11" then
        -- Shift plays VIC3's alternate ending. Outside a run the stats show the
        -- preview record of data/ending.json.
        app.scenes:switch("ending", { alternate = love.keyboard.isDown("lshift", "rshift"),
            record = app.run_record, preview = true, on_done = function() app.scenes:switch("main_menu") end })
    elseif key == "delete" then
        -- The game-over picture of the vehicle; Shift shows the one before a respawn.
        CrashFX.preview(app.screen, app.settings.vehicle, not love.keyboard.isDown("lshift", "rshift"))
    elseif key == "v" then
        -- The vehicle (and variant) the free flights use.
        local settings = app.settings
        local skin     = settings.vehicle == "tank" and Config.tank_skin or Config.chopper_skin
        settings.vehicle, skin = Vehicles.cycle(settings.vehicle, skin)
        if settings.vehicle == "tank" then Config.tank_skin = skin else Config.chopper_skin = skin end
        Log.info("dev", "vehicle: %s", Vehicles.label(settings.vehicle, skin))
    elseif key == "o" then
        app.settings.death_enabled = not app.settings.death_enabled
        Log.info("dev", "game over: %s", app.settings.death_enabled and "on" or "off")
    else
        return false
    end
    return true
end

function MainMenu:update(dt)         self.menu:update(dt)  end
function MainMenu:draw()             self.menu:draw()      end
function MainMenu:mousemoved(x, y)   self.menu:hover(x, y) end
function MainMenu:mousepressed(x, y) self.menu:press(x, y) end
function MainMenu:mousereleased(x, y) self.menu:release(x, y) end

return MainMenu
