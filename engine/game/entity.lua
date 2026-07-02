local Class  = require "engine.core.class"
local json   = require "lib.json"
local Config = require "engine.core.config"
local Mathx  = require "engine.core.mathx"

local entity_types = {}  -- keyed by kind_name, loaded once

local Entity = Class()

local DEATH_PUSH  = 5     -- px a unit corpse slides in the shot direction
local DEATH_SLIDE = 0.12  -- seconds for the corpse slide to settle
local DROP_CHANCE = 0.9   -- chance a destroyed large building drops a power-up

function Entity.load_types(path)
    local data = love.filesystem.read(path)
    if not data then error("missing " .. path) end
    entity_types = json.decode(data)
end

function Entity.type_for(kind_name)
    return entity_types[kind_name] or {}
end

function Entity:init(id, stage_ent, stage_cls)
    self.id           = id
    self.class_idx    = stage_ent.class
    self.x            = stage_ent.x
    self.y            = stage_ent.y
    self.angle        = 0
    self.hp           = stage_cls.hit_points
    self.max_hp       = stage_cls.hit_points
    self.state        = "idle"
    self.state_before = nil
    self.route        = stage_ent.route
    self.route_pt     = 1
    self.route_points = nil   -- resolved from the stage at load (patrol waypoints)
    self.patrol_v     = 0     -- current patrol speed (eased for accel/decel)
    self.engaging     = false -- set by the AI: in firing range, so slow to a stop
    self.type_data    = Entity.type_for(stage_cls.kind_name)
    self.anim         = nil

    -- Two-part enemy (tank): a separate turret entity is folded onto the hull at
    -- load (see World:load / attach_turret). The turret tracks and fires while the
    -- hull stays put, and must be destroyed before the hull can be damaged.
    self.has_turret   = false
    self.turret_alive = false
    self.turret_fx    = nil   -- one-shot explosion played when the turret blows

    -- Enemy AI: turret/facing heading toward the player and a reload timer.
    -- self.weapon may override type_data.weapon for specific sprites (set at load).
    self.aim_angle    = 0
    self.reload       = 0
    self.weapon       = nil

    -- Damage visual effects
    self._damage_smokes = {}   -- {anim, ox, oy}: persistent looping smoke per HP tier
    self._hit_smokes    = {}   -- {anim, ox, oy}: one-shot SMOKE2 on hit

    -- Corpse slide (units only): current draw offset and its animation state
    self.death_ox = 0
    self.death_oy = 0
end

-- Entity is hittable and should be drawn while idle/animating/patrol/attack.
-- Exploding entities are "logically gone"; projectiles pass through them.
function Entity:is_alive()
    return self.state ~= "dead" and self.state ~= "exploding"
end

function Entity:take_damage(amount, dx, dy)
    if not self:is_alive() then return end
    -- A POW building stays indestructible while it still holds prisoners.
    if self.protected then return end
    -- While the turret stands it absorbs all incoming damage; the hull is only
    -- vulnerable once the turret is gone.
    if self.turret_alive then
        self.turret_hp = self.turret_hp - amount
        if self.turret_hp <= 0 then
            self.turret_hp = 0
            self:_destroy_turret()
        end
        return
    end
    self.hp = self.hp - amount
    if self.hp <= 0 then
        self.hp = 0
        self:_start_death(dx, dy)
    end
end

-- Fold a co-located turret entity onto this hull. render = {img, ax, ay} drawn
-- by the renderer, rotated to aim_angle about (ax, ay). spin (deg/s) makes the
-- turret rotate continuously (radar dish) instead of being aimed by the AI.
function Entity:attach_turret(render, spin)
    self.turret_render = render
    self.turret_spin   = spin
    self.has_turret    = true
    self.turret_alive  = true
    self.turret_max_hp = (self.type_data and self.type_data.turret_hp)
        or math.max(1, math.floor((self.max_hp or 1) * 0.5))
    self.turret_hp = self.turret_max_hp
end

function Entity:_destroy_turret()
    local Animation = require "engine.core.animation"
    self.turret_alive = false
    local ex = (self.type_data and self.type_data.turret_explosion) or "medium"
    local fx = Animation.new("explosion_" .. ex)
    self.turret_fx = (not fx:is_done()) and fx or nil
end

-- Spawn a one-shot hit effect at the entity's position with a small random
-- offset. Defaults to SMOKE2; the weapon may pass its own clip (e.g. FFR rockets
-- alternate randomly between smoke and smoke2).
function Entity:on_hit(clip)
    if not self:is_alive() then return end
    local Animation = require "engine.core.animation"
    local anim = Animation.new(clip or "smoke2")
    if anim:is_done() then return end  -- clip not found / empty
    self._hit_smokes[#self._hit_smokes + 1] = {
        anim = anim,
        ox   = (math.random() - 0.5) * 12,
        oy   = (math.random() - 0.5) * 12,
    }
end

function Entity:play_anim(clip_name)
    local Animation = require "engine.core.animation"
    local anim = Animation.new(clip_name)
    if anim.clip:is_empty() then return end
    anim:reset()
    self.anim         = anim
    self.state_before = (self.state ~= "animating") and self.state or self.state_before
    self.state        = "animating"
end

function Entity:_start_death(dx, dy)
    local Animation = require "engine.core.animation"
    local explosion = (self.type_data and self.type_data.explosion) or "none"
    self.anim  = Animation.new("explosion_" .. explosion)
    self.state = self.anim:is_done() and "dead" or "exploding"
    -- Unit corpses (soldiers) get nudged in the direction of the killing shot.
    if dx and dy and self.type_data and self.type_data.sprite then
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            self._death_push = { x = dx / len * DEATH_PUSH, y = dy / len * DEATH_PUSH }
            self._death_t    = 0
        end
    end
    -- Only large static buildings leave a crater. The per-mission crater sprite is
    -- assigned to the entity at load (crater_src); reveal it now that it has died.
    if self.crater_eligible then
        self.crater_img = self.crater_src
        if self.world then self.world:spawn_debris(self.x, self.y) end
    end
    -- Power-up drop: a forced kind always drops (e.g. bunker -> medal); otherwise
    -- large buildings drop a random pickup most of the time.
    if self.drop_kind then
        self.drop_powerup = self.drop_kind
    elseif self.crater_eligible and math.random() < DROP_CHANCE then
        self.drop_powerup = true
    end
    -- Clear smoke effects when dying
    self._damage_smokes = {}
    self._hit_smokes    = {}
end

function Entity:update(dt)
    -- Corpse slide settles over a fraction of a second (ease-out).
    if self._death_push and self._death_t < 1 then
        self._death_t = math.min(1, self._death_t + dt / DEATH_SLIDE)
        local f = 1 - (1 - self._death_t) ^ 2
        self.death_ox = self._death_push.x * f
        self.death_oy = self._death_push.y * f
    end

    -- Turret destruction effect plays while the hull is still alive.
    if self.turret_fx then
        self.turret_fx:update(dt)
        if self.turret_fx:is_done() then self.turret_fx = nil end
    end

    -- Explosion / overlay animation
    if (self.state == "exploding" or self.state == "animating") and self.anim then
        self.anim:update(dt)
        if self.anim:is_done() then
            if self.state == "exploding" then
                self.state = "dead"
            else
                self.state = self.state_before or "idle"
                self.state_before = nil
            end
        end
    end

    if not self:is_alive() then return end

    self:_patrol(dt)

    -- Continuously spinning turret (radar dish).
    if self.turret_spin and self.turret_alive then
        self.aim_angle = (self.aim_angle + self.turret_spin * dt) % 360
    end

    -- Persistent damage smoke: threshold by HP percentage
    if self.max_hp > 0 then
        local pct    = self.hp / self.max_hp
        local target = 0
        if pct < 0.6 then target = 1 end
        if pct < 0.4 then target = 2 end
        if pct < 0.2 then target = 3 end

        while #self._damage_smokes < target do
            local Animation = require "engine.core.animation"
            local anim = Animation.new("smoke")
            self._damage_smokes[#self._damage_smokes + 1] = {
                anim = anim,
                ox   = (math.random() - 0.5) * 20,
                oy   = (math.random() - 0.5) * 20,
            }
        end
        while #self._damage_smokes > target do
            table.remove(self._damage_smokes)
        end

        for _, se in ipairs(self._damage_smokes) do
            se.anim:update(dt)
            if se.anim:is_done() then
                se.anim:reset()
                se.ox = (math.random() - 0.5) * 20
                se.oy = (math.random() - 0.5) * 20
            end
        end
    end

    -- One-shot hit smokes
    local live = {}
    for _, hs in ipairs(self._hit_smokes) do
        hs.anim:update(dt)
        if not hs.anim:is_done() then live[#live + 1] = hs end
    end
    self._hit_smokes = live
end

-- Patrol the assigned waypoint loop, driving like a tank: the hull eases its
-- speed up/down (slowing to a stop when about to fire, telegraphing the shot)
-- and turns toward the next waypoint gradually rather than snapping. The turret
-- (aim_angle) is steered independently by the combat AI.
function Entity:_patrol(dt)
    local pts  = self.route_points
    local td   = self.type_data
    local base = td and td.patrol_speed or 0
    if not pts or #pts < 2 or base <= 0 then return end

    -- Ease speed toward the target (0 while engaging the player, else cruising).
    local target = self.engaging and 0 or base
    local accel  = base * 1.5
    if self.patrol_v < target then
        self.patrol_v = math.min(target, self.patrol_v + accel * dt)
    else
        self.patrol_v = math.max(target, self.patrol_v - accel * dt)
    end

    local tgt = pts[self.route_pt]
    if not tgt then self.route_pt = 1; return end
    local dx, dy = tgt.x - self.x, tgt.y - self.y
    if dx * dx + dy * dy < 36 then           -- reached the waypoint (< 6 px)
        self.route_pt = self.route_pt % #pts + 1
        return
    end

    -- Turn the hull toward the waypoint at a limited rate (no instant snap).
    local desired = Mathx.heading_deg(dx, dy)
    local turn    = (td.patrol_turn or 70) * dt * Config.speed_scale
    local diff    = ((desired - self.angle + 180) % 360) - 180
    if math.abs(diff) <= turn then
        self.angle = desired
    else
        self.angle = (self.angle + (diff > 0 and turn or -turn)) % 360
    end

    -- Drive forward along the current heading.
    if self.patrol_v > 0 then
        local rad  = (self.angle - 90) * math.pi / 180
        local step = self.patrol_v * dt * Config.speed_scale
        self.x = self.x + math.cos(rad) * step
        self.y = self.y + math.sin(rad) * step
    end
end

-- Rotation in radians for g.draw(). The canonical sprite is the axis-aligned
-- frame 0 (pointing north), so a static entity (angle 0) draws unrotated and a
-- moving one rotates clockwise by its heading. Single-frame classes never turn.
function Entity:draw_angle_rad(angle_steps)
    if angle_steps <= 1 then return 0 end
    return self.angle * math.pi / 180
end

return Entity
