local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local MissionMenu = require "engine.ui.mission_menu"

-- Pre-mission briefing scene wrapping the MISSION/PHASE menu (the menu itself
-- is the briefing). PLAY drops into the game; EXIT backs out to the main
-- menu. SAVE / LOAD / SHOP are stubs for now.
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
        self.app.scenes:switch("gameplay")
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
