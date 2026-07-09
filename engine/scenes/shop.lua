local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Loadout    = require "engine.game.loadout"
local Mission    = require "engine.game.mission"
local ShopScreen = require "engine.ui.shop_screen"

-- Weapon shop scene, opened from the mission briefing's SHOP button. Spends the
-- run's medal purse on weapon levels (engine/ui/shop_screen.lua drives the
-- widgets against the shared Loadout). DONE returns to the briefing; purchases
-- persist into the loadout the equip screen then equips from. A forced-vehicle
-- phase (missions.json "vehicle") locks the shop to that vehicle.
local Shop = Class(Scene)

Shop.ui_pointer = true

function Shop:init(app)
    Scene.init(self, app)
    self.screen = ShopScreen:new()
    self.screen.on_select = function(id) self:_select(id) end
end

function Shop:enter(stage_name)
    local app = self.app
    self.stage_name = stage_name or app.world.stage_name
    self.loadout    = Loadout.active(app)
    local required  = Mission.required_vehicle(self.stage_name)
    if required then self.loadout.vehicle = required end
    self.screen:open(self.loadout, app.combat.weapons, { lock_vehicle = required ~= nil })
end

function Shop:leave()
    self.screen:close()
end

function Shop:_select(_id)
    self.app.scenes:switch("mission_briefing", self.stage_name)
end

function Shop:update(dt)          self.screen:update(dt)      end
function Shop:draw()              self.screen:draw()          end
function Shop:keypressed(key)     self.screen:keypressed(key) end
function Shop:mousemoved(x, y)    self.screen:hover(x, y)     end
function Shop:mousepressed(x, y)  self.screen:press(x, y)     end
function Shop:mousereleased(x, y) self.screen:release(x, y)   end

return Shop
