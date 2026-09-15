-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Font       = require "engine.core.font"
local InfoScreen = require "engine.ui.info_screen"
local Pointer    = require "engine.ui.pointer"
local json       = require "lib.json"
local Log        = require "engine.core.log"

-- High-score scene: the HISCORE backdrop with the flying-in HIGH SCORES title, a
-- table of the top 10 entries (rank / nickname / score) over a dimming panel for
-- readability, and an EXIT button bottom-right. Reached two ways:
--   * from the main menu's HIGH SCORES entry (replace, no argument): view only.
--   * from game over (switch("hiscores", score)): if the final score makes the
--     top 10, a new row opens for the player to type a name (blinking caret),
--     which is saved to the persisted table on Enter.
-- EXIT returns to the menu.
local HiScores = Class(Scene)

HiScores.ui_pointer = true

local GOLD = { 1, 0.8, 0.2 }
local LIVE = { 1, 1, 1 }   -- the row being typed into, brighter than the rest

local MAX_ROWS   = 10
local NAME_MAX   = 8      -- longest nickname the entry field accepts
local LIST_TOP   = 58     -- first row baseline
local ROW_H      = 15
local RANK_X     = 66
local NAME_X     = 96
local SCORE_RX   = 254    -- score right edge
local PANEL_X    = 52
local PANEL_W    = 216

-- Where the persisted table lives. love.filesystem.write targets the save
-- directory (conf identity), which is also searched first on read, so a saved
-- table shadows the shipped default in data/.
local SAVE_PATH  = "data/highscores.json"

function HiScores:init(app)
    Scene.init(self, app)
    self.screen = InfoScreen:new("HISCORE", "hiscore_title")
    self.screen.on_exit = function() self.app.scenes:replace("main_menu") end

    self.font = Font.get("hichars")
    self.screen.on_draw_content = function(g, fade) self:_draw_table(g, fade) end
end

-- Top entries from SAVE_PATH ({ name, score } list), sorted high-to-low and
-- capped at MAX_ROWS. No padding: the real length drives eligibility, the draw
-- pass fills empty ranks with placeholders.
function HiScores:_load()
    local list = {}
    local raw = love.filesystem.getInfo(SAVE_PATH) and love.filesystem.read(SAVE_PATH)
    if raw then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then
            for _, e in ipairs(data) do
                list[#list + 1] = { name = tostring(e.name or "---"), score = tonumber(e.score) or 0 }
            end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    while #list > MAX_ROWS do table.remove(list) end
    return list
end

-- A score qualifies while there is an empty rank or it beats the last entry.
function HiScores:_qualifies(score)
    if #self.entries < MAX_ROWS then return true end
    return score > self.entries[MAX_ROWS].score
end

-- Open an editable row at the score's rank and start capturing keystrokes.
function HiScores:_begin_entry(score)
    local rank = #self.entries + 1
    for i, e in ipairs(self.entries) do
        if score > e.score then rank = i; break end
    end
    table.insert(self.entries, rank, { name = "", score = score, editing = true })
    while #self.entries > MAX_ROWS do table.remove(self.entries) end
    self.entry = { row = rank, text = "" }
end

function HiScores:_commit_entry()
    local row   = self.entries[self.entry.row]
    row.name    = self.entry.text ~= "" and self.entry.text or "PLAYER"
    row.editing = nil
    Log.info("hiscores", "new entry %s, %d points, rank %d", row.name, row.score, self.entry.row)
    self.entry  = nil
    self:_save()
end

function HiScores:_entry_key(key)
    local e = self.entry
    if key == "return" or key == "kpenter" or key == "escape" then
        self:_commit_entry()
    elseif key == "backspace" then
        e.text = e.text:sub(1, -2)
    elseif #e.text < NAME_MAX then
        local ch
        if     key:match("^[a-z]$") then ch = key:upper()
        elseif key:match("^%d$")    then ch = key
        elseif key == "space"       then ch = " "
        end
        if ch then e.text = e.text .. ch end
    end
    if self.entry then self.entries[self.entry.row].name = self.entry.text end
end

-- Serialize the live table back to SAVE_PATH. Names are A-Z/0-9/space only, but
-- quotes and backslashes are escaped defensively. The parent directory is
-- created first: writing into a not-yet-existing save subdirectory otherwise
-- reports success while silently dropping the file.
function HiScores:_save()
    local function esc(s) return (s:gsub('[\\"]', "\\%0")) end
    local parts = {}
    for _, e in ipairs(self.entries) do
        parts[#parts + 1] = string.format('  { "name": "%s", "score": %d }', esc(e.name), e.score)
    end
    local encoded = "[\n" .. table.concat(parts, ",\n") .. "\n]\n"
    local dir = SAVE_PATH:match("^(.*)/[^/]+$")
    if dir then love.filesystem.createDirectory(dir) end
    local ok, err = pcall(love.filesystem.write, SAVE_PATH, encoded)
    if not ok then Log.warn("hiscores", "save failed: %s", tostring(err)) end
end

function HiScores:_draw_table(g, fade)
    local panel_h = MAX_ROWS * ROW_H + 8
    g.setColor(0, 0, 0, 0.55 * fade)
    g.rectangle("fill", PANEL_X, LIST_TOP - 6, PANEL_W, panel_h)

    for i = 1, MAX_ROWS do
        local e   = self.entries[i]
        local y   = LIST_TOP + (i - 1) * ROW_H
        local hue = (e and e.editing) and LIVE or GOLD
        local col = { hue[1], hue[2], hue[3], fade }
        self.font:print(string.format("%2d", i), RANK_X, y, { color = col })
        if not e then
            self.font:print("---", NAME_X, y, { color = col })
        else
            local name = e.name ~= "" and e.name or "---"
            if e.editing then
                -- Blinking underscore caret trailing the typed text.
                local caret = (math.floor((self.caret_t or 0) * 2) % 2 == 0) and "_" or ""
                name = e.name .. caret
            end
            self.font:print(name, NAME_X, y, { color = col })
            local score = tostring(e.score)
            self.font:print(score, SCORE_RX - self.font:width(score), y, { color = col })
        end
    end

    if self.entry then
        local hint = "ENTER YOUR NAME - PRESS ENTER"
        self.font:print(hint, (320 - self.font:width(hint)) / 2, LIST_TOP + panel_h + 4,
            { color = { LIVE[1], LIVE[2], LIVE[3], fade } })
    end
end

function HiScores:enter(new_score)
    self.entries = self:_load()
    self.entry   = nil
    self.caret_t = 0
    if new_score and new_score > 0 and self:_qualifies(new_score) then
        self:_begin_entry(new_score)
    end
    self.screen:open()
end

function HiScores:leave()          self.screen:close()     end
function HiScores:update(dt)
    self.caret_t = (self.caret_t or 0) + dt
    self.screen:update(dt)
end
function HiScores:draw()           self.screen:draw()      end

-- While a name is being typed the keystrokes are captured here and the EXIT
-- button is inert (Enter finishes the entry); otherwise input drives the screen.
function HiScores:keypressed(key)
    if self.entry then self:_entry_key(key) else self.screen:keypressed(key) end
end
function HiScores:mousemoved(x, y)    if not self.entry then self.screen:hover(x, y)   end end
function HiScores:mousepressed(x, y)  if not self.entry then self.screen:press(x, y)   end end
-- There is no keyboard on a touch device, so a tap commits the name as typed.
function HiScores:mousereleased(x, y)
    if not self.entry then
        self.screen:release(x, y)
    elseif Pointer.touch then
        self:_commit_entry()
    end
end

return HiScores
