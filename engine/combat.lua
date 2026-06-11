local Class     = require "engine.class"
local json      = require "lib.json"
local Animation = require "engine.animation"

-- ── Projectile ────────────────────────────────────────────────────────────────

local Projectile = Class()

function Projectile:init(p)
  self.x         = p.x
  self.y         = p.y
  self.vx        = p.vx
  self.vy        = p.vy
  self.damage    = p.damage
  self.aoe       = p.aoe  or 0
  self.owner     = p.owner
  self.ttl       = p.ttl
  self.radius    = p.radius
  self.wdef      = p.wdef
  self.angle_rad = p.angle_rad  -- Love2D draw rotation (radians)
  self.alive     = true
end

function Projectile:update(dt)
  self.x   = self.x   + self.vx * dt
  self.y   = self.y   + self.vy * dt
  self.ttl = self.ttl - dt
  if self.ttl <= 0 then self.alive = false end
end

function Projectile:get_image()
  local wdef = self.wdef
  if not wdef.proj_sprite then return nil end
  local clip = Animation.clip(wdef.proj_sprite)
  if not clip or #clip.frames == 0 then return nil end
  return clip.frames[1]
end

-- ── CombatSystem ─────────────────────────────────────────────────────────────

local CombatSystem = Class()

function CombatSystem:init(world, camera)
  self.world       = world
  self.camera      = camera
  self.player      = nil
  self.projectiles = {}
  self.weapons     = {}
  self._swing      = {}
end

function CombatSystem:load(path)
  local raw = love.filesystem.read(path)
  if not raw then error("combat: missing " .. path) end
  self.weapons = json.decode(raw)
end

function CombatSystem:fire(x, y, angle_deg, weapon_name, owner, level_idx)
  local wdef = self.weapons[weapon_name]
  if not wdef then return end
  level_idx = level_idx or 1
  local level = (wdef.levels and wdef.levels[level_idx]) or wdef

  -- Forward direction in world space (angle_deg: 0=north CW)
  local rad = (angle_deg - 90) * math.pi / 180
  local fx  = math.cos(rad)
  local fy  = math.sin(rad)
  -- Right-perpendicular (90 deg CW in Y-down screen space): (-fy, fx)
  local rx  = -fy
  local ry  =  fx

  local speed      = wdef.speed or 0
  local spread     = (level.spread_deg or wdef.spread_deg or 0) * math.pi / 180
  local count      = level.count   or 1
  local streams    = level.streams or 1
  local side       = level.side_offset or 0
  local total      = math.max(count, streams)

  local swing_off = 0
  if level.swing then
    local key = tostring(owner) .. weapon_name
    swing_off = math.sin(self._swing[key] or 0) * spread
  end

  for i = 1, total do
    -- Angular spread offset
    local angle_off = swing_off
    if total > 1 and spread > 0 then
      angle_off = angle_off + (i - (total + 1) / 2) * spread / math.max(1, total - 1)
    end

    -- Lateral position offset (perpendicular to travel)
    local ox, oy = 0, 0
    if side > 0 and total > 1 then
      local dist = (i - (total + 1) / 2) * side / math.max(1, total - 1)
      ox = rx * dist
      oy = ry * dist
    end

    local fire_rad = rad + angle_off
    local proj = Projectile:new({
      x         = x + ox,
      y         = y + oy,
      vx        = math.cos(fire_rad) * speed,
      vy        = math.sin(fire_rad) * speed,
      damage    = level.damage    or wdef.damage    or 10,
      aoe       = wdef.aoe        or 0,
      owner     = owner,
      ttl       = wdef.ttl        or 2,
      radius    = wdef.proj_radius or 3,
      wdef      = wdef,
      -- Rotation for drawing: angle_deg in our CW-from-north system maps to Love2D radians
      angle_rad = angle_deg * math.pi / 180 + angle_off,
    })
    self.projectiles[#self.projectiles + 1] = proj
  end
end

function CombatSystem:tick_swing(owner, weapon_name)
  local key = tostring(owner) .. weapon_name
  if not self._swing[key] then self._swing[key] = 0 end
end

function CombatSystem:update(dt)
  for k in pairs(self._swing) do
    self._swing[k] = self._swing[k] + dt * 5.0
  end

  local alive = {}
  for _, proj in ipairs(self.projectiles) do
    proj:update(dt)
    if proj.alive and not self:_check_hit(proj) then
      alive[#alive + 1] = proj
    end
  end
  self.projectiles = alive
end

function CombatSystem:_check_hit(proj)
  if proj.owner == "player" then
    for _, e in ipairs(self.world.entities) do
      if e:is_alive() then
        local hr = e.type_data and e.type_data.hit_radius or 0
        if hr > 0 then
          local dx = e.x - proj.x
          local dy = e.y - proj.y
          if dx * dx + dy * dy < (proj.radius + hr) ^ 2 then
            e:on_hit()
            e:take_damage(proj.damage)
            if proj.aoe > 0 then self:_apply_aoe(proj) end
            return true
          end
        end
      end
    end
  else
    local p = self.player
    if p and p.armor > 0 then
      local dx = p.x - proj.x
      local dy = p.y - proj.y
      if dx * dx + dy * dy < (proj.radius + 20) ^ 2 then
        p.armor = math.max(0, p.armor - proj.damage)
        return true
      end
    end
  end
  return false
end

function CombatSystem:_apply_aoe(proj)
  local r2 = proj.aoe ^ 2
  for _, e in ipairs(self.world.entities) do
    if e:is_alive() then
      local dx = e.x - proj.x
      local dy = e.y - proj.y
      if dx * dx + dy * dy < r2 then
        e:take_damage(proj.damage * 0.5)
      end
    end
  end
end

function CombatSystem:draw()
  if #self.projectiles == 0 then return end
  local g = love.graphics
  g.push()
  self.camera:apply()

  for _, proj in ipairs(self.projectiles) do
    local wdef = proj.wdef
    if wdef.proj_type == "bullet" then
      local c  = wdef.proj_color or {1, 1, 1}
      local sz = wdef.proj_size  or 2
      g.setColor(c[1], c[2], c[3], 1)
      g.rectangle("fill", proj.x - sz / 2, proj.y - sz / 2, sz, sz)
    else
      local img = proj:get_image()
      if img then
        local w, h = img:getDimensions()
        g.setColor(1, 1, 1)
        g.draw(img, proj.x, proj.y, proj.angle_rad, 1, 1, w / 2, h / 2)
      end
    end
  end

  g.setColor(1, 1, 1)
  g.pop()
end

return CombatSystem
