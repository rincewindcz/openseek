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

local RADAR_COLOR = {
  structure    = { 0.55, 0.35, 0.10 },
  flak_turret  = { 1.0,  0.2,  0.2  },
  tree         = { 0.2,  0.55, 0.15 },
  scenery      = { 0.45, 0.45, 0.45 },
  ground_decal = { 0,    0,    0,    0 },
}
local RADAR_DEFAULT = { 0.9, 0.3, 0.3 }

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

function Hud:_draw_gauge(g, item, x, y)
  if not item._frames then return end
  local s   = item.scale or 1
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
  local fi  = math.max(1, math.min(#item._frames, (p.weapon_idx or 0) + 1))
  local img = item._frames[fi]
  if img then
    g.setColor(1, 1, 1)
    g.draw(img, x, y, 0, s, s)
  end
end

-- ── movement cursor ───────────────────────────────────────────────────────────

function Hud:_draw_cursor(g, item, x, y)
  local p    = self.player
  local s    = item.scale or 1
  local size = (item.size or 60) * s
  local half = size / 2

  g.setColor(0, 0, 0, 0.75)
  g.rectangle("fill", x, y, size, size)
  g.setColor(0.2, 0.45, 0.2, 0.85)
  g.setLineWidth(s)
  g.rectangle("line", x, y, size, size)

  -- crosshair
  g.setColor(0.15, 0.3, 0.15, 0.7)
  g.line(x + half, y + 4*s,       x + half, y + size - 4*s)
  g.line(x + 4*s,  y + half,      x + size - 4*s, y + half)

  -- dot
  local max_s = p.MAX_FWD      or 180
  local max_r = p.STRAFE_SPEED or 100
  local dx    = (p.strafe or 0) / max_r * (half - 6*s)
  local dy    = -(p.speed or 0) / max_s * (half - 6*s)
  local dot_x = x + half + dx
  local dot_y = y + half + dy

  if p.land_state == "airborne" or p.land_state == "taking_off" then
    g.setColor(0.1, 1.0, 0.15)
  else
    g.setColor(0.85, 0.75, 0.1)
  end
  g.circle("fill", dot_x, dot_y, 4 * s)
  g.setColor(0, 0, 0, 0.5)
  g.circle("line", dot_x, dot_y, 4 * s)
  g.setLineWidth(1)
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
  local dot_r   = math.max(1.5, s * 1.5)

  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then
      local dx = (e.x - p.x) * px_per_unit
      local dy = (e.y - p.y) * px_per_unit
      local rx  = dx * cos_pa - dy * sin_pa
      local ry  = dx * sin_pa + dy * cos_pa
      if rx * rx + ry * ry <= r * r then
        local cls = classes[e.class_idx + 1]
        local c   = RADAR_COLOR[cls.kind_name] or RADAR_DEFAULT
        if not (c[4] == 0) then
          g.setColor(c[1], c[2], c[3], 0.9)
          g.rectangle("fill", cx + rx - dot_r, cy + ry - dot_r, dot_r*2, dot_r*2)
        end
      end
    end
  end

  g.setColor(1, 1, 1)
  g.circle("fill", cx, cy, math.max(2.5, s * 2.5))
end

return Hud
