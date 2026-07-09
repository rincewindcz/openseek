local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local Loadout     = require "engine.game.loadout"
local Mission     = require "engine.game.mission"
local EquipScreen = require "engine.ui.equip_screen"

-- Vehicle select and equip scene, between the mission briefing's PLAY and the
-- live game: pick the vehicle (TANK / CHOP button) and load its weapon bays
-- (engine/ui/equip_screen.lua drives the widgets against app.loadout). OK
-- starts the phase with the picked vehicle and loadout; EXIT returns to the
-- briefing. Weapons are bought on the shop screen and equipped here. Stages
-- with a forced vehicle (missions.json "vehicle") lock the screen to it.
-- Without exported equip art the briefing skips this scene.
local Equip = Class(Scene)

Equip.ui_pointer = true

function Equip:init(app)
    Scene.init(self, app)
    self.screen = EquipScreen:new()
    self.screen.on_select = function(id) self:_select(id) end
end

function Equip:enter(stage_name)
    local app = self.app
    self.stage_name = stage_name or app.world.stage_name
    -- A campaign run equips its own inventory, grown by the shop from medal
    -- pickups; a single mission (MISSION mode) equips the START_MEDALS-seeded
    -- inventory bought in the shop. Both share the run's Loadout.
    self.loadout = Loadout.active(app)
    local required = Mission.required_vehicle(self.stage_name)
    if required then self.loadout.vehicle = required end
    if not self.screen:open(self.loadout, app.combat.weapons,
        { lock_vehicle = required ~= nil }) then
        self:_select("ok")   -- equip art not exported: launch directly
    end
end

function Equip:leave()
    self.screen:close()
end

-- OK: apply the picked vehicle and the built weapon list (unique bay weapons
-- in bay order, ammo multiplied by bay count, plus the special) and drop into
-- the game. The snapshot lives on settings so respawns re-seed from it; the
-- free-play launchers clear it.
function Equip:_select(id)
    local app = self.app
    if id == "ok" then
        local loadout = self.loadout
        local list, counts, levels = loadout:weapon_list(loadout.vehicle)
        app.settings.vehicle = loadout.vehicle
        app.settings.loadout = { list = list, counts = counts, levels = levels,
            chars = { fuel = loadout:char(loadout.vehicle, "fuel"),
                      armor = loadout:char(loadout.vehicle, "armor") } }
        app.scenes:switch("gameplay")
    else
        app.scenes:switch("mission_briefing", self.stage_name)
    end
end

function Equip:update(dt)          self.screen:update(dt)      end
function Equip:draw()              self.screen:draw()          end
function Equip:keypressed(key)     self.screen:keypressed(key) end
function Equip:mousemoved(x, y)    self.screen:hover(x, y)     end
function Equip:mousepressed(x, y)  self.screen:press(x, y)     end
function Equip:mousereleased(x, y) self.screen:release(x, y)   end

return Equip
