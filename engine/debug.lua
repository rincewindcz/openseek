local Class = require "engine.class"
local json  = require "lib.json"

local Debug = Class()

local PANEL_W    = 280
local PANEL_PAD  = 10
local LINE_H     = 18
local BG         = { 0, 0, 0, 0.82 }
local COL_LABEL  = { 0.7, 0.7, 0.7, 1 }
local COL_VALUE  = { 1,   1,   1,   1 }
local COL_EDIT   = { 1,   1,   0,   1 }
local COL_KEY    = { 0.5, 0.8, 1,   1 }
local COL_HINT   = { 0.5, 0.5, 0.5, 1 }
local COL_RADIUS = { 1,   0.3, 0.3, 0.25 }
local COL_ATCK   = { 1,   0.7, 0.0, 0.25 }
local COL_ROUTE  = { 0.3, 1,   0.3, 0.7 }

-- Numeric fields of entity_types that are editable in the inspector.
local EDITABLE_FIELDS = {
  "speed", "turn_speed", "attack_range", "detection_radius", "hit_radius"
}

-- Small delta applied per keypress for each editable field.
local FIELD_STEP = {
  speed            = 5,
  turn_speed       = 5,
  attack_range     = 10,
  detection_radius = 10,
  hit_radius       = 1,
}

local function write_json(path, t)
  -- love.filesystem.write goes to the save dir; use io.open for the source tree.
  local src = love.filesystem.getSource()
  local full = src .. "/" .. path
  local lines = { "{" }
  local keys  = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for ki, k in ipairs(keys) do
    local v   = t[k]
    local sub = { "  " .. string.format("%q", k) .. ": {" }
    local fk  = {}
    for f in pairs(v) do fk[#fk + 1] = f end
    table.sort(fk)
    for fi, f in ipairs(fk) do
      local val = v[f]
      local vs
      if val == nil then
        vs = "null"
      elseif type(val) == "string" then
        vs = string.format("%q", val)
      elseif type(val) == "boolean" then
        vs = tostring(val)
      else
        vs = tostring(val)
      end
      sub[#sub + 1] = "    " .. string.format("%q", f) .. ": " .. vs ..
        (fi < #fk and "," or "")
    end
    sub[#sub + 1] = "  }" .. (ki < #keys and "," or "")
    lines[#lines + 1] = table.concat(sub, "\n")
  end
  lines[#lines + 1] = "}"
  local content = table.concat(lines, "\n") .. "\n"
  local f = io.open(full, "w")
  if f then
    f:write(content)
    f:close()
  else
    print("debug: could not write " .. full)
  end
end

function Debug:init(world, camera)
  self.world        = world
  self.camera       = camera
  self.enabled      = false
  self.hovered      = nil   -- Entity under mouse cursor
  self.selected     = nil   -- Entity selected for editing
  self.edit_field   = 1     -- index into EDITABLE_FIELDS for selected entity
  self.show_radii   = true
  self.entity_types_path = "data/entity_types.json"
end

function Debug:toggle()
  self.enabled  = not self.enabled
  self.hovered  = nil
  self.selected = nil
end

function Debug:update()
  if not self.enabled then return end
  self.hovered = self:_entity_under_mouse()
end

function Debug:keypressed(key)
  if not self.enabled then return false end

  if key == "f2" then
    self:toggle()
    return true
  end

  if not self.selected then return false end

  local td = self.selected.type_data
  if not td then return false end

  local fname = EDITABLE_FIELDS[self.edit_field]
  local step  = FIELD_STEP[fname] or 1

  if key == "up" then
    self.edit_field = (self.edit_field - 2) % #EDITABLE_FIELDS + 1
    return true
  end
  if key == "down" then
    self.edit_field = self.edit_field % #EDITABLE_FIELDS + 1
    return true
  end
  if key == "right" or key == "=" or key == "+" or key == "kp+" then
    td[fname] = (td[fname] or 0) + step
    return true
  end
  if key == "left" or key == "-" or key == "kp-" then
    td[fname] = math.max(0, (td[fname] or 0) - step)
    return true
  end
  if key == "s" then
    self:_save_entity_types()
    return true
  end
  if key == "escape" then
    self.selected = nil
    return true
  end
  return false
end

function Debug:mousepressed(_, _, button)
  if not self.enabled then return false end
  if button == 1 then
    if self.hovered then
      self.selected   = self.hovered
      self.edit_field = 1
    else
      self.selected = nil
    end
    return true
  end
  return false
end

function Debug:draw()
  if not self.enabled then return end

  local g = love.graphics

  -- AI radius circles drawn in world space
  g.push()
  self.camera:apply()
  self:_draw_radii()
  g.pop()

  -- HUD panels drawn in screen space
  self:_draw_stats_bar()
  if self.hovered or self.selected then
    self:_draw_inspector(self.selected or self.hovered)
  end
  self:_draw_help()
end

-- ── private ──────────────────────────────────────────────────────────────────

function Debug:_entity_under_mouse()
  local mx, my  = love.mouse.getPosition()
  local wx, wy  = self:_screen_to_world(mx, my)
  local best    = nil
  local best_d2 = 20 * 20  -- 20 px pick radius

  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then
      local dx = e.x - wx
      local dy = e.y - wy
      local d2 = dx * dx + dy * dy
      if d2 < best_d2 then
        best_d2 = d2
        best    = e
      end
    end
  end
  return best
end

function Debug:_screen_to_world(sx, sy)
  local sw, sh = love.graphics.getDimensions()
  local z      = self.camera:zoom()
  return self.camera.x + (sx - sw / 2) / z,
         self.camera.y + (sy - sh / 2) / z
end

function Debug:_draw_radii()
  if not self.show_radii then return end
  local g   = love.graphics
  local ent = self.selected or self.hovered
  if not ent then return end

  local td = ent.type_data
  if not td then return end

  g.setLineWidth(1)
  if (td.detection_radius or 0) > 0 then
    g.setColor(COL_RADIUS)
    g.circle("fill", ent.x, ent.y, td.detection_radius)
    g.setColor(COL_RADIUS[1], COL_RADIUS[2], COL_RADIUS[3], 0.8)
    g.circle("line", ent.x, ent.y, td.detection_radius)
  end
  if (td.attack_range or 0) > 0 then
    g.setColor(COL_ATCK)
    g.circle("fill", ent.x, ent.y, td.attack_range)
    g.setColor(COL_ATCK[1], COL_ATCK[2], COL_ATCK[3], 0.9)
    g.circle("line", ent.x, ent.y, td.attack_range)
  end
  if (td.hit_radius or 0) > 0 then
    g.setColor(0.2, 0.8, 1, 0.6)
    g.circle("line", ent.x, ent.y, td.hit_radius)
  end

  -- patrol route
  if ent.route then
    local routes = self.world.stage.routes
    local route  = routes and routes[ent.route + 1]
    if route and route.points then
      g.setColor(COL_ROUTE)
      for i, pt in ipairs(route.points) do
        g.circle("fill", pt.x, pt.y, 4)
        if i > 1 then
          local prev = route.points[i - 1]
          g.line(prev.x, prev.y, pt.x, pt.y)
        end
      end
    end
  end

  g.setColor(1, 1, 1)
end

function Debug:_draw_stats_bar()
  local g    = love.graphics
  local fps  = love.timer.getFPS()
  local live = 0
  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then live = live + 1 end
  end
  local text = string.format("FPS %d  entities %d/%d  [F2] debug",
    fps, live, #self.world.entities)

  local sw = love.graphics.getWidth()
  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", sw - 320, 0, 320, 22)
  g.setColor(COL_HINT)
  g.print(text, sw - 316, 4)
end

function Debug:_draw_inspector(ent)
  local g    = love.graphics
  local cls  = self.world.stage.classes[ent.class_idx + 1]
  local td   = ent.type_data or {}

  local rows = {
    { "id",        tostring(ent.id)                      },
    { "class",     tostring(ent.class_idx)               },
    { "kind",      cls.kind_name or "?"                  },
    { "pos",       string.format("%d, %d", ent.x, ent.y) },
    { "angle",     string.format("%.1f°", ent.angle)     },
    { "hp",        string.format("%d / %d", ent.hp, ent.max_hp) },
    { "state",     ent.state                             },
    { "route",     ent.route and tostring(ent.route) or "none" },
  }

  -- separator
  rows[#rows + 1] = { "---", "" }

  for _, fname in ipairs(EDITABLE_FIELDS) do
    rows[#rows + 1] = { fname, tostring(td[fname] or 0), fname }
  end
  rows[#rows + 1] = { "weapon",    td.weapon or "none"     }
  rows[#rows + 1] = { "explosion", td.explosion or "none"  }

  local bh = #rows * LINE_H + PANEL_PAD * 2
  local bx = love.graphics.getWidth() - PANEL_W - 8
  local by = 30

  g.setColor(BG)
  g.rectangle("fill", bx, by, PANEL_W, bh, 4)

  local is_editing = (self.selected == ent)

  for i, row in ipairs(rows) do
    local label, value, field = row[1], row[2], row[3]
    local y = by + PANEL_PAD + (i - 1) * LINE_H

    if label == "---" then
      g.setColor(0.3, 0.3, 0.3, 1)
      g.line(bx + PANEL_PAD, y + LINE_H / 2, bx + PANEL_W - PANEL_PAD, y + LINE_H / 2)
    else
      local is_selected_field = is_editing and field and
        (EDITABLE_FIELDS[self.edit_field] == field)

      g.setColor(COL_LABEL)
      g.print(label, bx + PANEL_PAD, y)

      if is_selected_field then
        g.setColor(COL_EDIT)
        g.print("◄ " .. value .. " ►", bx + 110, y)
      else
        g.setColor(field and COL_KEY or COL_VALUE)
        g.print(value, bx + 110, y)
      end
    end
  end

  if is_editing then
    g.setColor(COL_HINT)
    g.print("↑↓ field  ←→ value  S save  Esc deselect",
      bx + PANEL_PAD, by + bh + 2)
  else
    g.setColor(COL_HINT)
    g.print("click to edit", bx + PANEL_PAD, by + bh + 2)
  end
end

function Debug:_draw_help()
  local g  = love.graphics
  local sw = love.graphics.getWidth()
  local sh = love.graphics.getHeight()
  g.setColor(COL_HINT)
  g.print("[F2] close debug", sw - 140, sh - 20)
end

function Debug:_save_entity_types()
  -- Rebuild the entity_types table from live type_data on all entities.
  -- (Multiple entities share the same type_data reference, so one pass is enough.)
  local seen  = {}
  local types = {}
  for _, e in ipairs(self.world.entities) do
    local cls = self.world.stage.classes[e.class_idx + 1]
    local kn  = cls.kind_name
    if kn and not seen[kn] and e.type_data then
      seen[kn]  = true
      types[kn] = e.type_data
    end
  end
  write_json(self.entity_types_path, types)
end

return Debug
