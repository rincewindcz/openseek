local Class     = require "engine.class"
local Animation = require "engine.animation"

local Powerups = Class()

local TTL        = 6.0   -- seconds a pickup stays before vanishing
local BLINK_AT   = 4.0   -- starts blinking after this to warn it is leaving
local PICK_RANGE = 22    -- collection radius added to the player's own radius

-- Pickup kinds mapped to PICKUPS.BIN frames, with spawn weights. Ammo kinds
-- carry a weapon name; the medal kind animates by toggling frames 8/9.
local KINDS = {
  { frame = 4,  weight = 3, kind = "fuel"  },
  { frame = 5,  weight = 3, kind = "armor" },
  { frame = 8,  weight = 1, kind = "medal" },
  { frame = 1,  weight = 1, kind = "ammo", weapon = "air_to_air"   },
  { frame = 2,  weight = 1, kind = "ammo", weapon = "napalm"       },
  { frame = 3,  weight = 1, kind = "ammo", weapon = "rockets"      },
  { frame = 10, weight = 1, kind = "ammo", weapon = "shells"       },
  { frame = 12, weight = 1, kind = "ammo", weapon = "bomb"         },
  { frame = 13, weight = 1, kind = "ammo", weapon = "mega_missile" },
}
local TOTAL_WEIGHT = 0
for _, k in ipairs(KINDS) do TOTAL_WEIGHT = TOTAL_WEIGHT + k.weight end

function Powerups:init(world, camera, weapons)
  self.world     = world
  self.camera    = camera
  self.weapons   = weapons or {}
  self.player    = nil
  self.list      = {}
  self.easy_mode = true   -- fly-over pickup; false = must land the chopper on it
  self._frames   = nil
end

function Powerups:reset(player)
  self.player = player
  self.list   = {}
end

function Powerups:_pickup_frames()
  if self._frames == nil then
    local clip = Animation.clip("pickup")
    self._frames = clip and clip.frames or false
  end
  return self._frames or nil
end

function Powerups:_random_kind()
  local r = math.random() * TOTAL_WEIGHT
  for _, k in ipairs(KINDS) do
    r = r - k.weight
    if r <= 0 then return k end
  end
  return KINDS[1]
end

function Powerups:_kind_named(name)
  for _, k in ipairs(KINDS) do
    if k.kind == name then return k end
  end
  return nil
end

function Powerups:_spawn(x, y, forced)
  local def = (type(forced) == "string" and self:_kind_named(forced)) or self:_random_kind()
  self.list[#self.list + 1] = { x = x, y = y, def = def, age = 0 }
end

function Powerups:update(dt)
  -- Spawn from freshly destroyed buildings. drop_powerup is true (random) or a
  -- kind name string (forced drop, e.g. bunker -> medal).
  for _, e in ipairs(self.world.entities) do
    if e.drop_powerup then
      local forced = e.drop_powerup
      e.drop_powerup = false
      self:_spawn(e.x, e.y, forced)
    end
  end

  local p    = self.player
  local live = {}
  for _, pu in ipairs(self.list) do
    pu.age = pu.age + dt
    local taken = false
    if p then
      local dx = p.x - pu.x
      local dy = p.y - pu.y
      local rr = PICK_RANGE + (p.collision_radius or 8)
      if dx * dx + dy * dy <= rr * rr then
        -- Easy: fly over. Hard: the chopper must be landed on it (a tank is
        -- always grounded, so it collects either way).
        local grounded = (not p.is_flyer) or (not p:is_flyer()) or p.land_state == "grounded"
        if self.easy_mode or grounded then
          self:_apply(pu.def)
          taken = true
        end
      end
    end
    if not taken and pu.age < TTL then live[#live + 1] = pu end
  end
  self.list = live
end

function Powerups:_apply(def)
  local p = self.player
  if not p then return end
  if def.kind == "fuel" then
    p:refuel()
  elseif def.kind == "armor" then
    p:repair()
  elseif def.kind == "medal" then
    p.medals = (p.medals or 0) + 1
  elseif def.kind == "ammo" then
    local w = self.weapons[def.weapon]
    p:add_ammo(def.weapon, (w and w.ammo_pickup) or 10)
  end
end

function Powerups:draw()
  if #self.list == 0 then return end
  local frames = self:_pickup_frames()
  if not frames then return end
  local g = love.graphics
  g.push()
  self.camera:apply()
  for _, pu in ipairs(self.list) do
    local visible = (pu.age <= BLINK_AT) or (math.floor(pu.age * 8) % 2 == 0)
    if visible then
      local fi = pu.def.frame
      if pu.def.kind == "medal" then
        fi = (math.floor(pu.age * 3) % 2 == 0) and 8 or 9
      end
      local img = frames[fi + 1]
      if img then
        local iw, ih = img:getDimensions()
        g.setColor(1, 1, 1)
        g.draw(img, pu.x, pu.y, 0, 1, 1, iw / 2, ih / 2)
      end
    end
  end
  g.setColor(1, 1, 1)
  g.pop()
end

return Powerups
