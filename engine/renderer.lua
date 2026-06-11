local Class = require "engine.class"

local Renderer = Class()

function Renderer:init(world, camera)
  self.world         = world
  self.camera        = camera
  self.show_segments = true
  self.show_grid     = false
  self.picker        = false
end

function Renderer:draw()
  self:_draw_world()
  self:_draw_hud()
  if self.picker then self:_draw_picker() end
end

function Renderer:_draw_world()
  local g    = love.graphics
  local w    = self.world
  local vp   = self.camera:viewport()

  g.clear(w:ground_color())
  g.push()
  self.camera:apply()

  self:_draw_entities(w.decals, vp)

  if self.show_segments then
    g.setLineStyle("rough")
    g.setLineWidth(1)
    for _, s in ipairs(w.stage.segments) do
      g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255)
      g.line(s.x1, s.y1, s.x2, s.y2)
    end
    g.setColor(1, 1, 1)
  end

  self:_draw_entities(w.objects, vp)

  if self.show_grid then
    g.setColor(0, 0, 0, 0.2)
    g.setLineWidth(1 / self.camera:zoom())
    local ws = w.stage.world_size
    for i = 0, ws, 256 do
      g.line(i, 0, i, ws)
      g.line(0, i, ws, i)
    end
    g.setColor(1, 1, 1)
  end

  g.pop()
end

function Renderer:_draw_entities(list, vp)
  local g      = love.graphics
  local images = self.world.images
  g.setColor(1, 1, 1)
  for _, e in ipairs(list) do
    if e.x >= vp.x0 and e.x <= vp.x1 and e.y >= vp.y0 and e.y <= vp.y1 then
      local r = images[e.class + 1]
      if r then
        g.draw(r.img, e.x, e.y, r.rot, 1, 1, -r.ox, -r.oy)
      else
        g.setColor(1, 0, 1)
        g.circle("fill", e.x, e.y, 3)
        g.setColor(1, 1, 1)
      end
    end
  end
end

function Renderer:_draw_hud()
  local g = love.graphics
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 0, 0, 440, 22)
  g.setColor(1, 1, 1)
  g.print(string.format(
    "%s  cam %d,%d  zoom %gx  [Tab] stages [PgUp/PgDn] [L]ines [G]rid",
    self.world.stage_name, self.camera.x, self.camera.y, self.camera:zoom()), 4, 4)
end

function Renderer:_draw_picker()
  local g      = love.graphics
  local w, h   = g.getDimensions()
  local stages = self.world.stages
  local lh     = 28
  local bw     = 280
  local bh     = #stages * lh + 50
  local bx     = (w - bw) / 2
  local by     = (h - bh) / 2
  g.setColor(0, 0, 0, 0.85)
  g.rectangle("fill", bx, by, bw, bh, 6)
  g.setColor(1, 1, 1)
  g.print("Select stage (Enter)", bx + 16, by + 12)
  for i, name in ipairs(stages) do
    local y = by + 40 + (i - 1) * lh
    if i == self.world.stage_index then
      g.setColor(1, 1, 0)
      g.rectangle("line", bx + 10, y - 4, bw - 20, lh - 4)
    else
      g.setColor(0.8, 0.8, 0.8)
    end
    g.print(name, bx + 20, y)
  end
  g.setColor(1, 1, 1)
end

return Renderer
