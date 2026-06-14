local Class = require "engine.class"
local json  = require "lib.json"

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

function Hud:_preload_item(item)
  if item.sprite_pattern and item.sprite_count then
    item._frames = {}
    for i = 0, item.sprite_count - 1 do
      item._frames[i + 1] = self:_img(string.format(item.sprite_pattern, i))
    end
  end
  if item.background then
    item._bg = self:_img(item.background)
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
  for _, item in ipairs(self.items) do
    local fn     = ANCHOR[item.anchor or "top_left"]
    local ax, ay = fn(sw, sh)
    local ox     = item.offset and item.offset[1] or 0
    local oy     = item.offset and item.offset[2] or 0
    local x, y   = ax + ox, ay + oy
    local t      = item.type
    if     t == "gauge"  then self:_draw_gauge(g, item, x, y)
    elseif t == "weapon" then self:_draw_weapon(g, item, x, y)
    elseif t == "cursor" then self:_draw_cursor(g, item, x, y)
    elseif t == "radar"  then self:_draw_radar(g, item, x, y)
    end
  end
  g.setColor(1, 1, 1)
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
  return math.floor(pct * (item.sprite_count - 1) + 0.5) + 1
end

function Hud:_gauge_pct(item)
  local p = self.player
  if     item.value == "armor" then return p.max_armor > 0 and p.armor / p.max_armor or 0
  elseif item.value == "fuel"  then return p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 0
  end
  return 0
end

function Hud:_draw_gauge(g, item, x, y)
  if not item._frames then return end
  local s   = item.scale or 1
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

function Hud:_draw_weapon(g, item, x, y)
  if not item._frames then return end
  local s   = item.scale or 1
  local p   = self.player
  local fi  = math.max(1, math.min(#item._frames, (p.weapon_icon or 0) + 1))
  local img = item._frames[fi]
  if img then
    g.setColor(1, 1, 1)
    g.draw(img, x, y, 0, s, s)
  end
end

-- ── movement cursor ───────────────────────────────────────────────────────────

function Hud:_draw_cursor(g, item, x, y)
  local p     = self.player
  local s     = item.scale or 1
  local size  = (item.size or 36) * s
  local half  = size / 2
  local wall  = math.max(2, math.floor(size / 8))

  -- thick black border, transparent interior
  g.setColor(0, 0, 0, 1.0)
  g.setLineWidth(wall)
  g.rectangle("line", x + wall/2, y + wall/2, size - wall, size - wall)
  g.setLineWidth(1)

  -- large green square dot
  local max_s  = p.max_fwd      or 260
  local max_r  = p.strafe_speed or 140
  local inner  = half - wall - 3*s
  local dx     = (p.strafe or 0) / max_r * inner
  local dy     = -(p.speed or 0) / max_s * inner
  local dot_sz = math.max(3, math.floor(size / 7))
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

function Hud:_draw_radar(g, item, x, y)
  local p     = self.player
  local s     = item.scale or 1
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

  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then
      local cls  = classes[e.class_idx + 1]
      local kind = cls.kind_name
      -- Objective targets / POW zones override the kind color with a white dot
      -- (same size as the others) so the mission goal stands out on the scanner.
      local c
      if     e.objective          then c = RADAR_COLOR_OBJECTIVE
      elseif RADAR_ENEMY[kind]    then c = RADAR_COLOR_ENEMY
      elseif RADAR_BUILDING[kind] then c = RADAR_COLOR_BUILDING
      end
      if c then
        local dx = (e.x - p.x) * px_per_unit
        local dy = (e.y - p.y) * px_per_unit
        local rx = dx * cos_pa - dy * sin_pa
        local ry = dx * sin_pa + dy * cos_pa
        if rx * rx + ry * ry <= r * r then
          g.setColor(c[1], c[2], c[3], 0.95)
          g.rectangle("fill", cx + rx - dot_r, cy + ry - dot_r, dot_r*2, dot_r*2)
        end
      end
    end
  end

  -- Co-op teammate (split screen): a larger dot in the teammate's color.
  local mate = self.coplayer
  if mate and (mate.armor or 0) > 0 and not mate.death then
    local dx = (mate.x - p.x) * px_per_unit
    local dy = (mate.y - p.y) * px_per_unit
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
