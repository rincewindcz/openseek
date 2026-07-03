local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Font       = require "engine.core.font"
local InfoScreen = require "engine.ui.info_screen"
local json       = require "lib.json"

-- High-score scene: the HISCORE backdrop with the flying-in HIGH SCORES title, a
-- table of the top 10 entries (rank / nickname / score) over a dimming panel for
-- readability, and an EXIT button bottom-right. Reached from the main menu's
-- HIGH SCORES entry via replace(); EXIT returns to the menu the same way.
local HiScores = Class(Scene)

HiScores.ui_pointer = true

local GOLD = { 1, 0.8, 0.2 }

local MAX_ROWS   = 10
local LIST_TOP   = 58     -- first row baseline
local ROW_H      = 15
local RANK_X     = 66
local NAME_X     = 96
local SCORE_RX   = 254    -- score right edge
local PANEL_X    = 52
local PANEL_W    = 216

function HiScores:init(app)
    Scene.init(self, app)
    self.screen = InfoScreen:new("HISCORE", "hiscore_title")
    self.screen.on_exit = function() self.app.scenes:replace("main_menu") end

    self.font    = Font.get("hichars")
    self.entries = self:_load()

    self.screen.on_draw_content = function(g, fade) self:_draw_table(g, fade) end
end

-- Top 10 entries from data/highscores.json ({ name, score } list), trimmed and
-- padded so the table always has exactly MAX_ROWS rows to render.
function HiScores:_load()
    local list = {}
    local raw = love.filesystem.read("data/highscores.json")
    if raw then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then
            for _, e in ipairs(data) do
                list[#list + 1] = { name = tostring(e.name or "---"), score = tonumber(e.score) or 0 }
                if #list >= MAX_ROWS then break end
            end
        end
    end
    while #list < MAX_ROWS do
        list[#list + 1] = { name = "---", score = 0 }
    end
    return list
end

function HiScores:_draw_table(g, fade)
    local panel_h = MAX_ROWS * ROW_H + 8
    g.setColor(0, 0, 0, 0.55 * fade)
    g.rectangle("fill", PANEL_X, LIST_TOP - 6, PANEL_W, panel_h)

    for i, e in ipairs(self.entries) do
        local y     = LIST_TOP + (i - 1) * ROW_H
        local color = { GOLD[1], GOLD[2], GOLD[3], fade }
        self.font:print(string.format("%2d", i), RANK_X, y, { color = color })
        self.font:print(e.name, NAME_X, y, { color = color })
        local score = tostring(e.score)
        self.font:print(score, SCORE_RX - self.font:width(score), y, { color = color })
    end
end

function HiScores:enter()             self.screen:open()          end
function HiScores:leave()             self.screen:close()         end
function HiScores:update(dt)          self.screen:update(dt)      end
function HiScores:draw()              self.screen:draw()          end
function HiScores:keypressed(key)     self.screen:keypressed(key) end
function HiScores:mousemoved(x, y)    self.screen:hover(x, y)     end
function HiScores:mousepressed(x, y)  self.screen:press(x, y)     end
function HiScores:mousereleased(x, y) self.screen:release(x, y)   end

return HiScores
