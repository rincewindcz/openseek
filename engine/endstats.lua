local Class  = require "engine.class"
local Config = require "engine.config"

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
local DW, DH = 320, 240

local LX        = 16      -- label left edge
local NUM_RX    = 258     -- number readout right edge (digits end here)
local ROW_Y0    = 72      -- first stat row baseline
local ROW_DY    = 28      -- row pitch
local ICON_Y    = 11      -- kill-icon row offset below the label
local ICON_GAP  = 2
local TOTAL_Y   = 216     -- TOTAL SCORE row
local MAX_ICONS = 10      -- 10 icons == 100% / full tally

local LINE_TIME    = 0.7  -- seconds to tally one line
local LINE_STAGGER = 0.45 -- gap between successive lines starting
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
    local ok, img = pcall(love.graphics.newImage, "assets/" .. path)
    if ok then
      img:setFilter("nearest", "nearest")
      self._img[path] = img
    else
      if not quiet then print("endstats: missing " .. path) end
      self._img[path] = false
    end
  end
  return self._img[path] or nil
end

-- ── lifecycle ──────────────────────────────────────────────────────────────

-- stats: { phase, ground={killed,total}, buildings={killed,total},
--          choppers, rescues, base_score, player }
function EndStats:start(stats)
  local function pct(c) return (c and c.total and c.total > 0) and (c.killed / c.total * 100) or 0 end
  local ground = pct(stats.ground)
  local build  = pct(stats.buildings)
  local choppers = stats.choppers or 0
  local rescues  = stats.rescues  or 0
  -- Provisional OK rating: one point per fully cleared objective category.
  local ok = 0
  if stats.ground and stats.ground.total > 0 and ground >= 100 then ok = ok + 1 end
  if stats.buildings and stats.buildings.total > 0 and build >= 100 then ok = ok + 1 end
  if choppers > 0 then ok = ok + 1 end
  if rescues > 0 then ok = ok + 1 end

  self.rows = {
    { kind = "ground",   value = math.floor(ground + 0.5), pct = true, icon = 0,
      bonus = math.floor(ground + 0.5) * PTS.ground },
    { kind = "buildings",value = math.floor(build + 0.5),  pct = true, icon = 1,
      bonus = math.floor(build + 0.5) * PTS.buildings },
    { kind = "choppers", value = choppers, icon = 2, bonus = choppers * PTS.choppers },
    { kind = "rescues",  value = rescues,  icon = 3, bonus = rescues * PTS.rescues },
    { kind = "ok",       value = ok, badge = true, bonus = ok * PTS.ok },
  }
  self.phase      = stats.phase or 1
  self.base_score = stats.base_score or 0
  self.player     = stats.player
  self.t          = 0
  self.badge_t    = 0
  self.active     = true
  self.applied    = false
  self._total_time = #self.rows * LINE_STAGGER + LINE_TIME + 0.6
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
  self.t = self.t + dt
  self.badge_t = self.badge_t + dt
  if not self.applied and self.t >= self._total_time then
    self.applied = true
    if self.player then self.player.score = self:_total_score() end
  end
end

function EndStats:_total_score()
  local s = self.base_score
  for i, row in ipairs(self.rows) do
    s = s + math.floor(row.bonus * self:_row_prog(i) + 0.5)
  end
  return s
end

-- Dismiss the screen (any key after the tally settles, or Esc at any time).
function EndStats:keypressed()
  if not self.active then return false end
  if self.t < self._total_time then
    self.t = self._total_time   -- first press snaps the tally to completion
    return true
  end
  self.active = false
  if self.player and not self.applied then self.player.score = self:_total_score() end
  return true
end

-- ── draw ─────────────────────────────────────────────────────────────────────

-- Right-align a number's digits so the readout ends at design x = rx.
function EndStats:_draw_number(g, value, rx, ty, gold)
  local base = gold and 10 or 0
  local str  = tostring(math.max(0, math.floor(value + 0.5)))
  local x    = rx
  for i = #str, 1, -1 do
    local d   = base + tonumber(str:sub(i, i))
    local img = self.digit[d]
    if img then
      x = x - img:getWidth()
      g.setColor(1, 1, 1)
      g.draw(img, x, ty)
      x = x - 1
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
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 0, 0, sw, sh)

  local sc = math.min(sw / (DW + 8), sh / (DH + 8))
  g.push()
  g.translate((sw - DW * sc) / 2, (sh - DH * sc) / 2)
  g.scale(sc, sc)

  -- Header + phase number.
  if self.header then
    g.setColor(1, 1, 1)
    g.draw(self.header, (DW - self.header:getWidth()) / 2, 4)
    local pn = self.phase_num[math.max(1, math.min(4, self.phase))]
    if pn then
      -- after the "PHASE" word, before the right wing
      g.draw(pn, (DW + self.header:getWidth()) / 2 - 76, 6)
    end
  end

  for i, row in ipairs(self.rows) do
    local ry   = ROW_Y0 + (i - 1) * ROW_DY
    local prog = self:_row_prog(i)
    local shown = Config.endstats_count_up and (row.value * prog)
      or (row.value * (1 - prog))

    local label = self:_load("label_" .. (row.kind == "ok" and "total5" or row.kind) .. ".png")
    if label then
      g.setColor(1, 1, 1)
      g.draw(label, LX, ry)
    end

    if row.badge then
      -- OK rating: the spinning badge sits just right of the "5." marker.
      local frames = #self.okbadge
      if frames > 0 then
        local fi = (math.floor(self.badge_t * BADGE_FPS) % frames) + 1
        g.setColor(1, 1, 1)
        g.draw(self.okbadge[fi], LX + 22, ry - 4)
      end
    else
      -- proportional kill-icon row under the label
      local frac = (row.pct and (shown / 100) or (shown / MAX_ICONS))
      local n    = math.min(MAX_ICONS, frac * MAX_ICONS)
      g.push()
      g.translate(0, ry + ICON_Y)
      self:_draw_icons(g, row, n)
      g.pop()
    end

    self:_draw_number(g, shown, NUM_RX, ry, true)
    if row.pct and self.pct then
      g.setColor(1, 1, 1)
      g.draw(self.pct, NUM_RX + 3, ry)
    end
  end

  -- TOTAL SCORE row.
  if self.totalscore then
    g.setColor(1, 1, 1)
    g.draw(self.totalscore, LX + 78, TOTAL_Y)
  end
  self:_draw_number(g, self:_total_score(), DW - 12, TOTAL_Y, true)

  g.pop()
  g.setColor(1, 1, 1)
end

return EndStats
