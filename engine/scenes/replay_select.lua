-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local Scene   = require "engine.core.scene"
local Font    = require "engine.core.font"
local Layout  = require "engine.ui.layout"
local Hint    = require "engine.ui.hint"
local Pointer = require "engine.ui.pointer"
local Audio   = require "engine.core.audio"
local Replay  = require "engine.game.replay"
local Log     = require "engine.core.log"

-- REPLAY screen: the player-facing recording browser, built like the SAVE /
-- LOAD panel (engine/scenes/saves.lua) but tinted blue, with the stage each
-- recording was made on in the row and its mode / players / running time under
-- the list. Left / right flip the list between newest and oldest first.
-- Reached from the ADVANCED submenu. The raw dev browser on F4 in the overview
-- (engine/scenes/replays.lua) stays as it is: that one also verifies.
--
-- enter() takes { return_to = <scene name> }; playback returns to this screen
-- through app.replay_return (see GameplayBase:finish_playback).
local ReplaySelect = Class(Scene)

ReplaySelect.ui_pointer = true

local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

local PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 12, 22, 296, 194
local PANEL_ALPHA = 0.65
local BG_TINT     = { 0.34, 0.52, 0.86 }   -- blue wash over the greyscale MAINP
local TITLE_Y     = 32
local ROW_Y0      = 50
local ROW_DY      = 16
local ROW_H       = 12
local MAX_ROWS    = 8
local NAME_X      = 32
local STAGE_RX    = 290    -- right edge of the row's stage column
local HIT_X0      = 22
local HIT_X1      = 300
local DETAIL_Y    = 178
local INFO_Y      = 194
local EXIT_RX     = 296
local ARROW_GAP   = 8
local FOOTER_Y    = 222
local FADE_IN     = 0.25

local TICKS_PER_SECOND = 60

local GOLD = { 1, 0.8, 0.2 }

function ReplaySelect:init(app)
    Scene.init(self, app)
    self.name_font = Font.get("savechar")
    self.font      = Font.get("chars")
    self.hint_font = Font.get("keysfont")

    self.newest_first = true   -- kept across visits, not persisted

    local ok, bg = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then bg:setFilter("linear", "linear"); self.bg = bg end
    local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
    if aok then arrow:setFilter("nearest", "nearest"); self.arrow = arrow end
end

function ReplaySelect:enter(opts)
    opts = opts or {}
    self.return_to = opts.return_to or "advanced_menu"
    self.t         = 0
    self.cursor    = 1
    self.scroll    = 0
    self.pending_delete = nil
    self:_refresh()
end

-- Replay.list() is newest first; the file names are timestamps, so flipping the
-- order is a reversal of the same sort.
function ReplaySelect:_refresh()
    self.rows = Replay.list()
    if not self.newest_first then
        table.sort(self.rows, function(a, b) return a.name < b.name end)
    end
    self.cursor = math.min(self.cursor, #self.rows + 1)
    self:_scroll_to(self.cursor)
end

function ReplaySelect:_set_order(newest_first)
    if self.newest_first == newest_first then return end
    self.newest_first   = newest_first
    self.cursor         = 1
    self.scroll         = 0
    self.pending_delete = nil
    Audio.play_event("ui.move")
    self:_refresh()
end

function ReplaySelect:_exit_index() return #self.rows + 1 end

function ReplaySelect:_scroll_to(i)
    local n = #self.rows
    if n <= MAX_ROWS or i > n then return end
    self.scroll = math.max(math.min(self.scroll, i - 1), i - MAX_ROWS)
    self.scroll = math.max(0, math.min(self.scroll, n - MAX_ROWS))
end

function ReplaySelect:_move(dir)
    local n = self:_exit_index()
    self.cursor = ((self.cursor - 1 + dir) % n) + 1
    self.pending_delete = nil
    self:_scroll_to(self.cursor)
    Audio.play_event("ui.move")
end

function ReplaySelect:_back()
    Audio.play_event("ui.back")
    self.app.scenes:replace(self.return_to)
end

-- Load the recording's own stage (the gameplay scene reloads it on entry) and
-- hand the replay to the matching gameplay scene at normal speed.
function ReplaySelect:_play(row)
    local app    = self.app
    local replay = row.replay
    app.campaign         = false
    app.settings.loadout = nil
    app.replay_play      = replay
    app.replay_verify    = false
    app.replay_result    = nil
    app.replay_return    = "replay_select"
    replay:rewind()
    Audio.play_event("ui.confirm")
    Log.info("replay", "playing %s", row.path)
    app.scenes:switch(replay.header.mode == "coop" and "coop_gameplay" or "gameplay")
end

function ReplaySelect:_activate(i)
    if i == self:_exit_index() then self:_back(); return end
    local row = self.rows[i]
    if not row then return end
    self.pending_delete = nil
    self:_play(row)
end

-- Delete needs a second press on the same recording, as in the saves screen.
function ReplaySelect:_delete(i)
    local row = self.rows[i]
    if not row then return end
    if self.pending_delete ~= row.path then
        self.pending_delete = row.path
        return
    end
    self.pending_delete = nil
    Log.info("replay", "deleted %s", row.path)
    row.replay:delete()
    Audio.play_event("ui.back")
    self:_refresh()
    self.cursor = math.min(self.cursor, self:_exit_index())
end

function ReplaySelect:keypressed(key)
    if     key == "up"     then self:_move(-1)
    elseif key == "down"   then self:_move(1)
    elseif key == "left"   then self:_set_order(true)
    elseif key == "right"  then self:_set_order(false)
    elseif key == "return" or key == "space" or key == "kpenter" then self:_activate(self.cursor)
    elseif key == "delete" or key == "backspace" then self:_delete(self.cursor)
    elseif key == "escape" then self:_back()
    end
end

function ReplaySelect:wheelmoved(_dx, dy)
    local n = #self.rows
    if n <= MAX_ROWS then return end
    self.scroll = math.max(0, math.min(self.scroll - dy, n - MAX_ROWS))
end

-- The sort-order label is a widget of its own (the only one the cursor does not
-- stop on), so the pointer can flip the order without the keyboard.
function ReplaySelect:_order_label()
    return self.newest_first and "NEWEST FIRST" or "OLDEST FIRST"
end

function ReplaySelect:_order_at(x, y)
    if #self.rows <= 1 then return false end
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    return dy >= TITLE_Y - 3 and dy <= TITLE_Y + ROW_H
        and dx >= STAGE_RX - self.font:width(self:_order_label()) - 4 and dx <= STAGE_RX + 4
end

function ReplaySelect:_index_at(x, y)
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

function ReplaySelect:mousemoved(x, y)
    local i = self:_index_at(x, y)
    if i and i ~= self.cursor then self.cursor = i; self.pending_delete = nil end
end

function ReplaySelect:mousepressed(x, y)
    if self:_order_at(x, y) then
        self:_set_order(not self.newest_first)
        return
    end
    local i = self:_index_at(x, y)
    if not i then return end
    self.cursor = i
    self:_activate(i)
end

function ReplaySelect:update(dt)
    self.t = self.t + dt
end

-- A recording's file name without the .osr extension, shortened to the date and
-- time the recorder stamped it with (stage12-20260924-183000 -> 09-24 18:30).
local function row_label(row)
    local stage, date, time = row.name:match("^(.-)%-(%d+)%-(%d+)%.osr$")
    if not stage then return (row.name:gsub("%.osr$", "")) end
    return string.format("%s-%s %s:%s", date:sub(5, 6), date:sub(7, 8),
        time:sub(1, 2), time:sub(3, 4))
end

function ReplaySelect:_draw_arrow(x, y, fade)
    if not self.arrow then return end
    local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
    local phase  = 0.5 + 0.5 * math.sin(self.t * 2.2)
    love.graphics.setColor(1, 1, 1, fade)
    love.graphics.draw(self.arrow, x - ARROW_GAP - aw / 2 + 3 * phase, y + ROW_H / 2,
        0, 1, 1, aw / 2, ah / 2)
end

function ReplaySelect:_draw_scroll_marks(fade)
    local n = #self.rows
    if n <= MAX_ROWS then return end
    local g  = love.graphics
    local cx = (NAME_X + STAGE_RX) / 2
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

function ReplaySelect:_draw_row(i, y, fade)
    local row   = self.rows[i]
    local sel   = (i == self.cursor)
    local alpha = (sel and 1 or 0.65) * fade
    local hue   = sel and GOLD or { 1, 1, 1 }
    local col   = { hue[1], hue[2], hue[3], alpha }

    self.name_font:print(row_label(row), NAME_X, y, { color = col })

    local stage = tostring(row.replay.header.stage or "?"):upper()
    if row.replay.header.mode == "coop" then stage = "2P " .. stage end
    self.font:print(stage, STAGE_RX - self.font:width(stage), y + 2, { color = col })
    if sel then self:_draw_arrow(NAME_X, y, fade) end
end

-- What the highlighted recording holds, under the list, and the build it was
-- made on beside the EXIT widget (a recording from another build may diverge).
function ReplaySelect:_draw_detail(fade)
    local row = self.rows[self.cursor]
    local col = { 1, 1, 1, 0.55 * fade }
    local text
    if self.pending_delete then
        text = "PRESS DEL AGAIN TO ERASE THIS RECORDING"
    elseif row then
        local header  = row.replay.header
        local players = tonumber(header.players) or 1
        local seconds = math.floor(row.replay.length / TICKS_PER_SECOND)
        text = string.format("%s   %d PLAYER%s   %d:%02d",
            tostring(header.mode or "?"):upper(), players, players > 1 and "S" or "",
            math.floor(seconds / 60), seconds % 60)
    elseif #self.rows == 0 then
        text = "NO RECORDINGS YET"
    else
        text = ""
    end
    self.font:print(text, NAME_X, DETAIL_Y, { color = col })
    -- A recording made on another build may not reproduce; nothing to say when
    -- it matches, so the line stays empty.
    if row and tostring(row.replay.header.build or "?") ~= Replay.build_id() then
        self.font:print("RECORDED ON AN OLDER BUILD", NAME_X, INFO_Y, { color = col })
    end
end

function ReplaySelect:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade               = math.min(1, self.t / FADE_IN)

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

    local title = "REPLAYS"
    self.font:print(title, (DESIGN_W - self.font:width(title)) / 2, TITLE_Y,
        { color = { GOLD[1], GOLD[2], GOLD[3], fade } })

    if #self.rows > 1 then
        local order = self:_order_label()
        self.font:print(order, STAGE_RX - self.font:width(order), TITLE_Y,
            { color = { 1, 1, 1, 0.55 * fade } })
    end

    for i = 1 + self.scroll, math.min(#self.rows, self.scroll + MAX_ROWS) do
        self:_draw_row(i, ROW_Y0 + (i - 1 - self.scroll) * ROW_DY, fade)
    end
    self:_draw_scroll_marks(fade)
    self:_draw_detail(fade)

    local exit_sel = (self.cursor == self:_exit_index())
    local col = exit_sel and { GOLD[1], GOLD[2], GOLD[3], fade } or { 1, 1, 1, 0.65 * fade }
    local exit_x = EXIT_RX - self.font:width("EXIT")
    self.font:print("EXIT", exit_x, INFO_Y, { color = col })
    if exit_sel then self:_draw_arrow(exit_x, INFO_Y - 2, fade) end

    Hint.print_centered(self.hint_font,
        "{UP/DOWN} SELECT   {LEFT/RIGHT} ORDER   {ENTER} WATCH   {DEL} ERASE   {ESC} BACK",
        DESIGN_W, FOOTER_Y, { alpha = fade })

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return ReplaySelect
