local Class     = require "engine.class"
local json      = require "lib.json"
local Animation = require "engine.animation"

-- LuaJIT (LÖVE) has math.atan2; Lua 5.3+ folds it into math.atan(y, x).
local atan2 = math.atan2 or math.atan

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
  self.max_range = p.max_range
  self.accel     = p.accel or 0  -- forward acceleration (px/s^2), e.g. tracers
  self.traveled  = 0
  self.trail          = p.trail            -- effect clip dropped along the path
  self.trail_interval = p.trail_interval or 14
  self._trail_dist    = 0
  self.alive     = true
  -- Animated sprite (e.g. the growing tracer streak); plays once, holds last frame.
  if p.animate then self.anim = Animation.new(p.wdef.proj_sprite) end
end

function Projectile:update(dt)
  if self.accel > 0 then
    local sp = math.sqrt(self.vx * self.vx + self.vy * self.vy)
    if sp > 0 then
      local nsp = sp + self.accel * dt
      self.vx = self.vx / sp * nsp
      self.vy = self.vy / sp * nsp
    end
  end
  local dx = self.vx * dt
  local dy = self.vy * dt
  self.x = self.x + dx
  self.y = self.y + dy
  local step = math.sqrt(dx * dx + dy * dy)
  self.traveled = self.traveled + step
  if self.trail then self._trail_dist = self._trail_dist + step end
  if self.max_range and self.traveled >= self.max_range then self.alive = false end
  if self.anim then self.anim:update(dt) end
  self.ttl = self.ttl - dt
  if self.ttl <= 0 then self.alive = false end
end

function Projectile:get_image()
  local wdef = self.wdef
  if not wdef.proj_sprite then return nil end
  if self.anim then return self.anim:current_image() end
  local clip = Animation.clip(wdef.proj_sprite)
  if not clip or #clip.frames == 0 then return nil end
  return clip.frames[1]
end

-- Draw origin that centers the sprite's visible art on the projectile position.
function Projectile:get_anchor()
  if not self.wdef.proj_sprite then return 0, 0 end
  local frame = self.anim and self.anim.frame or 1
  return Animation.frame_anchor(self.wdef.proj_sprite, frame)
end

-- ── CombatSystem ─────────────────────────────────────────────────────────────

local CombatSystem = Class()

function CombatSystem:init(world, camera)
  self.world       = world
  self.camera      = camera
  self.player      = nil
  self.projectiles = {}
  self.effects     = {}   -- transient world anims (missile trails, napalm fire)
  self.weapons     = {}
  self._swing      = {}
  self._alt        = {}   -- per owner+weapon side toggle for alternate_side weapons
end

-- Spawn a transient world-space effect. opts: {rot, scale, damage, radius, ttl}.
-- A damage effect applies its damage once to entities within radius. ttl bounds
-- looping clips (napalm fire); non-looping clips also cull when their anim ends.
function CombatSystem:add_effect(clip_name, x, y, opts)
  opts = opts or {}
  local anim = Animation.new(clip_name)
  if anim:is_done() then return end
  self.effects[#self.effects + 1] = {
    anim   = anim,
    x      = x,
    y      = y,
    rot    = opts.rot   or 0,
    scale  = opts.scale or 1,
    damage = opts.damage,
    radius = opts.radius or 0,
    ttl    = opts.ttl,
    age    = 0,
    hit    = false,
  }
end

function CombatSystem:load(path)
  local raw = love.filesystem.read(path)
  if not raw then error("combat: missing " .. path) end
  self.weapons = json.decode(raw)
end

function CombatSystem:fire(x, y, angle_deg, weapon_name, owner, level_idx, range_override)
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

  -- Napalm and similar: a widening cone of ground fire ahead, no projectiles.
  if wdef.proj_type == "flame" then
    return self:_fire_flame(x, y, fx, fy, rad, wdef, level)
  end

  -- Range cap: player shots are limited to ~1.5x the visible screen so they
  -- cannot cross the map; enemies pass their attack range so their shots reach.
  local sw, sh    = love.graphics.getDimensions()
  local view      = math.max(sw, sh) / self.camera:zoom()
  local max_range = range_override or (1.5 * view)

  -- Multi-frame projectile sprites animate (the tracer streak that grows).
  local clip      = wdef.proj_sprite and Animation.clip(wdef.proj_sprite)
  local animate   = clip and #clip.frames > 1 or false

  local speed      = wdef.speed or 0
  local spread     = (level.spread_deg or wdef.spread_deg or 0) * math.pi / 180
  local count      = level.count   or 1
  local streams    = level.streams or 1
  local side       = level.side_offset or 0
  local side_list  = level.side_offsets   -- explicit per-projectile lateral offsets (px)
  local total      = side_list and #side_list or math.max(count, streams)

  local swing_off = 0
  if level.swing then
    local key = tostring(owner) .. weapon_name
    swing_off = math.sin(self._swing[key] or 0) * spread
  end

  -- Alternate-side weapons (mega missile) fire one round, swapping the muzzle
  -- between the left and right pod each trigger.
  local alt_sign = 0
  if wdef.alternate_side then
    local key = tostring(owner) .. weapon_name
    alt_sign = (self._alt[key] == 1) and -1 or 1
    self._alt[key] = alt_sign
  end

  for i = 1, total do
    -- Angular spread offset
    local angle_off = swing_off
    if total > 1 and spread > 0 then
      angle_off = angle_off + (i - (total + 1) / 2) * spread / math.max(1, total - 1)
    end

    -- Lateral position offset (perpendicular to travel)
    local ox, oy = 0, 0
    if side_list then
      local dist = side_list[i]
      ox = rx * dist
      oy = ry * dist
    elseif side > 0 and total > 1 then
      local dist = (i - (total + 1) / 2) * side / math.max(1, total - 1)
      ox = rx * dist
      oy = ry * dist
    end
    if wdef.alternate_side then
      ox = rx * side * alt_sign
      oy = ry * side * alt_sign
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
      max_range = max_range,
      accel     = wdef.proj_accel or 0,
      animate   = animate,
      trail          = wdef.trail,
      trail_interval = wdef.trail_interval,
      -- Rotation for drawing: angle_deg in our CW-from-north system maps to Love2D radians
      angle_rad = angle_deg * math.pi / 180 + angle_off,
    })
    self.projectiles[#self.projectiles + 1] = proj
  end
end

-- Napalm: a deterministic wave of `count` fire patches laid straight ahead of
-- the muzzle, repeated as `lines` parallel rows (level 1/2/3 -> 1/2/3 lines).
-- Each patch is a one-shot damage effect.
function CombatSystem:_fire_flame(x, y, fx, fy, rad, wdef, level)
  local lines   = level.lines   or 1
  local count   = level.count   or 10
  local spacing = level.spacing or wdef.spacing or 15
  local loff    = level.line_offset or wdef.line_offset or 18
  local dmg     = level.damage  or wdef.damage or 30
  local radius  = wdef.aoe      or 20
  local px, py  = -fy, fx  -- perpendicular (lateral) direction
  for l = 1, lines do
    local lat = (l - (lines + 1) / 2) * loff
    for i = 1, count do
      local d  = i * spacing
      local ex = x + fx * d + px * lat
      local ey = y + fy * d + py * lat
      self:add_effect(wdef.effect or "fire", ex, ey,
        { damage = dmg, radius = radius, ttl = wdef.fire_ttl or 1.3 })
    end
  end
end

function CombatSystem:tick_swing(owner, weapon_name)
  local key = tostring(owner) .. weapon_name
  if not self._swing[key] then self._swing[key] = 0 end
end

-- Angular threshold (deg) within which a turret/soldier is considered locked on.
local LOCK_DEG = 8

-- Drive enemy aiming and firing. Each combatant rotates its aim toward the
-- player at its turn_speed, and fires its weapon when locked and in range.
function CombatSystem:_update_ai(dt)
  local p = self.player
  if not p then return end
  for _, e in ipairs(self.world.combatants) do
    if e:is_alive() then
      local td  = e.type_data
      local dx  = p.x - e.x
      local dy  = p.y - e.y
      local d2  = dx * dx + dy * dy
      local det = td.detection_radius or 0
      if det > 0 and d2 <= det * det then
        local target = (math.deg(atan2(dy, dx)) + 90) % 360
        local diff   = ((target - e.aim_angle + 180) % 360) - 180
        local step   = (td.turn_speed or 90) * dt
        if math.abs(diff) <= step then
          e.aim_angle = target
        else
          e.aim_angle = (e.aim_angle + (diff > 0 and step or -step)) % 360
        end
        -- Single-sprite turrets (flak) rotate the whole sprite via e.angle;
        -- two-part tanks keep the hull fixed and spin only the turret overlay,
        -- which the renderer draws from aim_angle.
        if not e.has_turret then e.angle = e.aim_angle end

        local atk    = td.attack_range or det
        local weapon = e.weapon or td.weapon
        local can_fire = (not e.has_turret) or e.turret_alive
        if can_fire and math.abs(diff) < LOCK_DEG and d2 <= atk * atk then
          e.reload = e.reload - dt
          if e.reload <= 0 then
            self:fire(e.x, e.y, e.aim_angle, weapon, "enemy", 1, atk * 1.3)
            local w = self.weapons[weapon]
            e.reload = 1 / ((w and w.fire_rate) or 1)
          end
        end
      end
    end
  end
end

function CombatSystem:update(dt)
  for k in pairs(self._swing) do
    self._swing[k] = self._swing[k] + dt * 5.0
  end

  self:_update_ai(dt)

  local alive = {}
  for _, proj in ipairs(self.projectiles) do
    proj:update(dt)
    -- Drop a trail puff every trail_interval px travelled.
    if proj.trail and proj._trail_dist >= proj.trail_interval then
      proj._trail_dist = 0
      self:add_effect(proj.trail, proj.x, proj.y, {})
    end
    local ended
    if proj.alive then
      if self:_check_hit(proj) then ended = true else alive[#alive + 1] = proj end
    else
      ended = true
    end
    if ended then self:_end_projectile(proj) end
  end
  self.projectiles = alive

  self:_update_effects(dt)
end

-- An enemy round bursts into its explosion clip when it hits the player or fades
-- out (e.g. flak/sgun -> flakani). Player impacts are handled by entity deaths.
function CombatSystem:_end_projectile(proj)
  if proj.owner == "player" then return end
  local ex = proj.wdef.explosion
  if ex and ex ~= "explosion_none" then
    self:add_effect(ex, proj.x, proj.y, {})
  end
end

function CombatSystem:_update_effects(dt)
  local live = {}
  for _, fx in ipairs(self.effects) do
    fx.anim:update(dt)
    fx.age = fx.age + dt
    if fx.damage and not fx.hit then
      fx.hit = true
      local r2 = (fx.radius or 0) ^ 2
      for _, e in ipairs(self.world.entities) do
        if e:is_alive() and (e.type_data and (e.type_data.hit_radius or 0) > 0) then
          local dx = e.x - fx.x
          local dy = e.y - fx.y
          if dx * dx + dy * dy < r2 then
            e:on_hit()
            e:take_damage(fx.damage, dx, dy)
          end
        end
      end
    end
    local expired = (fx.ttl and fx.age >= fx.ttl) or fx.anim:is_done()
    if not expired then live[#live + 1] = fx end
  end
  self.effects = live
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
            e:take_damage(proj.damage, proj.vx, proj.vy)
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
      local pr = (p.collision_radius or 12) + proj.radius
      if dx * dx + dy * dy < pr * pr then
        if not p.unlimited then p.armor = math.max(0, p.armor - proj.damage) end
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
  if #self.projectiles == 0 and #self.effects == 0 then return end
  local g = love.graphics
  g.push()
  self.camera:apply()

  -- Transient effects (trails, napalm fire) draw under the projectiles.
  for _, fx in ipairs(self.effects) do
    local img = fx.anim:current_image()
    if img then
      local iw, ih = img:getDimensions()
      g.setColor(1, 1, 1)
      g.draw(img, fx.x, fx.y, fx.rot, fx.scale, fx.scale, iw / 2, ih / 2)
    end
  end

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
        local extra    = (wdef.proj_sprite_rot or 0) * math.pi / 180
        local ax, ay   = proj:get_anchor()
        g.setColor(1, 1, 1)
        g.draw(img, proj.x, proj.y, proj.angle_rad + extra, 1, 1, ax, ay)
      end
    end
  end

  g.setColor(1, 1, 1)
  g.pop()
end

return CombatSystem
