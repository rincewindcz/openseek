-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Loadout    = require "engine.game.loadout"
local ShopScreen = require "engine.ui.shop_screen"
local PlayerTag  = require "engine.ui.player_tag"
local Campaign   = require "engine.game.campaign"
local Layout     = require "engine.ui.layout"

-- Weapon shop scene, opened from the mission briefing's SHOP button. Spends the
-- run's medal purse on weapon levels (engine/ui/shop_screen.lua drives the
-- widgets against the shared Loadout). DONE returns to the briefing; purchases
-- persist into the loadout the equip screen then equips from. A forced-vehicle
-- phase (missions.json "vehicle") locks the shop to that vehicle. A co-op run
-- visits the shop once per player, each spending their own purse.
local Shop = Class(Scene)

Shop.ui_pointer = true

function Shop:init(app)
    Scene.init(self, app)
    self.screen = ShopScreen:new()
    self.screen.on_select = function(id) self:_select(id) end
end

function Shop:enter(stage_name, player)
    local app = self.app
    self.stage_name = stage_name or app.world.stage_name
    self.player     = Campaign.coop(app) and (player or Campaign.next_player(app)) or nil
    self.loadout    = Loadout.active(app, self.player)
    local required  = Campaign.required_vehicle(app, self.stage_name)
    if required then self.loadout.vehicle = required end
    self.screen:open(self.loadout, app.combat.weapons, { lock_vehicle = required ~= nil })
end

function Shop:leave()
    self.screen:close()
end

function Shop:_select(_id)
    local next_player = self.player and Campaign.next_player(self.app, self.player)
    if next_player then
        self.app.scenes:switch("shop", self.stage_name, next_player)
    else
        self.app.scenes:switch("mission_briefing", self.stage_name)
    end
end

function Shop:update(dt)          self.screen:update(dt)      end
function Shop:draw()
    self.screen:draw()
    if self.player then self:_draw_tag() end
end

-- The player tag sits on the grass strip right of the medal purse.
function Shop:_draw_tag()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local scale, ox, oy      = Layout.fit(screen_w, screen_h)
    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)
    local pos = self.screen.layout.player_tag
    PlayerTag.draw(self.player, pos[1], pos[2], self.screen:fade())
    g.pop()
end
function Shop:keypressed(key)     self.screen:keypressed(key) end
function Shop:mousepressed(x, y)  self.screen:press(x, y)     end
function Shop:mousereleased(x, y) self.screen:release(x, y)   end

return Shop
