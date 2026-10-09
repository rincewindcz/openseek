-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Scene  = require "engine.core.scene"
local Font   = require "engine.core.font"
local Assets = require "engine.core.assets"
local Audio  = require "engine.core.audio"
local Config = require "engine.core.config"
local Flic   = require "engine.core.flic"
local Log    = require "engine.core.log"
local Layout = require "engine.ui.layout"
local json   = require "lib.json"

-- The original's ending (FUN_001f2b70), played when a campaign run clears the
-- last stage: the CD's ending animation with its frame-timed sounds, then the
-- end music under six story pictures (FIN01..03, VIC1..3); the shareware has
-- no animation and four pictures of its own (DEMO01..03, DEMOOVER). Each
-- picture fades in, holds, then types its lines one letter per retrace (a tab
-- pauses and draws nothing) and waits on PRESS A KEY OR MOUSE BUTTON. The
-- story and its layout come from the pack (tools/export_ending.py), the timing
-- and the animation's sound cues from data/ending.json.
--
-- Over the original: a key completes the whole picture's text instead of one
-- line, a key skips the animation, and Esc skips the rest of the sequence.
--
-- enter(opts): alternate (VIC3's alternate ending), record (the run's record,
-- engine/game/campaign.lua), scores (a number, or co-op { score, label }
-- entries), preview (without a record, the sample record and score of
-- data/ending.json preview, for the overview's viewer), keep_music (leave the
-- end music playing into the next scene), on_done (where to go once it ends;
-- back to the main menu without).
local Ending = Class(Scene)

Ending.hide_cursor = true

local DATA_PATH     = "data/ending.json"
local TEXT_PATH     = "ending/ending.json"
local ANIM_PATH     = "ending/reganim.flc"
local FONT          = "endstory"
local FALLBACK_FONT = "endchars"   -- a pack exported before endstory existed
local DW, DH        = Layout.DESIGN_W, Layout.DESIGN_H

local function read_json(path)
    if not love.filesystem.getInfo(path) then return nil end
    local ok, data = pcall(json.decode, love.filesystem.read(path) or "")
    return ok and type(data) == "table" and data or nil
end

function Ending:init(app)
    Scene.init(self, app)
    self.cfg = read_json(DATA_PATH) or {}
    self.cfg.anim  = self.cfg.anim or {}
    self.cfg.stats = self.cfg.stats or {}
    self._pictures = {}
end

function Ending:_picture(name)
    if self._pictures[name] == nil then
        local path = Assets.path("fullscreen/" .. name .. ".png")
        local ok, img = false, nil
        if love.filesystem.getInfo(path) then ok, img = pcall(love.graphics.newImage, path) end
        if ok then
            img:setFilter("nearest", "nearest")
            self._pictures[name] = img
        else
            Log.warn("ending", "missing %s", path)
            self._pictures[name] = false
        end
    end
    return self._pictures[name] or nil
end

function Ending:enter(opts)
    opts = opts or {}
    local preview   = opts.preview and not opts.record and self.cfg.preview or {}
    local font      = Assets.exists("fonts/" .. FONT .. ".json") and FONT or FALLBACK_FONT
    self.alternate  = opts.alternate and true or false
    self.record     = opts.record or preview.record
    self.scores     = opts.scores or preview.scores
    self.on_done    = opts.on_done
    self.keep_music = opts.keep_music and true or false
    self.finished   = false
    self.story      = read_json(Assets.path(TEXT_PATH)) or { slides = {} }
    self.font       = Font.get(font)

    Audio.play_music(nil)   -- the animation plays without music, as in the original
    self.anim = Flic.open(Assets.path(ANIM_PATH))
    if self.anim then
        self:_start_anim()
    else
        self:_start_slides()
    end
end

function Ending:leave()
    self:_stop_loops()
    self.anim = nil
end

function Ending:_finish()
    if self.finished then return end
    self.finished = true
    self:_stop_loops()
    if not self.keep_music then Audio.play_music(nil) end
    Log.info("ending", "done")
    if self.on_done then
        self.on_done()
    else
        self.app.scenes:switch("main_menu")
    end
end

-- animation

function Ending:_start_anim()
    self.state   = "anim"
    self.anim_t  = 0
    self.cues    = {}
    for event, frames in pairs(self.cfg.anim.cues or {}) do
        for _, f in ipairs(frames) do
            self.cues[f] = self.cues[f] or {}
            table.insert(self.cues[f], event)
        end
    end
    self.loops = {}
    for _, def in ipairs(self.cfg.anim.loops or {}) do
        local src = Audio.loop(def.event)
        if src then
            src:setVolume(0)
            src:play()
            self.loops[#self.loops + 1] = { def = def, source = src }
        end
    end
    self:_show_frame()
end

function Ending:_stop_loops()
    for _, loop in ipairs(self.loops or {}) do loop.source:stop() end
    self.loops = {}
end

-- Decode the next frame and fire the sounds the original cues on it.
function Ending:_show_frame()
    local frame = self.anim.decoded
    for _, event in ipairs(self.cues[frame] or {}) do Audio.play_event(event) end
    self.anim:next_frame()
    for _, loop in ipairs(self.loops) do
        local def     = loop.def
        local level   = def.level or 1
        local fade_at = def.fade_at or 0
        if frame > fade_at then
            level = level * math.max(0, 1 - (frame - fade_at) / math.max(1, def.fade_frames or 1))
        end
        loop.source:setVolume(level * Audio.event_gain(def.event))
    end
end

function Ending:_update_anim(dt)
    local frame_time = self.cfg.anim.frame_time or (4 / 70)
    self.anim_t = self.anim_t + dt
    local due = math.min(self.anim.frames, math.floor(self.anim_t / frame_time) + 1)
    while self.anim.decoded < due do self:_show_frame() end
    if self.anim_t >= self.anim.frames * frame_time then
        self:_start_slides()
    end
end

-- story pictures

function Ending:_start_slides()
    self:_stop_loops()
    self.state = "slides"
    self.index = 0
    if self.cfg.music then Audio.play_music(self.cfg.music) end
    self:_next_slide()
end

function Ending:_next_slide()
    self.index = self.index + 1
    local slide = self.story.slides[self.index]
    if not slide then
        self.state = "done"   -- finished from update, never from inside enter()
        self.slide = nil
        return
    end
    self.slide   = slide
    self.lines   = self:_lines(slide)
    self.phase   = "in"
    self.t       = 0
    self.line    = 1
    self.char    = 0
    self.type_t  = 0
end

-- The picture's lines: the story (VIC3's alternate ending on request), the
-- lines data/ending.json adds under it (the shareware's closing call to get
-- the full game data), then the run's record under the first pictures.
function Ending:_lines(slide)
    local out = {}
    local story = (self.alternate and slide.alternate_lines) or slide.lines or {}
    for _, l in ipairs(story) do out[#out + 1] = l end
    for _, l in ipairs((self.cfg.extra_lines or {})[slide.picture] or {}) do
        out[#out + 1] = l
    end
    -- EXTRA (ending_stats): the run's service record under the story.
    if Config.ending_stats and self.record then
        for _, l in ipairs(self:_stat_lines(slide.picture)) do out[#out + 1] = l end
    end
    return out
end

local function clock(seconds)
    local s = math.floor(seconds or 0)
    return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end

function Ending:_stat_lines(picture)
    local cfg    = self.cfg.stats
    local keys   = (cfg.pictures or {})[picture] or {}
    local labels = cfg.labels or {}
    local rows   = {}
    for _, key in ipairs(keys) do
        if key == "score" then
            if type(self.scores) == "table" then
                for _, e in ipairs(self.scores) do
                    rows[#rows + 1] = { (e.label or "") .. " SCORE", tostring(e.score or 0) }
                end
            elseif self.scores then
                rows[#rows + 1] = { labels.score or "SCORE", tostring(self.scores) }
            end
        elseif key == "time" then
            rows[#rows + 1] = { labels.time or "TIME", clock(self.record.time) }
        else
            rows[#rows + 1] = { labels[key] or key:upper(), tostring(math.floor(self.record[key] or 0)) }
        end
    end
    local out     = {}
    local columns = cfg.columns or 38
    for i, row in ipairs(rows) do
        local gap = math.max(1, columns - #row[1] - #row[2])
        out[i] = {
            text = row[1] .. string.rep(" ", gap) .. row[2],
            x    = cfg.x or 8,
            y    = (cfg.y or 150) + (i - 1) * (cfg.line_height or 10),
        }
    end
    return out
end

-- Type letters for dt seconds. Returns true once every line is out.
function Ending:_type(dt)
    local char_time = self.cfg.char_time or (1 / 70)
    local tab_pause = self.cfg.tab_pause or (60 / 70)
    self.type_t = self.type_t - dt
    while self.type_t <= 0 do
        local line = self.lines[self.line]
        if not line then return true end
        if self.char >= #line.text then
            self.line, self.char = self.line + 1, 0
        else
            self.char = self.char + 1
            local ch = line.text:sub(self.char, self.char)
            self.type_t = self.type_t + (ch == "\t" and tab_pause or char_time)
        end
    end
    return false
end

function Ending:_complete_text()
    self.line  = #self.lines + 1
    self.char  = 0
    self.phase = "wait"
    self.t     = 0
end

function Ending:_update_slide(dt)
    self.t = self.t + dt
    if self.phase == "in" then
        if self.t >= (self.cfg.fade_in or 0.5) then self.phase, self.t = "hold", 0 end
    elseif self.phase == "hold" then
        if self.t >= (self.cfg.hold or 2.5) then self.phase, self.t = "type", 0 end
    elseif self.phase == "type" then
        if self:_type(dt) then self:_complete_text() end
    elseif self.phase == "out" then
        if self.t >= (self.cfg.fade_out or 0.3) then self:_next_slide() end
    end
end

function Ending:update(dt)
    if self.finished then return end
    if self.state == "anim" then
        self:_update_anim(dt)
    elseif self.state == "done" then
        self:_finish()
    else
        self:_update_slide(dt)
    end
end

-- input

function Ending:_advance()
    if self.finished or self.state == "done" then return end
    if self.state == "anim" then
        self:_start_slides()
    elseif self.phase == "wait" then
        self.phase, self.t = "out", 0
    elseif self.phase ~= "out" then
        self:_complete_text()
    end
end

function Ending:keypressed(key)
    if key == "escape" then
        self:_finish()
    else
        self:_advance()
    end
end

function Ending:mousereleased()
    self:_advance()
end

-- drawing

function Ending:_alpha()
    if self.phase == "in" then
        local t = self.cfg.fade_in or 0.5
        return t > 0 and math.min(1, self.t / t) or 1
    elseif self.phase == "out" then
        local t = self.cfg.fade_out or 0.3
        return t > 0 and math.max(0, 1 - self.t / t) or 0
    end
    return 1
end

function Ending:_draw_text(alpha)
    local cell  = self.cfg.cell or 8
    local color = { 1, 1, 1, alpha }
    for i = 1, math.min(self.line, #self.lines) do
        local l    = self.lines[i]
        local text = i < self.line and l.text or l.text:sub(1, self.char)
        text = text:gsub("\t", "")
        self.font:print(text, l.x, l.y, { cell = cell, color = color })
    end
    local prompt = self.slide.prompt
    if (self.phase == "wait" or self.phase == "out") and prompt and self.story.prompt then
        self.font:print(self.story.prompt, prompt.x, prompt.y, { cell = cell, color = color })
    end
end

function Ending:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local scale, ox, oy = Layout.fit(screen_w, screen_h)
    g.clear(0, 0, 0, 1)
    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)
    if self.state == "anim" and self.anim then
        g.setColor(1, 1, 1, 1)
        g.draw(self.anim.image, 0, 0, 0, DW / self.anim.width, DH / self.anim.height)
    elseif self.slide then
        local alpha   = self:_alpha()
        local picture = self:_picture(self.slide.picture)
        if picture then
            g.setColor(1, 1, 1, alpha)
            g.draw(picture, 0, 0, 0, DW / picture:getWidth(), DH / picture:getHeight())
        end
        self:_draw_text(alpha)
    end
    g.pop()
    g.setColor(1, 1, 1, 1)
end

return Ending
