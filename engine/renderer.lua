local Class = require "engine.class"

local Renderer = Class()

function Renderer:init(world, camera)
  self.world         = world
  self.camera        = camera
  self.show_segments = true
  self.show_grid     = false
  self.picker        = false      -- stage picker
  self.kind_picker   = false      -- kind visibility panel
  self.kind_index    = 1          -- cursor in kind panel
  self.hidden_kinds  = {}         -- set: kind_name -> true means hidden
  self._kinds        = {}         -- ordered list of {name, count} for the panel
end

-- Called after a stage load to rebuild the kind list.
function Renderer:refresh_kinds()
  local counts = {}
  for _, cls in ipairs(self.world.stage.classes) do
    local kn = cls.kind_name
    if kn then counts[kn] = (counts[kn] or 0) + 1 end
  end
  -- count entities per kind
  local entity_counts = {}
  for _, e in ipairs(self.world.entities) do
    local cls = self.world.stage.classes[e.class_idx + 1]
    local kn  = cls.kind_name
    if kn then entity_counts[kn] = (entity_counts[kn] or 0) + 1 end
  end
  self._kinds = {}
  for kn, _ in pairs(counts) do
    self._kinds[#self._kinds + 1] = { name = kn, count = entity_counts[kn] or 0 }
  end
  table.sort(self._kinds, function(a, b) return a.name < b.name end)
  self.kind_index = math.min(self.kind_index, math.max(1, #self._kinds))
end

function Renderer:is_kind_visible(kind_name)
  return not self.hidden_kinds[kind_name]
end

function Renderer:toggle_kind(kind_name)
  self.hidden_kinds[kind_name] = not self.hidden_kinds[kind_name] or nil
end

function Renderer:toggle_kind_picker()
  self.kind_picker = not self.kind_picker
  if self.kind_picker then
    self:refresh_kinds()
    self.picker = false  -- close stage picker if open
  end
end

function Renderer:on_kind_picker_key(key)
  local n = #self._kinds
  if n == 0 then return end
  if key == "up" then
    self.kind_index = (self.kind_index - 2) % n + 1
  elseif key == "down" then
    self.kind_index = self.kind_index % n + 1
  elseif key == "space" or key == "return" then
    self:toggle_kind(self._kinds[self.kind_index].name)
  elseif key == "backspace" then
    self.hidden_kinds = {}  -- show all
  end
end

-- ── draw ──────────────────────────────────────────────────────────────────────

function Renderer:draw()
  self:_draw_world()
  self:_draw_hud()
  if self.picker      then self:_draw_stage_picker() end
  if self.kind_picker then self:_draw_kind_picker()  end
end

function Renderer:_draw_world()
  local g  = love.graphics
  local w  = self.world
  local vp = self.camera:viewport()

  g.clear(w:ground_color())
  g.push()
  self.camera:apply()

  self:_draw_entities(w.decals,  vp)

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
  local g       = love.graphics
  local images  = self.world.images
  local classes = self.world.stage.classes
  local hidden  = self.hidden_kinds
  g.setColor(1, 1, 1)
  for _, e in ipairs(list) do
    local cls = classes[e.class_idx + 1]
    local in_vp = e.x >= vp.x0 and e.x <= vp.x1 and e.y >= vp.y0 and e.y <= vp.y1
    if not in_vp then goto continue end
    if hidden[cls.kind_name] then goto continue end

    if e.state == "exploding" and e.anim then
      local img = e.anim:current_image()
      if img then
        local iw, ih = img:getDimensions()
        g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
      end
    elseif e:is_alive() then
      local r = images[e.class_idx + 1]
      if r then
        local rot = e:draw_angle_rad(cls.angle_steps)
        g.draw(r.img, e.x, e.y, rot, 1, 1, -r.ox, -r.oy)
      else
        g.setColor(1, 0, 1)
        g.circle("fill", e.x, e.y, 3)
        g.setColor(1, 1, 1)
      end
      -- overlay animation (non-destructive: hit flash, etc.)
      if e.state == "animating" and e.anim then
        local img = e.anim:current_image()
        if img then
          local iw, ih = img:getDimensions()
          g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
        end
      end

      -- Damage smoke emitters (persistent, threshold-based)
      for _, se in ipairs(e._damage_smokes) do
        local img = se.anim:current_image()
        if img then
          local iw, ih = img:getDimensions()
          g.setColor(1, 1, 1, 0.85)
          g.draw(img, e.x + se.ox, e.y + se.oy, 0, 1, 1, iw / 2, ih / 2)
          g.setColor(1, 1, 1)
        end
      end

      -- One-shot hit smokes (SMOKE2)
      for _, hs in ipairs(e._hit_smokes) do
        local img = hs.anim:current_image()
        if img then
          local iw, ih = img:getDimensions()
          g.draw(img, e.x + hs.ox, e.y + hs.oy, 0, 1, 1, iw / 2, ih / 2)
        end
      end
    end

    ::continue::
  end
end

function Renderer:_draw_hud()
  local g = love.graphics
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 0, 0, 500, 22)
  g.setColor(1, 1, 1)

  -- count hidden kinds for the hint
  local nhidden = 0
  for _ in pairs(self.hidden_kinds) do nhidden = nhidden + 1 end
  local kind_hint = nhidden > 0
    and string.format("[K]inds (%d hidden)", nhidden)
    or  "[K]inds"

  g.print(string.format(
    "%s  cam %d,%d  zoom %gx  [Tab] [L] [G] %s",
    self.world.stage_name, self.camera.x, self.camera.y,
    self.camera:zoom(), kind_hint), 4, 4)
end

function Renderer:_draw_stage_picker()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  local stages = self.world.stages
  local lh     = 28
  local bw     = 280
  local bh     = #stages * lh + 50
  local bx     = (sw - bw) / 2
  local by     = (sh - bh) / 2
  g.setColor(0, 0, 0, 0.85)
  g.rectangle("fill", bx, by, bw, bh, 6)
  g.setColor(1, 1, 1)
  g.print("Select stage  (Enter)", bx + 16, by + 12)
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

function Renderer:_draw_kind_picker()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  local kinds  = self._kinds
  local lh     = 22
  local bw     = 320
  local bh     = #kinds * lh + 60
  local bx     = (sw - bw) / 2
  local by     = (sh - bh) / 2

  g.setColor(0, 0, 0, 0.88)
  g.rectangle("fill", bx, by, bw, bh, 6)
  g.setColor(1, 1, 1)
  g.print("Entity kinds  (Space toggle, Backspace show all)", bx + 12, by + 10)

  for i, entry in ipairs(kinds) do
    local y       = by + 36 + (i - 1) * lh
    local hidden  = self.hidden_kinds[entry.name]
    local cursor  = (i == self.kind_index)

    if cursor then
      g.setColor(1, 1, 0, 0.15)
      g.rectangle("fill", bx + 6, y - 2, bw - 12, lh - 2, 3)
      g.setColor(1, 1, 0)
      g.rectangle("line", bx + 6, y - 2, bw - 12, lh - 2, 3)
    end

    -- checkbox
    g.setColor(hidden and { 0.4, 0.4, 0.4 } or { 0.2, 0.9, 0.3 })
    g.print(hidden and "[ ]" or "[x]", bx + 12, y)

    -- kind name
    g.setColor(hidden and { 0.5, 0.5, 0.5 } or { 1, 1, 1 })
    g.print(entry.name, bx + 48, y)

    -- entity count
    g.setColor(0.5, 0.5, 0.5)
    g.print(tostring(entry.count), bx + bw - 44, y)
  end

  g.setColor(1, 1, 1)
end

return Renderer
