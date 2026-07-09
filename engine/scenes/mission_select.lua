local Class         = require "engine.core.class"
local Scene         = require "engine.core.scene"
local MissionSelect = require "engine.ui.mission_select"
local Loadout       = require "engine.game.loadout"

-- Debug mission/phase picker scene. PLAY loads the chosen stage and opens its
-- briefing; EXIT backs out to the main menu. Entered via replace() so a game
-- suspended under the menu stays suspended while the picker is up.
local MissionSelectScene = Class(Scene)

MissionSelectScene.ui_pointer = true

function MissionSelectScene:init(app)
    Scene.init(self, app)
    self.picker = MissionSelect:new()
    self.picker.on_select = function(id, stage_name) self:_select(id, stage_name) end
end

function MissionSelectScene:enter()
    self.picker:open()
end

function MissionSelectScene:leave()
    self.picker:close()
end

function MissionSelectScene:_select(id, stage_name)
    local app = self.app
    if id == "play" then
        app.campaign     = false   -- picked a single stage: play it, then back to menu
        app.loadout_free = nil     -- fresh MISSION-mode inventory, re-seeded with START_MEDALS
        Loadout.active(app)
        app.world:load(stage_name)
        app.after_stage_load()
        app.scenes:switch("mission_briefing", stage_name)
    elseif id == "exit" then
        app.scenes:replace("main_menu")
    end
end

function MissionSelectScene:update(dt)          self.picker:update(dt)      end
function MissionSelectScene:draw()              self.picker:draw()          end
function MissionSelectScene:keypressed(key)     self.picker:keypressed(key) end
function MissionSelectScene:mousemoved(x, y)    self.picker:hover(x, y)     end
function MissionSelectScene:mousepressed(x, y)  self.picker:press(x, y)     end
function MissionSelectScene:mousereleased(x, y) self.picker:release(x, y)   end

return MissionSelectScene
