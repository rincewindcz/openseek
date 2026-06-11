local Class = require "engine.class"

local ZOOMS = { 0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8 }

local Camera = Class()

function Camera:init(world_size)
  self.world_size = world_size or 4096
  self.x  = self.world_size / 2
  self.y  = self.world_size / 2
  self.zi = 4  -- index into ZOOMS; default 1x
end

function Camera:zoom()
  return ZOOMS[self.zi]
end

function Camera:set_zoom(zi, mx, my)
  zi = math.max(1, math.min(#ZOOMS, zi))
  if zi == self.zi then return end
  local w, h = love.graphics.getDimensions()
  mx = mx or w / 2
  my = my or h / 2
  local old_z = self:zoom()
  local wx = self.x + (mx - w / 2) / old_z
  local wy = self.y + (my - h / 2) / old_z
  self.zi = zi
  local new_z = self:zoom()
  self.x = wx - (mx - w / 2) / new_z
  self.y = wy - (my - h / 2) / new_z
  self:clamp()
end

function Camera:clamp()
  self.x = math.max(0, math.min(self.world_size, self.x))
  self.y = math.max(0, math.min(self.world_size, self.y))
end

function Camera:update(dt)
  local speed = 600 / self:zoom() * dt
  local kb = love.keyboard.isDown
  if kb("a") or kb("left")  then self.x = self.x - speed end
  if kb("d") or kb("right") then self.x = self.x + speed end
  if kb("w") or kb("up")    then self.y = self.y - speed end
  if kb("s") or kb("down")  then self.y = self.y + speed end
  self:clamp()
end

function Camera:on_wheel(dy)
  local mx, my = love.mouse.getPosition()
  self:set_zoom(self.zi + (dy > 0 and 1 or -1), mx, my)
end

-- Apply the camera transform (call inside love.draw after love.graphics.push).
function Camera:apply()
  local w, h = love.graphics.getDimensions()
  love.graphics.translate(w / 2, h / 2)
  love.graphics.scale(self:zoom())
  love.graphics.translate(-self.x, -self.y)
end

-- Viewport in world coordinates (with margin).
function Camera:viewport(margin)
  margin = margin or 64
  local w, h = love.graphics.getDimensions()
  local z = self:zoom()
  return {
    x0 = self.x - w / 2 / z - margin,
    x1 = self.x + w / 2 / z + margin,
    y0 = self.y - h / 2 / z - margin,
    y1 = self.y + h / 2 / z + margin,
  }
end

return Camera
