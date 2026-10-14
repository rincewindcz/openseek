-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Scene      = require "engine.core.scene"
local Font       = require "engine.core.font"
local Layout     = require "engine.ui.layout"
local Hint       = require "engine.ui.hint"
local Pointer    = require "engine.ui.pointer"
local Audio      = require "engine.core.audio"
local Log        = require "engine.core.log"
local World      = require "engine.game.world"
local MapFile    = require "engine.game.map_file"
local Loadout    = require "engine.game.loadout"
local Campaign   = require "engine.game.campaign"
local Records    = require "engine.game.records"
local Replay     = require "engine.game.replay"
local Difficulty = require "engine.game.difficulty"
local Sound      = require "engine.game.sound"
local Catalog    = require "engine.editor.catalog"
local Document   = require "engine.editor.document"
local Validate   = require "engine.editor.validate"

-- MAPS screen: the player-made maps (maps/ in the save directory), built like
-- the SAVE / LOAD and REPLAYS panels but tinted amber. A map is played from
-- here (briefing, equip, phase, stats, back here), by one player or by two on
-- the split screen as the map allows, or opened in the editor; the first row
-- starts a new one. Under the list the highlighted map's records
-- (engine/game/records.lua): the fastest win and the highest score, whose
-- recording BEST plays back. A map file dropped on the window is imported.
-- Reached from the ADVANCED submenu.
--
-- enter() takes { return_to = <scene name>, note = <a line to show> }.
local MapSelect = Class(Scene)

MapSelect.ui_pointer = true

local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

local PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 12, 22, 296, 194
local PANEL_ALPHA = 0.65
local BG_TINT     = { 0.86, 0.58, 0.28 }   -- amber wash over the greyscale MAINP
local TITLE_Y     = 32
local ROW_Y0      = 50
local ROW_DY      = 16
local ROW_H       = 12
local MAX_ROWS    = 7
local NAME_X      = 32
local NAME_GAP    = 12
local ART_RX      = 290    -- right edge of the row's art set column
local HIT_X0      = 22
local HIT_X1      = 300
local DETAIL_Y    = 164
local RECORD_Y    = 178
local INFO_Y      = 194
local ARROW_GAP   = 8
local FOOTER_Y    = 222
local FADE_IN     = 0.25
local NOTE_TIME   = 4

local GOLD = { 1, 0.8, 0.2 }

-- The words under the list, each a widget: what to do with the highlighted map.
local ACTIONS = {
    { id = "play", label = "PLAY" }, { id = "coop", label = "2P" }, { id = "best", label = "BEST" },
    { id = "edit", label = "EDIT" }, { id = "copy", label = "COPY" }, { id = "folder", label = "FOLDER" },
    { id = "exit", label = "EXIT" },
}
local ACTION_GAP = 12

local PLAYERS = { [1] = "1 PLAYER", [2] = "2 PLAYERS" }

function MapSelect:init(app)
    Scene.init(self, app)
    self.name_font = Font.get("savechar")
    self.font      = Font.get("chars")
    self.hint_font = Font.get("keysfont")

    local ok, bg = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then bg:setFilter("linear", "linear"); self.bg = bg end
    local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
    if aok then arrow:setFilter("nearest", "nearest"); self.arrow = arrow end
end

function MapSelect:enter(opts)
    opts = opts or {}
    self.return_to = opts.return_to or self.return_to or "advanced_menu"
    self.t         = 0
    self.cursor    = self.cursor or 1
    self.scroll    = 0
    self.note      = nil
    self.pending_delete = nil
    self.app.play_return = nil
    Sound.play_music("menu")
    self:_refresh()
    if opts.note then self:_say(opts.note) end
end

-- Rows: NEW MAP first, then the maps, newest first.
function MapSelect:_refresh()
    self.rows = { { kind = "new" } }
    for _, item in ipairs(MapFile.list()) do
        self.rows[#self.rows + 1] = { kind = "map", name = item.name, map = item.map, hash = item.hash }
    end
    self.cursor = math.max(1, math.min(self.cursor, #self.rows))
    self:_scroll_to(self.cursor)
end

function MapSelect:_say(text)
    self.note = { text = text, left = NOTE_TIME }
end

-- A map file dropped on the window joins the list.
function MapSelect:filedropped(file)
    local ok, text = pcall(function()
        file:open("r")
        local data = file:read()
        file:close()
        return data
    end)
    local stem = tostring(file:getFilename()):match("([^/\\]+)%.[^.]*$")
    local name, err = nil, "cannot read the file"
    if ok and text then name, err = MapFile.import(text, stem) end
    if name then
        Audio.play_event("ui.confirm")
        self:_refresh()
        for i, row in ipairs(self.rows) do
            if row.name == name then self.cursor = i end
        end
        self:_scroll_to(self.cursor)
        self:_say("MAP ADDED")
    else
        Audio.play_event("ui.back")
        self:_say("NOT A MAP: " .. tostring(err):upper())
    end
end

function MapSelect:_scroll_to(i)
    local n = #self.rows
    if n <= MAX_ROWS then self.scroll = 0; return end
    self.scroll = math.max(math.min(self.scroll, i - 1), i - MAX_ROWS)
    self.scroll = math.max(0, math.min(self.scroll, n - MAX_ROWS))
end

function MapSelect:_move(dir)
    local n = #self.rows
    self.cursor = ((self.cursor - 1 + dir) % n) + 1
    self.pending_delete = nil
    self:_scroll_to(self.cursor)
    Audio.play_event("ui.move")
end

function MapSelect:_back()
    Audio.play_event("ui.back")
    self.app.scenes:replace(self.return_to)
end

-- What keeps a map from being played, or nil. Checked once per row.
function MapSelect:_problem(row)
    if row.problem == nil then
        local issues = Validate.run(Document:new(row.map, row.name))
        row.problem = false
        for _, item in ipairs(issues) do
            if item.level == "error" then row.problem = item.text; break end
        end
    end
    return row.problem or nil
end

-- Play a map: by one player, or by two on the split screen, who first pick
-- their vehicles' looks and controls as a co-op campaign does.
function MapSelect:_play(row, players)
    local app = self.app
    if self:_problem(row) then
        Audio.play_event("ui.back")
        self:_say("NOT PLAYABLE YET: OPEN IT IN THE EDITOR")
        return
    end
    if row.map.players and row.map.players ~= players then
        Audio.play_event("ui.back")
        self:_say("THIS MAP IS FOR " .. PLAYERS[row.map.players])
        return
    end
    Audio.play_event("ui.confirm")
    Log.info("game", "map %s, %d", row.name, players)
    local stage = World.map_stage(row.name)
    app.campaign = false
    app.coop_run = nil
    app.world:load(stage)
    app.after_stage_load()
    local own = app.world.stage.mission
    -- A fresh MISSION-mode inventory, as for a single stage, under the map's own rules for it.
    Loadout.for_map(app, own and own.equip)
    if players ~= Campaign.PLAYERS then
        app.play_return = { scene = "map_select" }
        app.scenes:switch("mission_briefing", stage)
        return
    end
    app.scenes:switch("vehicle_select", { players = Campaign.PLAYERS, return_to = "map_select", on_start = function()
        app.play_return = { scene = "map_select" }
        Campaign.start_team(app, own)
        app.scenes:switch("mission_briefing", stage)
    end })
end

-- Play back the recording of the map's fastest win: the lone player's, else the team's.
function MapSelect:_watch(row)
    local app = self.app
    local path
    for _, mode in ipairs(Records.MODES) do
        path = path or Records.replay(row.name, row.hash, mode)
    end
    local replay = path and Replay.load(path)
    if not replay then
        Audio.play_event("ui.back")
        self:_say("NO RECORDING OF A BEST RUN YET")
        return
    end
    Audio.play_event("ui.confirm")
    Log.info("replay", "playing %s", path)
    app.campaign         = false
    app.settings.loadout = nil
    app.replay_play      = replay
    app.replay_verify    = false
    app.replay_result    = nil
    app.replay_return    = "map_select"
    replay:rewind()
    app.scenes:switch(replay.header.mode == "coop" and "coop_gameplay" or "gameplay")
end

function MapSelect:_edit(row)
    Audio.play_event("ui.confirm")
    self.app.scenes:switch("editor", row.kind == "map" and { map = row.name } or { new = true })
end

function MapSelect:_copy(row)
    local name = MapFile.file_name(row.name .. "_copy")
    row.map.name = row.map.name .. " COPY"
    -- The row's map went through Document:new for its check, which is fine to
    -- write back: it only dropped unused types.
    if MapFile.write(row.map, name) then
        Audio.play_event("ui.confirm")
        self:_refresh()
    end
end

function MapSelect:_open_folder()
    love.filesystem.createDirectory(MapFile.DIR)
    pcall(love.system.openURL, "file://" .. love.filesystem.getSaveDirectory() .. "/" .. MapFile.DIR)
end

function MapSelect:_act(id)
    local row = self.rows[self.cursor]
    self.pending_delete = nil
    if id == "exit" then self:_back()
    elseif id == "folder" then self:_open_folder()
    elseif not row then return
    elseif row.kind == "new" then self:_edit(row)
    elseif id == "play" then self:_play(row, row.map.players or 1)
    elseif id == "coop" then self:_play(row, Campaign.PLAYERS)
    elseif id == "best" then self:_watch(row)
    elseif id == "edit" then self:_edit(row)
    elseif id == "copy" then self:_copy(row)
    end
end

-- Delete needs a second press on the same map, as in the saves screen.
function MapSelect:_delete()
    local row = self.rows[self.cursor]
    if not row or row.kind ~= "map" then return end
    if self.pending_delete ~= row.name then
        self.pending_delete = row.name
        return
    end
    self.pending_delete = nil
    MapFile.delete(row.name)
    Records.forget(row.name)
    Audio.play_event("ui.back")
    self:_refresh()
end

function MapSelect:keypressed(key)
    if     key == "up"     then self:_move(-1)
    elseif key == "down"   then self:_move(1)
    elseif key == "return" or key == "space" or key == "kpenter" then self:_act("play")
    elseif key == "2"      then self:_act("coop")
    elseif key == "b"      then self:_act("best")
    elseif key == "e"      then self:_act("edit")
    elseif key == "c"      then self:_act("copy")
    elseif key == "f"      then self:_act("folder")
    elseif key == "n"      then self.cursor = 1; self:_act("edit")
    elseif key == "delete" or key == "backspace" then self:_delete()
    elseif key == "escape" then self:_back()
    end
end

function MapSelect:wheelmoved(_dx, dy)
    local n = #self.rows
    if n <= MAX_ROWS then return end
    self.scroll = math.max(0, math.min(self.scroll - dy, n - MAX_ROWS))
end

-- The action words sit right-aligned on one line; x of each, left to right.
function MapSelect:_action_spans()
    local spans, x = {}, ART_RX
    for i = #ACTIONS, 1, -1 do
        local w = self.font:width(ACTIONS[i].label)
        x = x - w
        spans[i] = { x = x, w = w, id = ACTIONS[i].id, label = ACTIONS[i].label }
        x = x - ACTION_GAP
    end
    return spans
end

function MapSelect:_action_at(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dy < INFO_Y - 3 or dy > INFO_Y + ROW_H then return nil end
    for _, span in ipairs(self:_action_spans()) do
        if dx >= span.x - 4 and dx <= span.x + span.w + 4 then return span.id end
    end
    return nil
end

function MapSelect:_index_at(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dx < HIT_X0 or dx > HIT_X1 then return nil end
    for i = 1, math.min(MAX_ROWS, #self.rows - self.scroll) do
        local ry = ROW_Y0 + (i - 1) * ROW_DY
        if dy >= ry - 3 and dy <= ry + ROW_H then return i + self.scroll end
    end
    return nil
end

function MapSelect:mousemoved(x, y)
    self.hot_action = self:_action_at(x, y)
    local i = self:_index_at(x, y)
    if i and i ~= self.cursor then self.cursor = i; self.pending_delete = nil end
end

function MapSelect:mousepressed(x, y)
    local action = self:_action_at(x, y)
    if action then self:_act(action); return end
    local i = self:_index_at(x, y)
    if not i then return end
    self.cursor = i
    self:_act(self.rows[i].kind == "new" and "edit" or "play")
end

function MapSelect:update(dt)
    self.t = self.t + dt
    if self.note then
        self.note.left = self.note.left - dt
        if self.note.left <= 0 then self.note = nil end
    end
end

function MapSelect:_draw_arrow(x, y, fade)
    if not self.arrow then return end
    local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
    local phase  = 0.5 + 0.5 * math.sin(self.t * 2.2)
    love.graphics.setColor(1, 1, 1, fade)
    love.graphics.draw(self.arrow, x - ARROW_GAP - aw / 2 + 3 * phase, y + ROW_H / 2,
        0, 1, 1, aw / 2, ah / 2)
end

function MapSelect:_draw_scroll_marks(fade)
    local n = #self.rows
    if n <= MAX_ROWS then return end
    local g  = love.graphics
    local cx = (NAME_X + ART_RX) / 2
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

-- text cut to fit w in a bitmap font.
local function fit(font, text, w)
    if font:width(text) <= w then return text end
    local n = #text
    while n > 1 and font:width(text:sub(1, n) .. "..") > w do n = n - 1 end
    return text:sub(1, n) .. ".."
end

function MapSelect:_draw_row(i, y, fade)
    local row   = self.rows[i]
    local sel   = (i == self.cursor)
    local alpha = (sel and 1 or 0.65) * fade
    local hue   = sel and GOLD or { 1, 1, 1 }
    local col   = { hue[1], hue[2], hue[3], alpha }
    if row.kind == "new" then
        self.name_font:print("NEW MAP", NAME_X, y, { color = col })
    else
        local art = Catalog.art_label(row.map.environment.art or 0)
        self.font:print(art, ART_RX - self.font:width(art), y + 2, { color = col })
        local room = ART_RX - self.font:width(art) - NAME_GAP - NAME_X
        self.name_font:print(fit(self.name_font, row.map.name:upper(), room), NAME_X, y, { color = col })
    end
    if sel then self:_draw_arrow(NAME_X, y, fade) end
end

local WEATHER = { snow = "SNOW", rain = "RAIN" }

-- A map's records as its file stands, looked up once per row.
function MapSelect:_records(row)
    if not row.records then row.records = Records.of(row.name, row.hash) end
    return row.records
end

-- Whether an action word does anything for the highlighted row.
function MapSelect:_usable(id, row)
    if id == "exit" or id == "folder" then return true end
    if not row then return false end
    if row.kind ~= "map" then return id == "edit" end
    if id == "play" then return row.map.players ~= Campaign.PLAYERS end
    if id == "coop" then return row.map.players ~= 1 end
    if id == "best" then
        for _, mode in ipairs(Records.MODES) do
            if Records.replay(row.name, row.hash, mode) then return true end
        end
        return false
    end
    return true
end

-- Two lines under the list: what the highlighted map is, and its records
-- (per way of playing it the fastest win and the highest score).
function MapSelect:_draw_detail(fade)
    local row = self.rows[self.cursor]
    local col = { 1, 1, 1, 0.55 * fade }
    local text, best = "", nil
    if self.note then
        text = self.note.text
    elseif self.pending_delete then
        text = "PRESS DEL AGAIN TO ERASE THIS MAP"
    elseif row and row.kind == "map" and self:_problem(row) then
        text = "NOT PLAYABLE YET: OPEN IT IN THE EDITOR"
    elseif row and row.kind == "map" then
        local map    = row.map
        local author = map.author:upper()
        local parts  = { author:match("%S") and ("BY " .. author) or nil }
        parts[#parts + 1] = PLAYERS[map.players] or "1-2 PLAYERS"
        if map.environment.night == true then parts[#parts + 1] = "NIGHT" end
        if WEATHER[map.environment.weather] then parts[#parts + 1] = WEATHER[map.environment.weather] end
        if map.difficulty then
            local preset = Difficulty.preset_label(Difficulty.match_preset(map.difficulty))
            parts[#parts + 1] = preset and ("ALWAYS " .. preset) or "OWN DIFFICULTY"
        end
        if map.based_on then parts[#parts + 1] = "COPY OF " .. map.based_on:upper() end
        text = table.concat(parts, "   ")
        local records, wins = self:_records(row), {}
        for _, mode in ipairs(Records.MODES) do
            local won = records[mode]
            if won then
                wins[#wins + 1] = string.format("%s %s %d", mode == "coop" and "2P" or "1P",
                    Records.clock(won.time), won.score)
            end
        end
        best = #wins > 0 and table.concat(wins, "   ") or "NOT WON YET"
    elseif row then
        text = "START A MAP OF YOUR OWN IN THE EDITOR"
    end
    self.font:print(fit(self.font, text, ART_RX - NAME_X), NAME_X, DETAIL_Y, { color = col })
    if best then
        self.font:print(fit(self.font, best, ART_RX - NAME_X), NAME_X, RECORD_Y,
            { color = { GOLD[1], GOLD[2], GOLD[3], 0.75 * fade } })
    end
end

function MapSelect:draw()
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

    local title = "MAPS"
    self.font:print(title, (DESIGN_W - self.font:width(title)) / 2, TITLE_Y,
        { color = { GOLD[1], GOLD[2], GOLD[3], fade } })

    for i = 1 + self.scroll, math.min(#self.rows, self.scroll + MAX_ROWS) do
        self:_draw_row(i, ROW_Y0 + (i - 1 - self.scroll) * ROW_DY, fade)
    end
    self:_draw_scroll_marks(fade)
    self:_draw_detail(fade)

    local row = self.rows[self.cursor]
    for _, span in ipairs(self:_action_spans()) do
        local usable = self:_usable(span.id, row)
        local hot    = usable and self.hot_action == span.id
        local col = hot and { GOLD[1], GOLD[2], GOLD[3], fade } or { 1, 1, 1, (usable and 0.65 or 0.25) * fade }
        self.font:print(span.label, span.x, INFO_Y, { color = col })
    end

    Hint.print_centered(self.hint_font,
        "{ENTER} PLAY  {2} CO-OP  {B} BEST RUN  {E} EDIT  {C} COPY  {DEL} ERASE  {ESC} BACK",
        DESIGN_W, FOOTER_Y, { alpha = fade })

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return MapSelect
