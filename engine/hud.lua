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

-- Radar entity color by kind_name (matches original game's color coding).
local RADAR_COLOR = {
  structure     = { 0.55, 0.35, 0.10 },   -- brown: buildings
  flak_turret   = { 1.0,  0.2,  0.2  },   -- red: enemies
  tree          = { 0.2,  0.55, 0.15 },   -- green: trees/foliage
  scenery       = { 0.45, 0.45, 0.45 },   -- grey: scenery
  ground_decal  = { 0,    0,    0, 0  },   -- invisible
}
local RADAR_DEFAULT = { 0.9, 0.3, 0.3 }   -- red default for unknowns

function Hud:init()
  self.player = nil
  self.world  = nil
  self.items  = {}
  self._cache = {}   -- path -> Image|false
end

function Hud:load(path)
  local raw = love.filesystem.read(path)
  if not raw then error("hud: missing " .. path) end
  local def   = json.decode(raw)
  self.items  = def.items or {}
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
    local ax, ay = fn and fn(sw, sh) or 0, 0
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

-- ── gauge (armour / fuel) ────────────────────────────────────────────────────

function Hud:_gauge_frame_index(item)
  local p   = self.player
  local val = item.value
  local pct
  if     val == "armor" then pct = p.max_armor > 0 and p.armor / p.max_armor or 0
  elseif val == "fuel"  then pct = p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 0
  else                       pct = 0
  end
  pct = math.max(0, math.min(1, pct))
  -- frame 0 = empty, frame (count-1) = full
  return math.floor(pct * (item.sprite_count - 1) + 0.5) + 1
end

function Hud:_draw_gauge(g, item, x, y)
  if not item._frames then return end
  local fi  = self:_gauge_frame_index(item)
  local img = item._frames[fi]
  if img then
    g.setColor(1, 1, 1)
    g.draw(img, x, y)
  end
end

-- ── weapon icon ──────────────────────────────────────────────────────────────

function Hud:_draw_weapon(g, item, x, y)
  if not item._frames then return end
  local p   = self.player
  local fi  = math.max(1, math.min(#item._frames, (p.weapon_idx or 0) + 1))
  local img = item._frames[fi]
  if img then
    g.setColor(1, 1, 1)
    g.draw(img, x, y)
  end
end

-- ── movement cursor ───────────────────────────────────────────────────────────
-- A square box with a dot showing current speed (vertical) and strafe (horizontal).

function Hud:_draw_cursor(g, item, x, y)
  local p    = self.player
  local size = item.size or 60
  local half = size / 2

  g.setColor(0, 0, 0, 0.75)
  g.rectangle("fill", x, y, size, size)
  g.setColor(0.2, 0.45, 0.2, 0.85)
  g.rectangle("line", x, y, size, size)

  -- crosshair
  g.setColor(0.15, 0.3, 0.15, 0.7)
  g.line(x + half, y + 4,      x + half, y + size - 4)
  g.line(x + 4,    y + half,   x + size - 4, y + half)

  -- dot
  local max_s = p.MAX_FWD    or 180
  local max_r = p.STRAFE_SPEED or 100
  local dx    = (p.strafe or 0) / max_r * (half - 6)
  local dy    = -(p.speed  or 0) / max_s * (half - 6)  -- up = forward
  local dot_x = x + half + dx
  local dot_y = y + half + dy

  if p.land_state == "airborne" or p.land_state == "taking_off" then
    g.setColor(0.1, 1.0, 0.15)
  else
    g.setColor(0.85, 0.75, 0.1)
  end
  g.circle("fill", dot_x, dot_y, 4)
  g.setColor(0, 0, 0, 0.5)
  g.circle("line", dot_x, dot_y, 4)
end

-- ── radar ────────────────────────────────────────────────────────────────────

function Hud:_draw_radar(g, item, x, y)
  local p     = self.player
  local r     = item.radius    or 88
  local range = item.world_range or 900
  local cx, cy = x + r, y + r
  local scale  = r / range

  -- background
  if item._bg then
    g.setColor(1, 1, 1)
    g.draw(item._bg, x, y)
  else
    g.setColor(0, 0.04, 0, 0.92)
    g.circle("fill", cx, cy, r)
    g.setColor(0.1, 0.5, 0.1)
    g.setLineWidth(2)
    g.circle("line", cx, cy, r)
    g.setLineWidth(1)
  end

  if not self.world then return end

  -- entity dots rotated to match player heading (north = up on radar)
  local pa      = -(p.angle * math.pi / 180)
  local cos_pa  = math.cos(pa)
  local sin_pa  = math.sin(pa)
  local classes = self.world.stage.classes

  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then
      local dx = (e.x - p.x) * scale
      local dy = (e.y - p.y) * scale
      local rx  = dx * cos_pa - dy * sin_pa
      local ry  = dx * sin_pa + dy * cos_pa
      if rx * rx + ry * ry <= r * r then
        local cls = classes[e.class_idx + 1]
        local c   = RADAR_COLOR[cls.kind_name] or RADAR_DEFAULT
        if c[4] ~= 0 then   -- skip invisible kinds
          g.setColor(c[1], c[2], c[3], 0.9)
          g.rectangle("fill", cx + rx - 1.5, cy + ry - 1.5, 3, 3)
        end
      end
    end
  end

  -- player dot
  g.setColor(1, 1, 1)
  g.circle("fill", cx, cy, 2.5)
end

return Hud
