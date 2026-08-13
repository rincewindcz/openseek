local Class  = require "engine.core.class"
local Assets = require "engine.core.assets"
local Config = require "engine.core.config"
local Layout = require "engine.ui.layout"

-- End-of-phase DESTRUCTION STATS screen. Drawn over the dimmed game once the
-- chopper lands home: a header (PHASE n / DESTRUCTION STATS), five tallied
-- lines (ground forces %, buildings %, choppers shot down, rescues, an OK
-- rating), and a running TOTAL SCORE. Each line counts toward (or, emulating
-- the original, down from) its value while the bonus folds into the score; a
-- row of kill icons tracks the live value proportionally. See export_phend.py.
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

local LINE_TIME    = 0.7  -- seconds to tally one line
local LINE_STAGGER = 0.45 -- gap between successive lines starting
local CLOSE_SPEED  = 1.6  -- reverse-tally rate on close, relative to the count-up
local BADGE_FPS    = 18

-- Bonus points folded into TOTAL SCORE per line unit.
local PTS = { ground = 10, buildings = 10, choppers = 100, rescues = 200, ok = 250 }

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
            if not quiet then print("endstats: missing " .. path) end
            self._img[path] = false
        end
    end
    return self._img[path] or nil
end

-- lifecycle

-- Build the per-line tally columns from one participant's figures. A single
-- player yields one (gold) column; co-op yields one tinted column per player.
-- A participant: { player, color, ground={killed,total}, buildings={killed,total},
-- choppers, rescues }.
local function participant_cols(p)
    local function pct(c) return (c and c.total and c.total > 0) and (c.killed / c.total * 100) or 0 end
    local ground   = math.floor(pct(p.ground) + 0.5)
    local build    = math.floor(pct(p.buildings) + 0.5)
    local choppers = p.choppers or 0
    local rescues  = p.rescues  or 0
    -- Provisional OK rating: one point per fully cleared objective category.
    local ok = 0
    if p.ground and p.ground.total > 0 and ground >= 100 then ok = ok + 1 end
    if p.buildings and p.buildings.total > 0 and build >= 100 then ok = ok + 1 end
    if choppers > 0 then ok = ok + 1 end
    if rescues > 0 then ok = ok + 1 end
    return {
        ground    = { value = ground,   bonus = ground * PTS.ground },
        buildings = { value = build,    bonus = build  * PTS.buildings },
        choppers  = { value = choppers, bonus = choppers * PTS.choppers },
        rescues   = { value = rescues,  bonus = rescues * PTS.rescues },
        ok        = { value = ok,       bonus = ok * PTS.ok },
    }
end

-- stats: { phase, participants = { {player, color, ground, buildings, choppers,
-- rescues}, ... } } (one participant single player, two in co-op).
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

    self.phase       = stats.phase or 1
    self.t           = 0
    self.badge_t     = 0
    self.active      = true
    self.closing     = false
    self.applied     = false
    -- Time for the last line to finish counting up (all lines full). The reverse
    -- close starts from here so it begins winding down at once, with no dead zone.
    self._tally_time = math.max(0, #self.rows - 1) * LINE_STAGGER + LINE_TIME
    self._total_time = self._tally_time + LINE_STAGGER + 0.6
end

function EndStats:is_active() return self.active end

-- progress 0..1 of row i (1-based), eased.
function EndStats:_row_prog(i)
    local start = (i - 1) * LINE_STAGGER
    local p = (self.t - start) / LINE_TIME
    if p <= 0 then return 0 end
    if p >= 1 then return 1 end
    return p * p * (3 - 2 * p)   -- smoothstep
end

function EndStats:update(dt)
    if not self.active then return end
    self.badge_t = self.badge_t + dt
    if self.closing then
        -- Reverse tally on close: wind every line (and the total) back down toward
        -- zero, the mirror of the count-up, then drop the screen. The score was
        -- already banked by _apply_final when the tally settled, so this is purely
        -- cosmetic. A bit quicker than the count-up so the close does not drag.
        self.t = self.t - dt * CLOSE_SPEED
        if self.t <= 0 then
            self.t      = 0
            self.active = false
        end
        return
    end
    self.t = self.t + dt
    if not self.applied and self.t >= self._total_time then
        self:_apply_final()
    end
end

function EndStats:_total_score()
    local s = self.base_score
    for i, row in ipairs(self.rows) do
        local prog = self:_row_prog(i)
        for _, col in ipairs(row.cols) do
            s = s + math.floor(col.bonus * prog + 0.5)
        end
    end
    return s
end

-- Fold each player's earned bonus into their own score (co-op keeps the two
-- scores separate); idempotent.
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
            p.player.score = p._base + bonus
        end
    end
end

-- Advance the screen a step: snap the tally to complete, then start the reverse
-- count-down close, then (an impatient press mid-close) finish it at once. The
-- screen only goes inactive once the close animation reaches zero (or here on the
-- skip); the scene watches is_active() to know when to hand off.
function EndStats:keypressed()
    if not self.active then return false end
    if self.closing then return true end   -- close is animating; let it play out
    if self.t < self._tally_time then
        self.t = self._tally_time   -- first press snaps the count-up to completion
        return true
    end
    -- Tally settled: bank the score, then run the reverse count-down close from a
    -- full board (clamp away the settle pause so it starts winding down at once).
    self:_apply_final()
    self.t       = self._tally_time
    self.closing = true
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
    local prog = self:_row_prog(i)
    for j, col in ipairs(row.cols) do
        local shown = Config.endstats_count_up and (col.value * prog)
            or (col.value * (1 - prog))
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
            local prog  = self:_row_prog(i)
            local shown = Config.endstats_count_up and (col.value * prog) or (col.value * (1 - prog))
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
