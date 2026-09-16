-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class    = require "engine.core.class"
local Scene    = require "engine.core.scene"
local Font     = require "engine.core.font"
local Layout   = require "engine.ui.layout"
local Pointer  = require "engine.ui.pointer"
local Audio    = require "engine.core.audio"
local Savegame = require "engine.game.savegame"
local Log      = require "engine.core.log"

-- SAVE / LOAD screen: an options-style panel of named slots over the pulsating
-- main-menu backdrop, tinted green so it reads as a sibling of the OPTIONS page
-- rather than the same screen (the original's own SAVEPIC art bakes eight fixed
-- slot boxes, which this list cannot use). The list is unlimited and scrolls,
-- every slot showing the name the player typed and the phase the run is parked
-- on, with the highlighted slot's score, medals and spare vehicles under the
-- list. Reached from the mission briefing's SAVE and LOAD buttons and from the
-- main menu's LOAD entry.
--
-- enter() takes { mode = "save" | "load", return_to = <scene name>,
-- stage = <stage name for the briefing> }. Saving writes the run state captured
-- by engine/game/savegame.lua and returns to the caller; loading restores it,
-- loads its stage and opens that phase's briefing.
local Saves = Class(Scene)

Saves.ui_pointer = true

local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

local PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 12, 22, 296, 194
local PANEL_ALPHA = 0.65
local BG_TINT     = { 0.30, 0.72, 0.38 }   -- green wash over the greyscale MAINP
local TITLE_Y     = 32
local ROW_Y0      = 50
local ROW_DY      = 16
local ROW_H       = 12
local MAX_ROWS    = 8
local NAME_X      = 32
local PHASE_RX    = 290    -- right edge of the row's phase column
local HIT_X0      = 22     -- row hit-test left / right
local HIT_X1      = 300
local DETAIL_Y    = 178    -- run summary for the highlighted slot
local INFO_Y      = 194    -- its timestamp, beside the EXIT widget
local EXIT_RX     = 296
local ARROW_GAP   = 8
local FOOTER_Y    = 222
local FADE_IN     = 0.25
local NAME_MAX    = 18

local GOLD = { 1, 0.8, 0.2 }

function Saves:init(app)
    Scene.init(self, app)
    self.name_font = Font.get("savechar")
    self.font      = Font.get("chars")
    self.hint_font = Font.get("keysfont")

    local ok, bg = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then bg:setFilter("linear", "linear"); self.bg = bg end
    local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
    if aok then arrow:setFilter("nearest", "nearest"); self.arrow = arrow end
end

function Saves:enter(opts)
    opts = opts or {}
    self.mode      = opts.mode == "save" and "save" or "load"
    self.return_to = opts.return_to or "main_menu"
    self.stage     = opts.stage
    self.t         = 0
    self.caret_t   = 0
    self.cursor    = 1
    self.scroll    = 0
    self.entry     = nil   -- { text, path } while a slot name is being typed
    self.pending_delete = nil
    self:_refresh()
end

-- Rows are the slot list, newest first, with a leading NEW SAVE row in save
-- mode. The EXIT widget is the cursor position one past the last row.
function Saves:_refresh()
    self.rows = {}
    if self.mode == "save" then
        self.rows[1] = { kind = "new" }
    end
    for _, slot in ipairs(Savegame.list()) do
        self.rows[#self.rows + 1] = { kind = "slot", path = slot.path, data = slot.data }
    end
    self.cursor = math.min(self.cursor, #self.rows + 1)
    self:_scroll_to(self.cursor)
end

function Saves:_exit_index() return #self.rows + 1 end

function Saves:_scroll_to(i)
    local n = #self.rows
    if n <= MAX_ROWS or i > n then return end
    self.scroll = math.max(math.min(self.scroll, i - 1), i - MAX_ROWS)
    self.scroll = math.max(0, math.min(self.scroll, n - MAX_ROWS))
end

function Saves:_move(dir)
    local n = self:_exit_index()
    self.cursor = ((self.cursor - 1 + dir) % n) + 1
    self.pending_delete = nil
    self:_scroll_to(self.cursor)
    Audio.play_event("ui.move")
end

function Saves:_back()
    Audio.play_event("ui.back")
    self.app.scenes:switch(self.return_to, self.stage)
end

-- A default slot name for a new save: the phase the run is parked on, dated.
function Saves:_default_name()
    return Savegame.stage_short(self.stage or self.app.world.stage_name)
        .. os.date(" %m-%d")
end

function Saves:_begin_entry(row)
    self.entry = {
        text = (row.kind == "slot") and tostring(row.data.name or "") or self:_default_name(),
        path = (row.kind == "slot") and row.path or nil,
    }
    self.caret_t = 0
    Audio.play_event("ui.confirm")
end

function Saves:_commit_entry()
    local entry = self.entry
    self.entry  = nil
    local name  = entry.text ~= "" and entry.text or "SAVED GAME"
    local data  = Savegame.capture(self.app, name)
    if Savegame.write(data, entry.path) then
        self.app.scenes:switch(self.return_to, self.stage)
    else
        self:_refresh()
    end
end

function Saves:_load_slot(row)
    local app = self.app
    if not Savegame.apply(app, row.data) then return end
    local stage = row.data.stage
    Log.info("game", "loaded %s at %s, score %d", row.data.name or "?", stage, app.run_score)
    Audio.play_event("ui.confirm")
    app.world:load(stage)
    app.after_stage_load()
    app.scenes:switch("mission_briefing", stage)
    app.screen:show_mission(tonumber(stage:match("^stage(%d)")))
end

function Saves:_activate(i)
    if i == self:_exit_index() then self:_back(); return end
    local row = self.rows[i]
    if not row then return end
    self.pending_delete = nil
    if self.mode == "save" then
        self:_begin_entry(row)
    elseif row.kind == "slot" then
        self:_load_slot(row)
    end
end

-- Delete needs a second press on the same slot; the footer says so meanwhile.
function Saves:_delete(i)
    local row = self.rows[i]
    if not row or row.kind ~= "slot" then return end
    if self.pending_delete ~= row.path then
        self.pending_delete = row.path
        return
    end
    self.pending_delete = nil
    Savegame.delete(row.path)
    Audio.play_event("ui.back")
    self:_refresh()
    self.cursor = math.min(self.cursor, self:_exit_index())
end

function Saves:captures_keys()
    return self.entry ~= nil
end

function Saves:_entry_key(key)
    local entry = self.entry
    if key == "return" or key == "kpenter" then
        self:_commit_entry()
    elseif key == "escape" then
        self.entry = nil
        Audio.play_event("ui.back")
    elseif key == "backspace" then
        entry.text = entry.text:sub(1, -2)
    elseif #entry.text < NAME_MAX then
        local ch
        if     key:match("^[a-z]$") then ch = key:upper()
        elseif key:match("^%d$")    then ch = key
        elseif key == "space"       then ch = " "
        elseif key == "-"           then ch = "-"
        end
        if ch then entry.text = entry.text .. ch end
    end
end

function Saves:keypressed(key)
    if self.entry then self:_entry_key(key); return end
    if     key == "up"     then self:_move(-1)
    elseif key == "down"   then self:_move(1)
    elseif key == "return" or key == "space" or key == "kpenter" then self:_activate(self.cursor)
    elseif key == "delete" or key == "backspace" then self:_delete(self.cursor)
    elseif key == "escape" then self:_back()
    end
end

function Saves:wheelmoved(_dx, dy)
    local n = #self.rows
    if self.entry or n <= MAX_ROWS then return end
    self.scroll = math.max(0, math.min(self.scroll - dy, n - MAX_ROWS))
end

-- Row index under a window-space point, the EXIT index over the EXIT label,
-- or nil.
function Saves:_index_at(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dy >= INFO_Y - 3 and dy <= INFO_Y + ROW_H
        and dx >= EXIT_RX - self.font:width("EXIT") - 4 and dx <= EXIT_RX + 4 then
        return self:_exit_index()
    end
    if dx < HIT_X0 or dx > HIT_X1 then return nil end
    for i = 1, math.min(MAX_ROWS, #self.rows - self.scroll) do
        local ry = ROW_Y0 + (i - 1) * ROW_DY
        if dy >= ry - 3 and dy <= ry + ROW_H then return i + self.scroll end
    end
    return nil
end

function Saves:mousemoved(x, y)
    if self.entry then return end
    local i = self:_index_at(x, y)
    if i and i ~= self.cursor then self.cursor = i; self.pending_delete = nil end
end

function Saves:mousepressed(x, y)
    -- There is no keyboard on a touch device, so a tap commits the typed name.
    if self.entry then
        if Pointer.touch then self:_commit_entry() end
        return
    end
    local i = self:_index_at(x, y)
    if not i then return end
    self.cursor = i
    self:_activate(i)
end

function Saves:update(dt)
    self.t       = self.t + dt
    self.caret_t = self.caret_t + dt
end

-- The blinking selection arrow to the left of a row at (x, y).
function Saves:_draw_arrow(x, y, fade)
    if not self.arrow then return end
    local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
    local phase  = 0.5 + 0.5 * math.sin(self.t * 2.2)
    love.graphics.setColor(1, 1, 1, fade)
    love.graphics.draw(self.arrow, x - ARROW_GAP - aw / 2 + 3 * phase, y + ROW_H / 2,
        0, 1, 1, aw / 2, ah / 2)
end

-- Triangles marking rows scrolled out of view above / below the list.
function Saves:_draw_scroll_marks(fade)
    local n = #self.rows
    if n <= MAX_ROWS then return end
    local g  = love.graphics
    local cx = (NAME_X + PHASE_RX) / 2
    g.setColor(1, 1, 1, 0.5 * fade)
    if self.scroll > 0 then
        g.polygon("fill", cx - 4, ROW_Y0 - 5, cx + 4, ROW_Y0 - 5, cx, ROW_Y0 - 10)
    end
    if self.scroll + MAX_ROWS < n then
        local by = ROW_Y0 + MAX_ROWS * ROW_DY - 6
        g.polygon("fill", cx - 4, by, cx + 4, by, cx, by + 5)
    end
    g.setColor(1, 1, 1, 1)
end

function Saves:_draw_row(i, y, fade)
    local row   = self.rows[i]
    local sel   = (i == self.cursor)
    local alpha = (sel and 1 or 0.65) * fade
    local hue   = sel and GOLD or { 1, 1, 1 }
    local col   = { hue[1], hue[2], hue[3], alpha }

    local editing = self.entry and sel
    local name
    if editing then
        local caret = (math.floor(self.caret_t * 2) % 2 == 0) and "_" or ""
        name = self.entry.text .. caret
    elseif row.kind == "new" then
        name = "NEW SAVE"
    else
        name = tostring(row.data.name or "")
        if name == "" then name = "---" end
    end
    self.name_font:print(name, NAME_X, y, { color = col })

    if row.kind == "slot" then
        local phase = Savegame.stage_short(row.data.stage)
        self.font:print(phase, PHASE_RX - self.font:width(phase), y + 2, { color = col })
    end
    if sel and not self.entry then self:_draw_arrow(NAME_X, y, fade) end
end

-- What the highlighted slot holds, under the list: the run summary and, on the
-- EXIT line, when it was written.
function Saves:_draw_detail(fade)
    local row  = self.rows[self.cursor]
    local slot = (row and row.kind == "slot") and row.data or nil
    local col  = { 1, 1, 1, 0.55 * fade }
    local text
    if self.entry then
        text = "TYPE A NAME FOR THIS SLOT"
    elseif slot then
        text = string.format("SCORE %d   MEDALS %d   SPARE %d",
            math.floor(tonumber(slot.score) or 0),
            math.floor(tonumber((slot.loadout or {}).medals) or 0),
            math.floor(tonumber(slot.lives) or 0))
    elseif row then
        text = "STORE THE RUN IN A NEW SLOT"
    elseif #self.rows == 0 then
        text = "NO SAVED GAMES YET"
    else
        text = ""
    end
    self.font:print(text, NAME_X, DETAIL_Y, { color = col })
    if slot and not self.entry then
        self.font:print("SAVED " .. tostring(slot.saved_at or "?"), NAME_X, INFO_Y, { color = col })
    end
end

function Saves:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade               = math.min(1, self.t / FADE_IN)

    -- Backdrop with the main menu's breathing zoom, through the green tint.
    if self.bg then
        local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
        local bw, bh  = screen_w * breathe, screen_h * breathe
        g.setColor(BG_TINT[1] * fade, BG_TINT[2] * fade, BG_TINT[3] * fade, 1)
        g.draw(self.bg, (screen_w - bw) / 2, (screen_h - bh) / 2, 0,
            bw / self.bg:getWidth(), bh / self.bg:getHeight())
    else
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", 0, 0, screen_w, screen_h)
    end

    local scale, ox, oy = Layout.fit(screen_w, screen_h)
    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    g.setColor(0, 0, 0, PANEL_ALPHA * fade)
    g.rectangle("fill", PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 4)

    local title = (self.mode == "save") and "SAVE GAME" or "LOAD GAME"
    self.font:print(title, (DESIGN_W - self.font:width(title)) / 2, TITLE_Y,
        { color = { GOLD[1], GOLD[2], GOLD[3], fade } })

    for i = 1 + self.scroll, math.min(#self.rows, self.scroll + MAX_ROWS) do
        self:_draw_row(i, ROW_Y0 + (i - 1 - self.scroll) * ROW_DY, fade)
    end
    self:_draw_scroll_marks(fade)
    self:_draw_detail(fade)

    local exit_sel = (self.cursor == self:_exit_index()) and not self.entry
    local col = exit_sel and { GOLD[1], GOLD[2], GOLD[3], fade } or { 1, 1, 1, 0.65 * fade }
    local exit_x = EXIT_RX - self.font:width("EXIT")
    self.font:print("EXIT", exit_x, INFO_Y, { color = col })
    if exit_sel then self:_draw_arrow(exit_x, INFO_Y - 2, fade) end

    local hint
    if self.entry then
        hint = "TYPE A NAME   ENTER SAVES   ESC CANCELS"
    elseif self.pending_delete then
        hint = "PRESS DEL AGAIN TO ERASE THIS SLOT"
    elseif self.mode == "save" then
        hint = "UP/DOWN SELECT   ENTER SAVE   DEL ERASE   ESC BACK"
    else
        hint = "UP/DOWN SELECT   ENTER LOAD   DEL ERASE   ESC BACK"
    end
    self.hint_font:print(hint, (DESIGN_W - self.hint_font:width(hint)) / 2, FOOTER_Y,
        { color = { 1, 1, 1, 0.6 * fade } })

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return Saves
