local Class     = require "engine.class"
local Animation = require "engine.animation"
local Config    = require "engine.config"

local atan2 = math.atan2 or math.atan

-- POW rescue from POWHERE buildings. Each powhere.bin marker (World.rescue_zones)
-- is a building holding one or more POWs and is paired with the nearest lh.bin
-- "land here" marker. Co-located powhut.bin huts are shielded from damage while
-- the building still holds POWs. When a vehicle sits on the land marker long
-- enough the POWs walk out one by one to the vehicle (rescued on contact) and
-- walk back if the vehicle leaves; a POW can be shot while outside. Once a
-- building is emptied its marker and land pad vanish and its huts become
-- destructible. Stages whose rescue objective is loose civilians (no powhere)
-- are left to the mission's simple fly-over collection instead.
local RescueSystem = Class()

local POW_CLIPS  = { "newdude0", "pow0", "pow1" }
local DWELL_TIME = 1.0   -- seconds the vehicle must hold the land pad before POWs emerge
local SPAWN_GAP  = 0.7   -- seconds between successive POWs leaving the building
local WALK_SPEED = 42    -- px/s a POW walks
local LAND_R     = 40    -- vehicle must be stationary within this of the land marker
local REACH_R    = 6     -- distance at which a POW reaches the vehicle / re-enters
local POW_HIT_R  = 6     -- a POW's collision radius when shot
local COLOCATE_R = 12    -- a building this close under the marker is its paired hull
local POW_ROT    = 180   -- the walk sprite faces south at rest; offset to its heading

function RescueSystem:init(world, combat)
  self.world      = world
  self.combat     = combat
  self.sites      = {}
  self.active     = false
  self.pow_counts = nil   -- optional per-building POW counts (set before reset)
  world.rescue    = self
end

-- POWs per building: an explicit per-building count (pow_counts, in zone load
-- order) when supplied, otherwise a random 1-3.
function RescueSystem:_count_for(idx)
  local c = self.pow_counts and self.pow_counts[idx]
  return c or math.random(1, 3)
end

function RescueSystem:_nearest_land(zone, taken)
  local best, bd
  for _, lz in ipairs(self.world.land_zones) do
    if not taken[lz] then
      local dx, dy = self.world:delta(lz.ent.x, lz.ent.y, zone.x, zone.y)
      local d = dx * dx + dy * dy
      if not bd or d < bd then best, bd = lz, d end
    end
  end
  return best
end

-- The destructible building directly under the marker (bunker, powhut, ...),
-- paired with it like a tank hull under its turret and shielded until the
-- building is emptied. Matches by co-location regardless of the building asset.
function RescueSystem:_paired_buildings(zone)
  local buildings = {}
  for _, e in ipairs(self.world.objects) do
    local cls = self.world.stage.classes[e.class_idx + 1]
    if cls and cls.kind_name == "structure" then
      local dx, dy = self.world:delta(e.x, e.y, zone.x, zone.y)
      if dx * dx + dy * dy <= COLOCATE_R * COLOCATE_R then buildings[#buildings + 1] = e end
    end
  end
  return buildings
end

function RescueSystem:reset()
  self.sites  = {}
  self.active = #self.world.rescue_zones > 0
  if not self.active then return end
  local taken = {}
  for idx, zone in ipairs(self.world.rescue_zones) do
    local land  = self:_nearest_land(zone, taken)
    if land then taken[land] = true end
    local buildings = self:_paired_buildings(zone)
    for _, b in ipairs(buildings) do b.protected = true end
    local total = self:_count_for(idx)
    self.sites[#self.sites + 1] = {
      zone      = zone,
      land      = land,
      lx        = land and land.ent.x or zone.x,
      ly        = land and land.ent.y or zone.y,
      buildings = buildings,
      total   = total,
      inside  = total,   -- POWs still in the building
      rescued = 0,
      lost    = 0,       -- POWs shot while outside
      pows    = {},      -- POWs currently walking
      dwell   = 0,
      spawn_t = 0,
      cleared = false,
    }
  end
end

function RescueSystem:clear()
  self.sites  = {}
  self.active = false
end

-- ── progress ────────────────────────────────────────────────────────────────────

function RescueSystem:_landed_in_zone(p, site)
  if not p:is_stationary() then return false end
  local dx, dy = self.world:delta(p.x, p.y, site.lx, site.ly)
  return dx * dx + dy * dy <= LAND_R * LAND_R
end

function RescueSystem:_emerge(site, target)
  site.inside = site.inside - 1
  site.pows[#site.pows + 1] = {
    x = site.zone.x, y = site.zone.y,
    state   = "out",
    target  = target,
    heading = 0,
    anim    = Animation.new(POW_CLIPS[math.random(#POW_CLIPS)]),
  }
end

function RescueSystem:_update_pow(pow, site, dt, lander)
  pow.anim:update(dt)
  -- While a vehicle holds the pad the POW heads for it; otherwise it walks home.
  if lander then
    pow.target = lander
    pow.state  = "out"
  else
    pow.state = "back"
  end

  local gx, gy, reach
  if pow.state == "out" then
    gx, gy = pow.target.x, pow.target.y
    reach  = (pow.target.collision_radius or 8) + REACH_R
  else
    gx, gy = site.zone.x, site.zone.y
    reach  = REACH_R
  end

  local dx, dy = self.world:delta(gx, gy, pow.x, pow.y)
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= reach then
    if pow.state == "out" then
      site.rescued     = site.rescued + 1
      pow.target.pows  = (pow.target.pows or 0) + 1
      pow.target.score = (pow.target.score or 0) + 150
    else
      site.inside = site.inside + 1   -- back inside, waits to be rescued again
    end
    pow.done = true
    return
  end

  -- Face the way it walks (heading: 0 = north, clockwise; dx,dy point at the goal).
  pow.heading = (math.deg(atan2(dy, dx)) + 90) % 360
  local step = WALK_SPEED * dt * Config.speed_scale
  local s    = self.world.stage.world_size
  pow.x = (pow.x + dx / d * step) % s
  pow.y = (pow.y + dy / d * step) % s
end

function RescueSystem:_clear_site(site)
  site.cleared = true
  for _, b in ipairs(site.buildings) do b.protected = false end
  site.zone.rescue_hidden = true
end

function RescueSystem:update(dt)
  if not self.active then return end
  local players = self.combat.players or {}
  for _, site in ipairs(self.sites) do
    if not site.cleared then
      local lander
      for _, p in ipairs(players) do
        if p and not p.death and self:_landed_in_zone(p, site) then lander = p; break end
      end

      if lander then site.dwell = site.dwell + dt else site.dwell = 0 end

      if lander and site.dwell >= DWELL_TIME and site.inside > 0 then
        site.spawn_t = site.spawn_t - dt
        if site.spawn_t <= 0 then
          site.spawn_t = SPAWN_GAP
          self:_emerge(site, lander)
        end
      end

      local keep = {}
      for _, pow in ipairs(site.pows) do
        if not pow.done then self:_update_pow(pow, site, dt, lander) end
        if not pow.done then keep[#keep + 1] = pow end
      end
      site.pows = keep

      if site.inside == 0 and #site.pows == 0
      and (site.rescued + site.lost) >= site.total then
        self:_clear_site(site)
      end
    end
  end
end

-- A projectile passed (x, y); kill any POW it touches. Enemy rounds always kill;
-- the player's own rounds only when the friendly-fire option is on. Returns true
-- if a POW was hit so the caller can consume the round.
function RescueSystem:projectile_hit(x, y, radius, from_player)
  if not self.active then return false end
  if from_player and not Config.friendly_fire_pows then return false end
  for _, site in ipairs(self.sites) do
    if not site.cleared then
      for _, pow in ipairs(site.pows) do
        if not pow.done then
          local dx, dy = self.world:delta(pow.x, pow.y, x, y)
          local rr = radius + POW_HIT_R
          if dx * dx + dy * dy < rr * rr then
            pow.done  = true
            site.lost = site.lost + 1
            if self.combat then self.combat:add_effect("smoke2", pow.x, pow.y, {}) end
            return true
          end
        end
      end
    end
  end
  return false
end

-- ── objective queries (read by Mission) ──────────────────────────────────────────

function RescueSystem:rescued_count()
  local n = 0
  for _, s in ipairs(self.sites) do n = n + s.rescued end
  return n
end

-- Initial POW total minus those lost, so the objective stays completable.
function RescueSystem:required_count()
  local n = 0
  for _, s in ipairs(self.sites) do n = n + (s.total - s.lost) end
  return n
end

function RescueSystem:all_cleared()
  for _, s in ipairs(self.sites) do
    if not s.cleared then return false end
  end
  return true
end

-- ── draw ──────────────────────────────────────────────────────────────────────

function RescueSystem:draw()
  if not self.active then return end
  local g    = love.graphics
  local cam  = self.combat.camera
  -- Land pads follow the pickups option: screen-upright (original) or world-rotated.
  local mrot = Config.axis_aligned_pickups and -(cam.angle or 0) or 0
  g.push()
  cam:apply()
  for _, t in ipairs(cam:tiles()) do
    g.push()
    g.translate(t.ox, t.oy)
    for _, site in ipairs(self.sites) do
      if not site.cleared and site.land then
        local r = self.world.images[site.land.ent.class_idx + 1]
        if r and r.img then
          local iw, ih = r.img:getDimensions()
          g.setColor(1, 1, 1)
          g.draw(r.img, site.land.ent.x + r.ox + iw / 2, site.land.ent.y + r.oy + ih / 2,
            mrot, 1, 1, iw / 2, ih / 2)
        end
      end
    end
    for _, site in ipairs(self.sites) do
      for _, pow in ipairs(site.pows) do
        local img = pow.anim:current_image()
        if img then
          local iw, ih = img:getDimensions()
          local rot = ((pow.heading or 0) + POW_ROT) * math.pi / 180
          g.setColor(1, 1, 1)
          g.draw(img, pow.x, pow.y, rot, 1, 1, iw / 2, ih / 2)
        end
      end
    end
    g.pop()
  end
  g.setColor(1, 1, 1)
  g.pop()
end

return RescueSystem
