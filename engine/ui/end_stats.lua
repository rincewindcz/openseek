-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Assets = require "engine.core.assets"
local Score  = require "engine.game.score"
local Layout = require "engine.ui.layout"
local Log    = require "engine.core.log"

-- End-of-phase DESTRUCTION STATS screen. Drawn over the dimmed game once the
-- chopper lands home: a header (PHASE n / DESTRUCTION STATS), five tallied
-- lines (ground forces %, buildings %, choppers shot down, rescues, an OK
-- rating), and a running TOTAL SCORE.
--
-- Two phases on one time axis. The reveal counts each line up from zero, its
-- row of kill icons filling proportionally, with the score untouched. The
-- scoring pass then winds every line back down to zero, and each line pays its
-- bonus into TOTAL SCORE as it empties, the way the original tallies a phase.
-- Both passes are staggered line by line. See export_phend.py.
local EndStats = Class()

local DIR = "phend/"   -- under assets/

-- Design canvas (the original screen is 320x240); the whole thing is scaled to
-- fit the window and centered, so every offset below is in these coordinates.
local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local LX        = 16      -- label left edge ("N." line number)
local TEXT_DX   = 15      -- label body text start (past the "N." line number)
local NUM_RX    = 258     -- number readout right edge (digits end here)
local ROW_Y0    = 72      -- first stat row baseline
local ROW_DY    = 28      -- row pitch
local ICON_Y    = 11      -- kill-icon row offset below the label
local ICON_GAP  = 2
local TOTAL_Y   = 216     -- TOTAL SCORE row
local MAX_ICONS = 10      -- 10 icons == 100% / full tally

local LINE_TIME     = 0.7  -- seconds to count one line up
local LINE_STAGGER  = 0.45 -- gap between successive lines starting to count up
local PHASE_GAP     = 0.5  -- pause between the reveal and the scoring pass
local SCORE_TIME    = 0.45 -- seconds to wind one line back down into the score
local SCORE_STAGGER = 0.3  -- gap between successive lines starting to wind down
local BADGE_FPS     = 18

function EndStats:init()
    self.active = false
    self._img   = {}
    self.header = self:_load("header.png")
    self.totalscore = self:_load("label_totalscore.png")
    self.pct    = self:_load("pct.png")
    self.phase_num = {}
    for i = 0, 3 do self.phase_num[i + 1] = self:_load("phase_f" .. i .. ".png") end
    self.digit = {}
    for i = 0, 19 do self.digit[i] = self:_load(string.format("digit_f%02d.png", i)) end
    self.killicon = {}
    for i = 0, 3 do self.killicon[i] = self:_asset("hud/killicon_f" .. string.format("%02d", i) .. ".png") end
    self.okbadge = {}
    local i = 0
    while true do
        local img = self:_asset("hud/okbadge_f" .. string.format("%02d", i) .. ".png", true)
        if not img then break end
        self.okbadge[i + 1] = img
        i = i + 1
    end
end

function EndStats:_load(name, quiet)
    return self:_asset(DIR .. name, quiet)
end

function EndStats:_asset(path, quiet)
    if self._img[path] == nil then
        -- Check the file exists before newImage: love.js (Lua 5.1 web build) raises
        -- an uncatchable error when newImage is handed a missing path, unlike native
        -- LOVE where pcall would swallow it. getInfo is the portable existence probe.
        local full = Assets.path(path)
        local img
        if love.filesystem.getInfo(full) then
            img = love.graphics.newImage(full)
            img:setFilter("nearest", "nearest")
        end
        if img then
            self._img[path] = img
        else
            if not quiet then Log.warn("endstats", "missing %s", path) end
            self._img[path] = false
        end
    end
    return self._img[path] or nil
end

-- lifecycle

-- Build the per-line tally columns from one participant's figures. A single
-- player yields one (gold) column; co-op yields one tinted column per player.
-- A participant: { player, color, ground={killed,total}, buildings={killed,total},
-- choppers, rescues, badges }.
-- Every line is paid on the figure it prints, never on the raw count behind it:
-- the first two on their truncated percentage, the chopper line on its tiered
-- readout (see Score.percent / Score.chopper_tier).
local function participant_cols(p)
    local ground = Score.percent((p.ground    and p.ground.killed)    or 0,
                                 (p.ground    and p.ground.total)     or 0)
    local build  = Score.percent((p.buildings and p.buildings.killed) or 0,
                                 (p.buildings and p.buildings.total)  or 0)
    local choppers, chopper_step = Score.chopper_tier(p.choppers)
    local rescues = p.rescues or 0
    local ok      = p.badges  or 0
    return {
        ground    = { value = ground,   bonus = Score.line_bonus("ground",    ground) },
        buildings = { value = build,    bonus = Score.line_bonus("buildings", build) },
        choppers  = { value = choppers, bonus = choppers * chopper_step },
        rescues   = { value = rescues,  bonus = Score.line_bonus("rescues",   rescues) },
        ok        = { value = ok,       bonus = Score.line_bonus("ok",        ok) },
    }
end

-- stats: { phase, participants = { {player, color, ground, buildings, choppers,
-- rescues, badges}, ... } } (one participant single player, two in co-op).
function EndStats:start(stats)
    local parts = stats.participants or {}
    self.players_meta = {}
    self.base_score   = 0
    for _, p in ipairs(parts) do
        p._cols = participant_cols(p)
        p._base = (p.player and p.player.score) or 0
        self.base_score = self.base_score + p._base
        self.players_meta[#self.players_meta + 1] = p
    end
    self.coop = #parts > 1

    local kinds = {
        { kind = "ground",    pct = true, icon = 0 },
        { kind = "buildings", pct = true, icon = 1 },
        { kind = "choppers",  icon = 2 },
        { kind = "rescues",   icon = 3 },
        { kind = "ok",        badge = true },
    }
    self.rows = {}
    for _, k in ipairs(kinds) do
        local row = { kind = k.kind, pct = k.pct, icon = k.icon, badge = k.badge, cols = {} }
        for _, p in ipairs(parts) do
            local c = p._cols[k.kind]
            row.cols[#row.cols + 1] = { value = c.value, bonus = c.bonus,
                                        color = p.color, player = p.player }
        end
        self.rows[#self.rows + 1] = row
    end

    self.phase     = stats.phase or 1
    self.t         = 0
    self.badge_t   = 0
    self.active    = true
    self.applied   = false
    self.dismissed = false
    -- When the last line finishes counting up, when the scoring pass starts, and
    -- when the last line has been paid into the score.
    local last        = math.max(0, #self.rows - 1)
    self._reveal_time = last * LINE_STAGGER + LINE_TIME
    self._score_at    = self._reveal_time + PHASE_GAP
    self._score_time  = self._score_at + last * SCORE_STAGGER + SCORE_TIME
end

function EndStats:is_active() return self.active end

local function smoothstep(p)
    if p <= 0 then return 0 end
    if p >= 1 then return 1 end
    return p * p * (3 - 2 * p)
end

-- How much of row i (1-based) has counted up, 0..1, eased.
function EndStats:_row_revealed(i)
    return smoothstep((self.t - (i - 1) * LINE_STAGGER) / LINE_TIME)
end

-- How much of row i has since been wound back down into the score, 0..1. The
-- scoring pass only starts once every line is full, so it never overtakes the
-- reveal.
function EndStats:_row_scored(i)
    return smoothstep((self.t - self._score_at - (i - 1) * SCORE_STAGGER) / SCORE_TIME)
end

-- What a row still shows, 0..1 of its value: counted up, less what has already
-- been paid into the score.
function EndStats:_row_fill(i)
    return math.max(0, self:_row_revealed(i) - self:_row_scored(i))
end

function EndStats:update(dt)
    if not self.active then return end
    if self.dismissed then
        self.active = false
        return
    end
    self.badge_t = self.badge_t + dt
    self.t = self.t + dt
    if not self.applied and self.t >= self._score_time then
        self:_apply_final()
    end
end

-- Running TOTAL SCORE: the base plus the part of each line's bonus the scoring
-- pass has already counted off that line.
function EndStats:_total_score()
    local s = self.base_score
    for i, row in ipairs(self.rows) do
        local scored = self:_row_scored(i)
        for _, col in ipairs(row.cols) do
            s = s + math.floor(col.bonus * scored + 0.5)
        end
    end
    return s
end

-- Fold each player's earned bonus into their own score (co-op keeps the two
-- scores separate); idempotent. Credited through Score.award so the phase bonus
-- can hand out bonus vehicles like any other points.
function EndStats:_apply_final()
    if self.applied then return end
    self.applied = true
    for _, p in ipairs(self.players_meta) do
        if p.player then
            local bonus = 0
            for _, row in ipairs(self.rows) do
                for _, col in ipairs(row.cols) do
                    if col.player == p.player then bonus = bonus + col.bonus end
                end
            end
            p.player.score = p._base
            Score.award(p.player, bonus)
        end
    end
end

-- Advance the screen a step: snap the reveal to a full board and start the
-- scoring pass at once, then snap that to a settled board and a banked score,
-- then dismiss. The dismiss lands on the next update(): the scene hands off when
-- is_active() drops right after its update() call, so a press must not clear it.
function EndStats:keypressed()
    if not self.active then return false end
    if self.t < self._score_at then
        self.t = self._score_at
    elseif self.t < self._score_time then
        self.t = self._score_time
        self:_apply_final()
    else
        self.dismissed = true
    end
    return true
end

-- draw

-- Right-align a number's digits so the readout ends at design x = rx. The gold
-- digit set (f10-19) draws untinted; the white set (f0-9) is tinted to a color
-- so co-op can show each player's column in their HUD color.
function EndStats:_draw_number(g, value, rx, ty, gold, color)
    local base = gold and 10 or 0
    local str  = tostring(math.max(0, math.floor(value + 0.5)))
    local x    = rx
    local c    = color or { 1, 1, 1 }
    for i = #str, 1, -1 do
        local d   = base + tonumber(str:sub(i, i))
        local img = self.digit[d]
        if img then
            x = x - img:getWidth()
            g.setColor(c[1], c[2], c[3])
            g.draw(img, x, ty)
            x = x - 1
        end
    end
    return x
end

-- Right edges of the value column(s): single gold column, or two tinted columns
-- in co-op (player 1, then player 2), pushed right of the longest label
-- ("BUILDINGS / INSTALLATIONS").
local COOP_RX = { 244, 300 }

function EndStats:_draw_row_values(g, row, i, ry)
    local fill = self:_row_fill(i)
    for j, col in ipairs(row.cols) do
        local shown = col.value * fill
        local rx, gold, color
        if self.coop then
            rx, gold, color = COOP_RX[j] or NUM_RX, false, col.color
        else
            rx, gold, color = NUM_RX, true, nil
        end
        self:_draw_number(g, shown, rx, ry, gold, color)
        if row.pct and self.pct then
            g.setColor(1, 1, 1)
            g.draw(self.pct, rx + 3, ry)
        end
    end
end

function EndStats:_draw_icons(g, row, n_full)
    local img = self.killicon[row.icon]
    if not img then return end
    local n = math.floor(n_full + 0.0001)
    local w = img:getWidth()
    for k = 0, n - 1 do
        g.setColor(1, 1, 1)
        g.draw(img, LX + k * (w + ICON_GAP), 0)
    end
end

function EndStats:draw()
    if not self.active then return end
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    local scale = Layout.fit(screen_w, screen_h, DW + 8, DH + 8)
    g.push()
    g.translate((screen_w - DW * scale) / 2, (screen_h - DH * scale) / 2)
    g.scale(scale, scale)

    -- Header + phase number.
    if self.header then
        g.setColor(1, 1, 1)
        g.draw(self.header, (DW - self.header:getWidth()) / 2, 4)
        local pn = self.phase_num[math.max(1, math.min(4, self.phase))]
        if pn then
            -- after the "PHASE" word, before the right wing
            g.draw(pn, (DW + self.header:getWidth()) / 2 - 62, 4)
        end
    end

    for i, row in ipairs(self.rows) do
        local ry = ROW_Y0 + (i - 1) * ROW_DY

        local label = self:_load("label_" .. (row.kind == "ok" and "total5" or row.kind) .. ".png")
        if label then
            g.setColor(1, 1, 1)
            g.draw(label, LX, ry)
        end

        if row.badge then
            -- OK rating: the spinning badge sits just right of the "5." marker. The
            -- frames vary in width (the badge rotates), so center each on a fixed point
            -- or it wobbles.
            local frames = #self.okbadge
            if frames > 0 then
                local fi  = (math.floor(self.badge_t * BADGE_FPS) % frames) + 1
                local img = self.okbadge[fi]
                g.setColor(1, 1, 1)
                g.draw(img, LX + TEXT_DX + 16 - img:getWidth() / 2, ry - 4)
            end
        elseif not self.coop then
            -- proportional kill-icon row under the label (single player only; co-op
            -- shows two value columns instead).
            local col   = row.cols[1]
            local shown = col.value * self:_row_fill(i)
            local frac  = (row.pct and (shown / 100) or (shown / MAX_ICONS))
            g.push()
            g.translate(0, ry + ICON_Y)
            self:_draw_icons(g, row, math.min(MAX_ICONS, frac * MAX_ICONS))
            g.pop()
        end

        self:_draw_row_values(g, row, i, ry)
    end

    -- TOTAL SCORE row: label aligned to the body-text column (past the line
    -- numbers), value aligned to the readout column like the line values.
    if self.totalscore then
        g.setColor(1, 1, 1)
        g.draw(self.totalscore, LX + TEXT_DX, TOTAL_Y)
    end
    self:_draw_number(g, self:_total_score(), NUM_RX, TOTAL_Y, true)

    g.pop()
    g.setColor(1, 1, 1)
end

return EndStats
