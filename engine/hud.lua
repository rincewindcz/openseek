local Class  = require "engine.class"
local json   = require "lib.json"
local Config = require "engine.config"
local Font   = require "engine.font"

local Hud = Class()

local ANCHOR = {
  top_left      = function(w, h) return 0,   0   end,
  top_right     = function(w, h) return w,   0   end,
  top_center    = function(w, h) return w/2, 0   end,
  bottom_left   = function(w, h) return 0,   h   end,
  bottom_right  = function(w, h) return w,   h   end,
  bottom_center = function(w, h) return w/2, h   end,
  center        = function(w, h) return w/2, h/2 end,
}

local RADAR_ENEMY = {
  flak_turret        = true,
  tank               = true,
  enemy_helicopter   = true,
  truck              = true,
  soldier            = true,
  soldier_aggressive = true,
}
local RADAR_BUILDING = {
  structure = true,
  radar     = true,
}
local RADAR_COLOR_ENEMY     = { 1.0, 0.15, 0.15 }
local RADAR_COLOR_BUILDING  = { 0.33, 0.18, 0.07 }
local RADAR_COLOR_OBJECTIVE = { 1.0, 1.0, 1.0 }
local RADAR_COLOR_AIR       = { 1.0, 0.4, 0.8 }   -- enemy helicopters (pinkish)

function Hud:init()
  self.player = nil
  self.world  = nil
  self.items  = {}
  self._cache = {}
end

function Hud:load(path)
  local raw = love.filesystem.read(path)
  if not raw then error("hud: missing " .. path) end
  local def  = json.decode(raw)
  self.items = def.items or {}
  for _, item in ipairs(self.items) do
    self:_preload_item(item)
  end
end

-- Load an item's frames/background, optionally from a per-mission override dir
-- (prefix, e.g. "hud/stage3/"). An item draws entirely from one source: if the
-- override has it (frame 0 / the background exists) every frame comes from there,
-- otherwise the shared "hud/" set. Frames are counted until the first gap, so an
-- override with a different frame count (mission 3 weapons has 19 vs 14) works.
function Hud:_preload_item(item, prefix)
  local function over(path)
    if not prefix then return path end
    local o = path:gsub("^hud/", prefix)
    return love.filesystem.getInfo("assets/" .. o) and o or path
  end

  if item.sprite_pattern then
    item._frames = {}
    local override = over(string.format(item.sprite_pattern, 0)) ~= string.format(item.sprite_pattern, 0)
    local i = 0
    while true do
      local p = string.format(item.sprite_pattern, i)
      if override then p = p:gsub("^hud/", prefix) end
      if not love.filesystem.getInfo("assets/" .. p) then break end
      item._frames[i + 1] = self:_img(p)
      i = i + 1
    end
  end
  if item.background then
    item._bg = self:_img(over(item.background))
  end
end

-- Switch HUD art to mission m's overrides (assets/hud/stage{m}/) where present,
-- per item, falling back to the shared set. Called on each stage load.
function Hud:set_mission(m)
  local prefix = "hud/stage" .. tostring(m) .. "/"
  for _, item in ipairs(self.items) do
    self:_preload_item(item, prefix)
  end
end

function Hud:_img(path)
  if self._cache[path] == nil then
    local ok, img = pcall(love.graphics.newImage, "assets/" .. path)
    if ok then
      img:setFilter("nearest", "nearest")
      self._cache[path] = img
    else
      print("hud: missing asset " .. path)
      self._cache[path] = false
    end
  end
  return self._cache[path] or nil
end

-- ── draw ─────────────────────────────────────────────────────────────────────

function Hud:draw()
  if not self.player then return end
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  if self.view_w then sw, sh = self.view_w, self.view_h end
  -- The global HUD scale grows each element and its inset from the anchored edge
  -- together, so a corner-anchored item stays in its corner as it gets bigger.
  local hs = Config.hud_scale or 1
  for _, item in ipairs(self.items) do
    local fn     = ANCHOR[item.anchor or "top_left"]
    local ax, ay = fn(sw, sh)
    local ox     = (item.offset and item.offset[1] or 0) * hs
    local oy     = (item.offset and item.offset[2] or 0) * hs
    local x, y   = ax + ox, ay + oy
    local s      = (item.scale or 1) * hs
    local t      = item.type
    if     t == "gauge"  then self:_draw_gauge(g, item, x, y, s)
    elseif t == "weapon" then self:_draw_weapon(g, item, x, y, s)
    elseif t == "cursor" then self:_draw_cursor(g, item, x, y, s)
    elseif t == "radar"  then self:_draw_radar(g, item, x, y, s)
    elseif t == "number" then self:_draw_number(g, item, x, y, s)
    end
  end
  self:_draw_overkill(g, sw, sh, hs)
  g.setColor(1, 1, 1)
end

-- ── numbers (score / lives / pows / ammo) ─────────────────────────────────────
-- A bitmap-font counter (ENDCHARS digits), optionally prefixed by a marker
-- sprite. value -> player field; ammo reads the current weapon's count (nil =
-- infinite, hidden). hide_when_zero hides the whole item at 0 (POW count).

function Hud:_number_value(item)
  local p = self.player
  local v = item.value
  if     v == "score" then return p.score or 0
  elseif v == "lives" then return p.lives or 0
  elseif v == "pows"  then return p.pows  or 0
  elseif v == "ammo"  then return p.ammo[p.weapon_name]   -- nil => infinite
  end
  return nil
end

function Hud:_draw_number(g, item, x, y, s)
  local val = self:_number_value(item)
  if val == nil then return end
  if item.hide_when_zero and val <= 0 then return end
  local digits = item.digits or 1
  local cap    = 10 ^ digits - 1
  local str    = string.format("%0" .. digits .. "d", math.max(0, math.min(val, cap)))

  local px = x
  if item.icon then
    local img = self:_img(item.icon)
    if img then
      g.setColor(1, 1, 1)
      g.draw(img, x, y + (item.icon_dy or 0) * s, 0, s, s)
      px = x + img:getWidth() * s + (item.gap or 2) * s
    end
  end
  Font.get(item.font or "endchars"):print(str, px, y + (item.text_dy or 0) * s,
    { scale = s, color = item.color or { 1, 1, 1 } })
end

-- Blinking OVERKILL banner during a kill streak (Player:register_kill).
function Hud:_draw_overkill(g, sw, sh, hs)
  local p = self.player
  if not (p.overkill_active and p:overkill_active()) then return end
  if math.floor(love.timer.getTime() * 12) % 2 ~= 0 then return end
  local font = Font.get("overkill")
  local s    = 4 * hs
  local w    = font:word_width(s)
  font:print_word((sw - w) / 2, sh * 0.28, { scale = s })
end

-- ── gauge ─────────────────────────────────────────────────────────────────────

function Hud:_gauge_frame_index(item)
  local p   = self.player
  local val = item.value
  local pct
  if     val == "armor" then pct = p.max_armor > 0 and p.armor / p.max_armor or 0
  elseif val == "fuel"  then pct = p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 0
  else                       pct = 0
  end
  pct = math.max(0, math.min(1, pct))
  local n = item._frames and #item._frames or 0
  if n == 0 then return 1 end
  return math.floor(pct * (n - 1) + 0.5) + 1
end

function Hud:_gauge_pct(item)
  local p = self.player
  if     item.value == "armor" then return p.max_armor > 0 and p.armor / p.max_armor or 0
  elseif item.value == "fuel"  then return p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 0
  end
  return 0
end

function Hud:_draw_gauge(g, item, x, y, s)
  if not item._frames then return end
  -- Low gauges (< 25%) blink to warn the player.
  if self:_gauge_pct(item) < 0.25 and (math.floor(love.timer.getTime() * 4) % 2 == 0) then
    return
  end
  local fi  = self:_gauge_frame_index(item)
  local img = item._frames[fi]
  if img then
    g.setColor(1, 1, 1)
    g.draw(img, x, y, 0, s, s)
  end
end

-- ── weapon icon ───────────────────────────────────────────────────────────────

function Hud:_draw_weapon(g, item, x, y, s)
  if not item._frames then return end
  local p   = self.player
  local fi  = math.max(1, math.min(#item._frames, (p.weapon_icon or 0) + 1))
  local img = item._frames[fi]
  if img then
    g.setColor(1, 1, 1)
    g.draw(img, x, y, 0, s, s)
  end
end

-- ── movement cursor ───────────────────────────────────────────────────────────

function Hud:_draw_cursor(g, item, x, y, s)
  local p     = self.player
  local size, half, inner, dot_sz

  -- Original game art (DATA/BOX.BIN, per-mission override under hud/stage{m}/)
  -- when present; otherwise the engine-drawn black frame.
  if item._bg then
    local bw, bh = item._bg:getWidth(), item._bg:getHeight()
    size   = bw * s
    half   = size / 2
    inner  = half - 3 * s
    dot_sz = math.max(3, math.floor(bw / 6) * s)
    g.setColor(1, 1, 1)
    g.draw(item._bg, x, y, 0, s, s)
  else
    size = (item.size or 36) * s
    half = size / 2
    local wall = math.max(2, math.floor(size / 8))
    g.setColor(0, 0, 0, 1.0)
    g.setLineWidth(wall)
    g.rectangle("line", x + wall/2, y + wall/2, size - wall, size - wall)
    g.setLineWidth(1)
    inner  = half - wall - 3 * s
    dot_sz = math.max(3, math.floor(size / 7))
  end

  -- Green dot: forward/back maps to Y, strafe to X, plus a lateral push from
  -- turning. A sustained turn drives the dot all the way to the box edge (and to
  -- the corner together with forward motion), like the original.
  local max_s  = p.max_fwd      or 260
  local max_r  = p.strafe_speed or 140
  local fx     = math.max(-1, math.min(1, (p.strafe or 0) / max_r + (p.turn_cursor or 0)))
  local dx     = fx * inner
  local dy     = -(p.speed or 0) / max_s * inner
  local dot_x  = x + half + dx - dot_sz / 2
  local dot_y  = y + half + dy - dot_sz / 2

  if p.land_state == "airborne" or p.land_state == "taking_off" then
    g.setColor(0.1, 1.0, 0.15, 1.0)
  else
    g.setColor(0.85, 0.75, 0.1, 1.0)
  end
  g.rectangle("fill", dot_x, dot_y, dot_sz, dot_sz)
end

-- ── radar ─────────────────────────────────────────────────────────────────────

function Hud:_draw_radar(g, item, x, y, s)
  local p     = self.player
  local r     = (item.radius or 88) * s
  local range = item.world_range or 900

  -- center: middle of the (scaled) background image
  local cx, cy
  if item._bg then
    local bw = item._bg:getWidth()  * s
    local bh = item._bg:getHeight() * s
    cx = x + bw / 2
    cy = y + bh / 2
    g.setColor(1, 1, 1)
    g.draw(item._bg, x, y, 0, s, s)
  else
    cx = x + r
    cy = y + r
    g.setColor(0, 0.04, 0, 0.92)
    g.circle("fill", cx, cy, r)
    g.setColor(0.1, 0.5, 0.1)
    g.setLineWidth(2)
    g.circle("line", cx, cy, r)
    g.setLineWidth(1)
  end

  if not self.world then return end

  local pa      = -(p.angle * math.pi / 180)
  local cos_pa  = math.cos(pa)
  local sin_pa  = math.sin(pa)
  local px_per_unit = r / range
  local classes = self.world.stage.classes
  local dot_r   = math.max(0.8, s * 0.8)

  -- Bucket blips by priority and draw low-to-high so the mission goal is never
  -- hidden under a building/enemy dot: buildings (brown) first, enemies (red)
  -- next, objectives (white) last on top.
  local buildings, enemies, objectives, air = {}, {}, {}, {}

  local function plot(bucket, ex, ey)
    local wdx, wdy = self.world:delta(ex, ey, p.x, p.y)
    local dx = wdx * px_per_unit
    local dy = wdy * px_per_unit
    local rx = dx * cos_pa - dy * sin_pa
    local ry = dx * sin_pa + dy * cos_pa
    if rx * rx + ry * ry <= r * r then bucket[#bucket + 1] = { rx, ry } end
  end
  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then
      local cls  = classes[e.class_idx + 1]
      local kind = cls.kind_name
      local bucket
      if     e.objective          then bucket = objectives
      elseif RADAR_ENEMY[kind]    then bucket = enemies
      elseif RADAR_BUILDING[kind] then bucket = buildings
      end
      if bucket then plot(bucket, e.x, e.y) end
    end
  end

  -- Airborne enemy helicopters live outside world.entities (heli system).
  for _, h in ipairs(self.world.air_units or {}) do
    if h.state == "alive" then plot(air, h.x, h.y) end
  end

  local function draw_blips(blips, c)
    g.setColor(c[1], c[2], c[3], 0.95)
    for _, b in ipairs(blips) do
      g.rectangle("fill", cx + b[1] - dot_r, cy + b[2] - dot_r, dot_r * 2, dot_r * 2)
    end
  end
  draw_blips(buildings,  RADAR_COLOR_BUILDING)
  draw_blips(enemies,    RADAR_COLOR_ENEMY)
  draw_blips(air,        RADAR_COLOR_AIR)
  draw_blips(objectives, RADAR_COLOR_OBJECTIVE)

  -- Co-op teammate (split screen): a larger dot in the teammate's color.
  local mate = self.coplayer
  if mate and (mate.armor or 0) > 0 and not mate.death then
    local wdx, wdy = self.world:delta(mate.x, mate.y, p.x, p.y)
    local dx = wdx * px_per_unit
    local dy = wdy * px_per_unit
    local rx = dx * cos_pa - dy * sin_pa
    local ry = dx * sin_pa + dy * cos_pa
    if rx * rx + ry * ry <= r * r then
      local col = self.coplayer_color or { 1, 1, 1 }
      g.setColor(col[1], col[2], col[3], 1)
      g.rectangle("fill", cx + rx - dot_r, cy + ry - dot_r, dot_r * 2, dot_r * 2)
    end
  end
end

return Hud
