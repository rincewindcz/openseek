-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local MissionMenu = require "engine.ui.mission_menu"
local EquipScreen = require "engine.ui.equip_screen"
local Campaign    = require "engine.game.campaign"
local Savegame    = require "engine.game.savegame"
local Loadout     = require "engine.game.loadout"
local World       = require "engine.game.world"
local MapFile     = require "engine.game.map_file"
local Document    = require "engine.editor.document"
local Cards       = require "engine.editor.cards"
local Sound       = require "engine.game.sound"

-- Pre-mission briefing scene wrapping the MISSION/PHASE menu (the menu itself
-- is the briefing). PLAY opens the vehicle equip screen (or drops straight
-- into the game when the equip art is not exported); SHOP opens the weapon
-- shop; SAVE / LOAD open the slot screen (engine/scenes/saves.lua), which is
-- also where a loaded run comes back to; EXIT backs out to the main menu.
-- Opening it in a campaign run rewrites the autosave the menu's RESUME reopens.
local MissionBriefing = Class(Scene)

MissionBriefing.ui_pointer = true

function MissionBriefing:init(app)
    Scene.init(self, app)
    self.menu = MissionMenu:new()
    self.menu.on_select = function(id) self:_select(id) end
end

function MissionBriefing:enter(stage_name)
    local world = self.app.world
    stage_name  = stage_name or world.stage_name or world.stages[1]
    -- A player-made map briefs with its own text over its art set's backdrop.
    local own = world.stage_name == stage_name and world.stage.mission
    self.own  = own and { mission = world:mission(), name = own.name, author = own.author, paragraphs = own.briefing,
                          cards = self:_cards(stage_name), disabled = MissionBriefing.closed(own) }
                or nil
    self.menu:open(stage_name, self.own)
    if self.app.campaign then Savegame.autosave(self.app) end
    Sound.play_music("menu")   -- back after a phase, as the original restarts it
end

-- The pictures a map sets beside its paragraphs, drawn from the map itself.
function MissionBriefing:_cards(stage_name)
    local map = MapFile.read(World.map_name(stage_name) or "")
    if not map or not next(map.briefing_cards) then return nil end
    return Cards.for_map(Document:new(map))
end

-- A map closes the shop by saying so, or by fixing the loadout: there is
-- nothing to buy for it.
function MissionBriefing.shop_closed(own)
    return own.loadout ~= nil or (type(own.equip) == "table" and own.equip.no_shop == true)
end

-- The buttons the briefing of a map (own is its stage.mission) shows closed:
-- a map played on its own is no run, so there is nothing to save or load.
function MissionBriefing.closed(own)
    return { save = true, load = true, shop = MissionBriefing.shop_closed(own) }
end

function MissionBriefing:leave()
    self.menu:close()
end

function MissionBriefing:_select(id)
    if id == "play" then
        -- Launching a real mission (new game / mission select both funnel here)
        -- turns on the lives + game-over flow; the developer toggle (O on the main menu) can still
        -- disable it. The sandbox is left deathless.
        self.app.settings.death_enabled = true
        -- A map that fixes the loadout goes straight into the phase with it.
        local own = self.app.world.stage.mission
        if own and own.loadout then
            local settings = self.app.settings
            local weapons  = self.app.combat.weapons
            if Campaign.coop(self.app) then
                for i = 1, Campaign.PLAYERS do
                    settings.coop.vehicle[i], settings.coop.loadout[i] = Loadout.fixed(own.loadout, weapons)
                end
                self.app.scenes:switch("coop_gameplay")
                return
            end
            settings.vehicle, settings.loadout = Loadout.fixed(own.loadout, weapons)
            self.app.scenes:switch("gameplay")
            return
        end
        -- A co-op run always goes through the equip scene: it builds each
        -- player's loadout, launching straight through when the art is missing.
        if EquipScreen.available() or Campaign.coop(self.app) then
            self.app.scenes:switch("equip", self.app.world.stage_name)
        else
            self.app.scenes:switch("gameplay")
        end
    elseif id == "shop" then
        -- The button is closed on such a map; this is for whatever reaches here all the same.
        local own = self.app.world.stage.mission
        if own and MissionBriefing.shop_closed(own) then
            self.menu:open(self.app.world.stage_name, self.own)
            return
        end
        self.app.scenes:switch("shop", self.app.world.stage_name)
    elseif id == "save" or id == "load" then
        -- The briefing is the one point where a run is between phases, so it is
        -- what a slot stores and what a loaded slot reopens. A map played on its
        -- own is no run: there is nothing to store, and its buttons are closed.
        if self.app.play_return then
            self.menu:open(self.app.world.stage_name, self.own)
            return
        end
        self.app.scenes:switch("saves", { mode = id, return_to = "mission_briefing",
            stage = self.app.world.stage_name })
    elseif id == "exit" then
        local back = self.app.play_return
        self.app.play_return = nil
        self.app.scenes:switch(back and back.scene or "main_menu")
    end
end

function MissionBriefing:update(dt)          self.menu:update(dt)     end
function MissionBriefing:draw()              self.menu:draw()         end
function MissionBriefing:keypressed(key)     self.menu:keypressed(key) end
function MissionBriefing:mousemoved(x, y)    self.menu:hover(x, y)    end
function MissionBriefing:mousepressed(x, y)  self.menu:press(x, y)    end
function MissionBriefing:mousereleased(x, y) self.menu:release(x, y)  end

return MissionBriefing
