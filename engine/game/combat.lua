local Class     = require "engine.core.class"
local json      = require "lib.json"
local Animation = require "engine.core.animation"
local Config    = require "engine.core.config"
local Mathx     = require "engine.core.mathx"
local Stats     = require "engine.game.stats"

-- Projectile

local Projectile = Class()

function Projectile:init(p)
    self.x          = p.x
    self.y          = p.y
    self.vx         = p.vx
    self.vy         = p.vy
    self.damage     = p.damage
    self.aoe        = p.aoe  or 0
    self.owner      = p.owner
    self.shooter    = p.shooter   -- firing Player (player rounds only), for score / friendly fire
    self.lifetime   = p.lifetime
    self.radius     = p.radius
    self.weapon_def = p.weapon_def
    self.angle_rad  = p.angle_rad  -- Love2D draw rotation (radians)
    self.max_range  = p.max_range
    self.accel      = p.accel or 0  -- forward acceleration (px/s^2), e.g. tracers
    self.traveled   = 0
    self.trail          = p.trail            -- effect clip dropped along the path
    self.trail_interval = p.trail_interval or 14
    self._trail_dist    = 0
    self.alive      = true
    self.scale      = 1
    -- Resolved draw sprite (the per-mission tracer streak overrides weapon_def.proj_sprite).
    self.sprite     = p.sprite or (p.weapon_def and p.weapon_def.proj_sprite)
    -- Animated sprite (e.g. the growing tracer streak); plays once, holds last frame.
    if p.animate then self.anim = Animation.new(self.sprite) end
    -- Bomb: glides forward while falling away (the sprite shrinks). Both motions
    -- are eased, so it covers most of its forward distance early and creeps the
    -- rest while shrinking faster toward the end. It never collides in flight.
    if self.weapon_def and self.weapon_def.proj_type == "bomb_drop" then
        self.bomb_phase = "drop"
        self.bomb_t     = 0
        self.bomb_x0    = self.x
        self.bomb_y0    = self.y
        local speed_now = math.sqrt(self.vx * self.vx + self.vy * self.vy)
        self.bomb_dx    = speed_now > 0 and self.vx / speed_now or 0
        self.bomb_dy    = speed_now > 0 and self.vy / speed_now or 0
    end
end

-- A dropped bomb eases forward (fast then slow) while shrinking (slow then fast)
-- to fake a bomb thrown ahead and falling away from the camera. It never
-- collides in flight; CombatSystem detonates it where it lands.
local BOMB_MIN_SCALE = 0.15
function Projectile:_update_bomb(dt)
    self.bomb_t = self.bomb_t + dt
    local dur = self.weapon_def.fall_time or 0.6
    local t   = math.min(1, self.bomb_t / dur)
    local fwd = 1 - (1 - t) * (1 - t)              -- ease-out forward glide
    local dist = (self.weapon_def.fly_distance or 140) * fwd
    self.x = self.bomb_x0 + self.bomb_dx * dist
    self.y = self.bomb_y0 + self.bomb_dy * dist
    self.scale = 1 - (1 - BOMB_MIN_SCALE) * (t * t) -- ease-in shrink
    if self.anim then self.anim:update(dt) end
    if t >= 1 then self.alive = false end
end

function Projectile:update(dt)
    if self.bomb_phase then return self:_update_bomb(dt) end
    if self.accel > 0 then
        local speed_now = math.sqrt(self.vx * self.vx + self.vy * self.vy)
        if speed_now > 0 then
            local new_speed = speed_now + self.accel * dt
            self.vx = self.vx / speed_now * new_speed
            self.vy = self.vy / speed_now * new_speed
        end
    end
    local sdt = dt * Config.speed_scale
    local dx = self.vx * sdt
    local dy = self.vy * sdt
    self.x = self.x + dx
    self.y = self.y + dy
    local step = math.sqrt(dx * dx + dy * dy)
    self.traveled = self.traveled + step
    if self.trail then self._trail_dist = self._trail_dist + step end
    if self.max_range and self.traveled >= self.max_range then self.alive = false end
    if self.anim then self.anim:update(dt) end
    self.lifetime = self.lifetime - dt
    if self.lifetime <= 0 then self.alive = false end
end

function Projectile:get_image()
    if not self.sprite then return nil end
    if self.anim then return self.anim:current_image() end
    local clip = Animation.clip(self.sprite)
    if not clip or #clip.frames == 0 then return nil end
    return clip.frames[1]
end

-- Draw origin that centers the sprite's visible art on the projectile position.
function Projectile:get_anchor()
    if not self.sprite then return 0, 0 end
    local frame = self.anim and self.anim.frame or 1
    return Animation.frame_anchor(self.sprite, frame)
end

-- CombatSystem

-- The enemy tracer streak ships under a different BIN per mission (mission 3 has
-- none, so it keeps the default). weapons.json names the generic "trace"; the
-- matching per-mission clip is swapped in at fire time from the world's mission.
local TRACER_SPRITE = { [0] = "trace", [1] = "strace", [2] = "jtrace", [4] = "rtrace" }

-- One of these bursts on the player's vehicle each time an enemy round connects.
local PLAYER_HIT_FX = { "fire", "missile_smoke", "smoke2" }

local CombatSystem = Class()

function CombatSystem:init(world, camera)
    self.world       = world
    self.camera      = camera
    self.player      = nil
    self.players     = {}   -- all controllable players (1 normally, 2 in split screen)
    self.heli_sys    = nil  -- enemy helicopter system (set by main); its helis are hittable
    self.friendly_fire = false  -- co-op option: player rounds can hit the other player
    self.projectiles = {}
    self.effects     = {}   -- transient world anims (missile trails, napalm fire)
    self.weapons     = {}
    self._swing      = {}
    self._alt        = {}   -- per owner+weapon side toggle for alternate_side weapons
end

-- Spawn a transient world-space effect. opts: {rot, scale, damage, radius, lifetime}.
-- A damage effect applies its damage once to entities within radius. lifetime
-- bounds looping clips (napalm fire); non-looping clips also cull when their
-- anim ends.
function CombatSystem:add_effect(clip_name, x, y, opts)
    opts = opts or {}
    local anim = Animation.new(clip_name)
    if anim:is_done() then return end
    self.effects[#self.effects + 1] = {
        anim     = anim,
        x        = x,
        y        = y,
        rot      = opts.rot   or 0,
        scale    = opts.scale or 1,
        damage   = opts.damage,
        radius   = opts.radius or 0,
        lifetime = opts.lifetime,
        delay    = opts.delay or 0,   -- seconds before the effect ignites (napalm wave)
        age      = 0,
        hit      = false,
    }
end

function CombatSystem:load(path)
    local raw = love.filesystem.read(path)
    if not raw then error("combat: missing " .. path) end
    self.weapons = json.decode(raw)
end

-- Draw sprite for a weapon's projectile, swapping in the current mission's tracer.
function CombatSystem:_resolve_sprite(weapon_def)
    local sprite = weapon_def.proj_sprite
    if weapon_def.proj_type == "tracer" and self.world and self.world.stage_name then
        local m    = tonumber(self.world.stage_name:match("^stage(%d)"))
        local name = m and TRACER_SPRITE[m]
        if name and Animation.clip(name) then sprite = name end
    end
    return sprite
end

function CombatSystem:fire(x, y, angle_deg, weapon_name, owner, level_idx, range_override, shooter)
    local weapon_def = self.weapons[weapon_name]
    if not weapon_def then return end
    level_idx = level_idx or 1
    local level = (weapon_def.levels and weapon_def.levels[level_idx]) or weapon_def

    -- Forward direction in world space (angle_deg: 0=north CW)
    local rad     = (angle_deg - 90) * math.pi / 180
    local fwd_x   = math.cos(rad)
    local fwd_y   = math.sin(rad)
    -- Right-perpendicular (90 deg CW in Y-down screen space): (-fwd_y, fwd_x)
    local right_x = -fwd_y
    local right_y =  fwd_x

    -- Napalm and similar: a widening cone of ground fire ahead, no projectiles.
    if weapon_def.proj_type == "flame" then
        return self:_fire_flame(x, y, fwd_x, fwd_y, rad, weapon_def, level)
    end

    -- Range cap: player shots are limited to ~1.5x the visible screen so they
    -- cannot cross the map; enemies pass their attack range so their shots reach.
    local screen_w, screen_h = love.graphics.getDimensions()
    local view               = math.max(screen_w, screen_h) / self.camera:zoom()
    local max_range          = range_override or (1.5 * view)

    -- Multi-frame projectile sprites animate (the tracer streak that grows).
    local sprite    = self:_resolve_sprite(weapon_def)
    local clip      = sprite and Animation.clip(sprite)
    local animate   = clip and #clip.frames > 1 or false

    local speed      = weapon_def.speed or 0
    local spread     = (level.spread_deg or weapon_def.spread_deg or 0) * math.pi / 180
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
    if weapon_def.alternate_side then
        local key = tostring(owner) .. weapon_name
        alt_sign = (self._alt[key] == 1) and -1 or 1
        self._alt[key] = alt_sign
    end

    -- Lock-on: locking missile levels (player) and homing enemy weapons steer
    -- toward a target each frame at a limited turn rate, so the shot can be
    -- evaded by quick maneuvering.
    local homing    = level.locking or weapon_def.homing or false
    local turn_rate = level.turn_rate or weapon_def.turn_rate or 90
    local target
    if homing then
        if owner == "player" then
            target = self:_nearest_enemy(x, y, max_range)
        else
            target = self:_nearest_player(x, y)
        end
        if not target then homing = false end
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
            ox = right_x * dist
            oy = right_y * dist
        elseif side > 0 and total > 1 then
            local dist = (i - (total + 1) / 2) * side / math.max(1, total - 1)
            ox = right_x * dist
            oy = right_y * dist
        end
        if weapon_def.alternate_side then
            ox = right_x * side * alt_sign
            oy = right_y * side * alt_sign
        end

        local fire_rad = rad + angle_off
        local projectile = Projectile:new({
            x          = x + ox,
            y          = y + oy,
            vx         = math.cos(fire_rad) * speed,
            vy         = math.sin(fire_rad) * speed,
            damage     = level.damage      or weapon_def.damage or 10,
            aoe        = weapon_def.aoe    or 0,
            owner      = owner,
            shooter    = shooter,
            lifetime   = weapon_def.lifetime    or 2,
            radius     = weapon_def.proj_radius or 3,
            weapon_def = weapon_def,
            sprite     = sprite,
            max_range  = max_range,
            accel      = weapon_def.proj_accel or 0,
            animate    = animate,
            trail          = weapon_def.trail,
            trail_interval = weapon_def.trail_interval,
            -- Rotation for drawing: angle_deg in our CW-from-north system maps to Love2D radians
            angle_rad  = angle_deg * math.pi / 180 + angle_off,
        })
        if homing then
            projectile.homing    = true
            projectile.turn_rate = turn_rate
            projectile.target    = target
        end
        self.projectiles[#self.projectiles + 1] = projectile
    end
end

-- Napalm: along each of the level's angle offsets (relative to aim), lay a ray of
-- `count` fire patches that ignite outward from the chopper (the wave). Level 1 =
-- one tongue ahead, level 2 = a -45/0/45 fan, level 3 = an 8-way ring.
function CombatSystem:_fire_flame(x, y, _fwd_x, _fwd_y, rad, weapon_def, level)
    local angles   = level.angles or { 0 }
    local count    = level.count   or weapon_def.count   or 8
    local spacing  = level.spacing or weapon_def.spacing or 20
    local wave     = weapon_def.wave_delay or 0.04
    local dmg      = level.damage   or weapon_def.damage or 40
    local radius   = weapon_def.aoe       or 22
    local scale    = weapon_def.fire_scale or 1
    local lifetime = weapon_def.fire_lifetime or 1.0
    for _, a in ipairs(angles) do
        local dir    = rad + a * math.pi / 180
        local cx, cy = math.cos(dir), math.sin(dir)
        for i = 1, count do
            local d = i * spacing
            self:add_effect(weapon_def.effect or "fire", x + cx * d, y + cy * d,
                { damage = dmg, radius = radius, scale = scale, lifetime = lifetime, delay = (i - 1) * wave })
        end
    end
end

function CombatSystem:tick_swing(owner, weapon_name)
    local key = tostring(owner) .. weapon_name
    if not self._swing[key] then self._swing[key] = 0 end
end

-- Angular threshold (deg) within which a turret/soldier is considered locked on.
local LOCK_DEG = 8
-- How long before its next shot a patrolling tank slows to a stop (then resumes).
local STOP_LEAD = 0.8

-- Nearest live player to a point, or nil if every player is down. Split screen
-- has two; enemies engage whichever is closer.
function CombatSystem:_nearest_player(x, y)
    local best, best_d2
    for _, p in ipairs(self.players) do
        if p and not p.death and (p.armor or 0) > 0 then
            local dx, dy = self.world:delta(p.x, p.y, x, y)
            local d2 = dx * dx + dy * dy
            if not best_d2 or d2 < best_d2 then best, best_d2 = p, d2 end
        end
    end
    return best
end

-- Nearest live, damageable entity to a point within range (lock-on target for
-- the player's homing missiles).
function CombatSystem:_nearest_enemy(x, y, range)
    local best, best_d2
    local r2 = range and range * range or nil
    for _, e in ipairs(self.world.entities) do
        if e:is_alive() and e.type_data and (e.type_data.hit_radius or 0) > 0 then
            local dx, dy = self.world:delta(e.x, e.y, x, y)
            local d2 = dx * dx + dy * dy
            if (not r2 or d2 <= r2) and (not best_d2 or d2 < best_d2) then
                best, best_d2 = e, d2
            end
        end
    end
    return best
end

-- Rotate a homing projectile's velocity toward its (moving) target, capped at
-- its turn rate so a nimble player can shake it. A dead/landed target drops the
-- lock and the missile flies straight on.
function CombatSystem:_steer_homing(projectile, dt)
    local tgt = projectile.target
    if not tgt then return end
    local lost
    if tgt.is_alive then lost = not tgt:is_alive()
    else lost = (tgt.armor or 0) <= 0 or tgt.death ~= nil end
    if lost then projectile.target = nil; return end

    local dx, dy   = self.world:delta(tgt.x, tgt.y, projectile.x, projectile.y)
    local desired  = Mathx.atan2(dy, dx)
    local cur      = Mathx.atan2(projectile.vy, projectile.vx)
    local diff     = ((desired - cur + math.pi) % (2 * math.pi)) - math.pi
    local maxstep  = math.rad(projectile.turn_rate) * dt * Config.speed_scale
    if diff >  maxstep then diff =  maxstep end
    if diff < -maxstep then diff = -maxstep end
    local new_angle = cur + diff
    local speed_now = math.sqrt(projectile.vx * projectile.vx + projectile.vy * projectile.vy)
    projectile.vx = math.cos(new_angle) * speed_now
    projectile.vy = math.sin(new_angle) * speed_now
    projectile.angle_rad = new_angle + math.pi / 2   -- sprite points north at frame 0; align to travel
end

-- Drive enemy aiming and firing. Each combatant rotates its aim toward the
-- nearest player at its turn_speed, and fires its weapon when locked and in range.
function CombatSystem:_update_ai(dt)
    for _, e in ipairs(self.world.combatants) do
        local p = e:is_alive() and self:_nearest_player(e.x, e.y) or nil
        if p then
            local td  = e.type_data
            local dx, dy = self.world:delta(p.x, p.y, e.x, e.y)
            local d2  = dx * dx + dy * dy
            local detection = td.detection_radius or 0
            e.engaging = false
            if detection > 0 and d2 <= detection * detection then
                local target = Mathx.heading_deg(dx, dy)
                local diff   = ((target - e.aim_angle + 180) % 360) - 180
                local step   = (td.turn_speed or 90) * dt * Config.speed_scale
                if math.abs(diff) <= step then
                    e.aim_angle = target
                else
                    e.aim_angle = (e.aim_angle + (diff > 0 and step or -step)) % 360
                end
                -- Single-sprite turrets (flak) rotate the whole sprite via e.angle;
                -- two-part tanks keep the hull fixed and spin only the turret overlay,
                -- which the renderer draws from aim_angle.
                if not e.has_turret then e.angle = e.aim_angle end

                local attack_range = td.attack_range or detection
                local weapon       = e.weapon or td.weapon
                -- Patrol only pauses for the brief window around each shot (slow to a
                -- stop as the reload comes up, fire, then resume), not the whole time
                -- the player is in range.
                e.engaging         = d2 <= attack_range * attack_range and e.reload <= STOP_LEAD
                local can_fire = (not e.has_turret) or e.turret_alive
                if can_fire and math.abs(diff) < LOCK_DEG and d2 <= attack_range * attack_range then
                    e.reload = e.reload - dt
                    if e.reload <= 0 then
                        -- owner is the firing entity so alternate_side / swing toggles are
                        -- tracked per turret (e.g. each sgun alternates its own L/R barrel).
                        -- Spawn forward of the hull center by the turret's muzzle offset.
                        local sx, sy = e.x, e.y
                        local muzzle_offset = e.muzzle_offset or 0
                        if muzzle_offset ~= 0 then
                            local muzzle_rad = (e.aim_angle - 90) * math.pi / 180
                            sx = e.x + math.cos(muzzle_rad) * muzzle_offset
                            sy = e.y + math.sin(muzzle_rad) * muzzle_offset
                        end
                        self:fire(sx, sy, e.aim_angle, weapon, e, 1, attack_range * 1.3)
                        local w = self.weapons[weapon]
                        -- Per-stage fire-rate override (e.fire_rate) wins over the weapon's.
                        e.reload = 1 / (e.fire_rate or (w and w.fire_rate) or 1)
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
    for _, projectile in ipairs(self.projectiles) do
        if projectile.homing then self:_steer_homing(projectile, dt) end
        projectile:update(dt)
        -- Drop a trail puff every trail_interval px travelled.
        if projectile.trail and projectile._trail_dist >= projectile.trail_interval then
            projectile._trail_dist = 0
            self:add_effect(projectile.trail, projectile.x, projectile.y, {})
        end
        local ended
        if projectile.bomb_phase then
            -- Bombs do not collide in flight; they detonate when their fall completes.
            if projectile.alive then alive[#alive + 1] = projectile else self:_bomb_detonate(projectile) end
        elseif projectile.alive then
            if self:_check_hit(projectile) then
                ended = true
                self:_ffr_shrapnel(projectile)
            else alive[#alive + 1] = projectile end
        else
            ended = true
        end
        if ended then self:_end_projectile(projectile) end
    end
    self.projectiles = alive

    self:_update_effects(dt)
end

-- FFR (the rockets/"ffr" projectile) throws 1-3 fast METAL8 shards along its
-- travel direction wherever it connects, matching the original game's impact.
function CombatSystem:_ffr_shrapnel(projectile)
    if projectile.weapon_def.proj_sprite ~= "ffr" then return end
    local n = math.random(0, 2)
    if n > 0 then
        self.world:spawn_directional_debris(projectile.x, projectile.y, projectile.vx, projectile.vy, n, "metal8")
    end
end

-- An enemy round bursts into its explosion clip when it hits the player or fades
-- out (e.g. flak/sgun -> flakani). Player impacts are handled by entity deaths.
function CombatSystem:_end_projectile(projectile)
    if projectile.owner == "player" then return end
    -- Tracers just fade to nothing (handled in draw); they do not burst.
    if projectile.weapon_def.proj_type == "tracer" then return end
    local explosion_clip = projectile.weapon_def.explosion
    if explosion_clip and explosion_clip ~= "explosion_none" then
        self:add_effect(explosion_clip, projectile.x, projectile.y, {})
    end
end

function CombatSystem:_update_effects(dt)
    local live = {}
    for _, effect in ipairs(self.effects) do
        effect.age = effect.age + dt
        if effect.age >= effect.delay then            -- ignited
            effect.anim:update(dt)
            if effect.damage and not effect.hit then
                effect.hit = true
                local r2 = (effect.radius or 0) ^ 2
                for _, e in ipairs(self.world.entities) do
                    if e:is_alive() and (e.type_data and (e.type_data.hit_radius or 0) > 0) then
                        local dx, dy = self.world:delta(e.x, e.y, effect.x, effect.y)
                        if dx * dx + dy * dy < r2 then
                            e:on_hit()
                            e:take_damage(effect.damage, dx, dy)
                        end
                    end
                end
            end
        end
        local life    = effect.age - effect.delay
        local expired = (effect.lifetime and life >= effect.lifetime) or (life >= 0 and effect.anim:is_done())
        if not expired then live[#live + 1] = effect end
    end
    self.effects = live
end

-- Score awarded to the player who lands the killing hit.
function CombatSystem:_kill_points(e)
    return 50 + (e.max_hp or 0)
end

-- DESTRUCTION STATS category of a killed entity ("ground" / "building" / nil),
-- credited to the player who landed the killing hit (co-op per-player columns).
function CombatSystem:_credit_kill(shooter, e)
    if not (shooter and shooter.stat_kills) then return end
    local cls  = self.world.stage.classes[e.class_idx + 1]
    local kind = cls and cls.kind_name
    local cat  = Stats.kind_category(kind)
    if cat then shooter.stat_kills[cat] = (shooter.stat_kills[cat] or 0) + 1 end
end

-- The impact effect a weapon spawns on the entity it hits. A list picks at
-- random per hit (FFR alternates smoke/smoke2); a string is used as-is; nil lets
-- the entity fall back to its default.
function CombatSystem:_hit_clip(weapon_def)
    local h = weapon_def.hit_effect
    if type(h) == "table" then return h[math.random(#h)] end
    return h
end

function CombatSystem:_check_hit(projectile)
    if projectile.owner == "player" then
        for _, e in ipairs(self.world.entities) do
            if e:is_alive() then
                local hit_radius = e.type_data and e.type_data.hit_radius or 0
                if hit_radius > 0 then
                    local dx, dy = self.world:delta(e.x, e.y, projectile.x, projectile.y)
                    if dx * dx + dy * dy < (projectile.radius + hit_radius) ^ 2 then
                        e:on_hit(self:_hit_clip(projectile.weapon_def))
                        e:take_damage(projectile.damage, projectile.vx, projectile.vy)
                        if projectile.aoe > 0 then self:_apply_aoe(projectile) end
                        if projectile.shooter and not e:is_alive() then
                            projectile.shooter.score = (projectile.shooter.score or 0) + self:_kill_points(e)
                            self:_credit_kill(projectile.shooter, e)
                            if projectile.shooter.register_kill then projectile.shooter:register_kill() end
                        end
                        return true
                    end
                end
            end
        end
        -- Airborne enemy helicopters (owned by the heli system, not world.entities).
        if self.heli_sys then
            for _, h in ipairs(self.heli_sys.helis) do
                if h.state == "alive" then
                    local dx, dy = self.world:delta(h.x, h.y, projectile.x, projectile.y)
                    local hit_range = (h.hit_radius or 13) + projectile.radius
                    if dx * dx + dy * dy < hit_range * hit_range then
                        self.heli_sys:hit(h, projectile.damage, projectile.shooter)
                        if projectile.aoe > 0 then self:_apply_aoe(projectile) end
                        return true
                    end
                end
            end
        end
        -- The player's own fire can kill a walking POW when that option is on.
        if self.world.rescue and self.world.rescue:projectile_hit(projectile.x, projectile.y, projectile.radius, true) then
            return true
        end
        -- Friendly fire (co-op option): a player round can hit the other player.
        if self.friendly_fire then
            for _, p in ipairs(self.players) do
                if p ~= projectile.shooter and p.armor > 0 and not p.death then
                    local dx, dy = self.world:delta(p.x, p.y, projectile.x, projectile.y)
                    local hit_range = (p.collision_radius or 12) + projectile.radius
                    if dx * dx + dy * dy < hit_range * hit_range then
                        if not p.unlimited then p.armor = math.max(0, p.armor - projectile.damage) end
                        return true
                    end
                end
            end
        end
    else
        for _, p in ipairs(self.players) do
            if p and p.armor > 0 and not p.death then
                local dx, dy = self.world:delta(p.x, p.y, projectile.x, projectile.y)
                local hit_range = (p.collision_radius or 12) + projectile.radius
                if dx * dx + dy * dy < hit_range * hit_range then
                    if not p.unlimited then p.armor = math.max(0, p.armor - projectile.damage) end
                    self:_player_hit_fx(p)
                    return true
                end
            end
        end
        -- Enemy rounds always cut down a walking POW caught in the open.
        if self.world.rescue and self.world.rescue:projectile_hit(projectile.x, projectile.y, projectile.radius, false) then
            return true
        end
    end
    return false
end

-- A random scorch (fire / smoke) burst on the player's vehicle when it is hit.
-- Attached to the player so it draws on top of the vehicle, not under it.
function CombatSystem:_player_hit_fx(p)
    local clip = PLAYER_HIT_FX[math.random(#PLAYER_HIT_FX)]
    if p.add_hit_fx then
        p:add_hit_fx(clip, clip == "fire" and 0.6 or nil)
    else
        self:add_effect(clip, p.x, p.y, clip == "fire" and { lifetime = 0.6 } or {})
    end
end

-- A landed bomb: a big explosion, a scatter of iron/metal shrapnel, and full
-- damage to everything inside the blast radius.
function CombatSystem:_bomb_detonate(projectile)
    self:add_effect(projectile.weapon_def.explosion or "explosion_large", projectile.x, projectile.y, { scale = 1.5 })
    -- Same flying iron/metal shrapnel (and the dust it leaves) as a building blast.
    self.world:spawn_debris(projectile.x, projectile.y, 5 + math.random(0, 3), 1.4)
    local r  = projectile.aoe > 0 and projectile.aoe or 80
    local r2 = r * r
    for _, e in ipairs(self.world.entities) do
        if e:is_alive() and e.type_data and (e.type_data.hit_radius or 0) > 0 then
            local dx, dy = self.world:delta(e.x, e.y, projectile.x, projectile.y)
            if dx * dx + dy * dy < r2 then
                e:on_hit()
                e:take_damage(projectile.damage, dx, dy)
                if projectile.shooter and not e:is_alive() then
                    projectile.shooter.score = (projectile.shooter.score or 0) + self:_kill_points(e)
                    self:_credit_kill(projectile.shooter, e)
                    if projectile.shooter.register_kill then projectile.shooter:register_kill() end
                end
            end
        end
    end
end

function CombatSystem:_apply_aoe(projectile)
    local r2 = projectile.aoe ^ 2
    for _, e in ipairs(self.world.entities) do
        if e:is_alive() then
            local dx, dy = self.world:delta(e.x, e.y, projectile.x, projectile.y)
            if dx * dx + dy * dy < r2 then
                e:take_damage(projectile.damage * 0.5)
            end
        end
    end
end

function CombatSystem:draw()
    if #self.projectiles == 0 and #self.effects == 0 then return end
    local g = love.graphics
    g.push()
    self.camera:apply()

    -- Projectiles fly in unbounded coordinates; tiling the pass keeps shots near a
    -- player at the wrapped map edge drawn next to that player.
    for _, t in ipairs(self.camera:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)

        -- Transient effects (trails, napalm fire) draw under the projectiles.
        for _, effect in ipairs(self.effects) do
            local img = effect.age >= effect.delay and effect.anim:current_image() or nil
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1)
                g.draw(img, effect.x, effect.y, effect.rot, effect.scale, effect.scale, iw / 2, ih / 2)
            end
        end

        for _, projectile in ipairs(self.projectiles) do
            local weapon_def = projectile.weapon_def
            if weapon_def.proj_type == "bullet" then
                local c  = weapon_def.proj_color or {1, 1, 1}
                local sz = weapon_def.proj_size  or 2
                g.setColor(c[1], c[2], c[3], 1)
                g.rectangle("fill", projectile.x - sz / 2, projectile.y - sz / 2, sz, sz)
            else
                local img = projectile:get_image()
                if img then
                    local extra    = (weapon_def.proj_sprite_rot or 0) * math.pi / 180
                    local ax, ay   = projectile:get_anchor()
                    -- Tracers fade out over their last moments instead of bursting.
                    local alpha = weapon_def.proj_type == "tracer" and math.min(1, projectile.lifetime / 0.4) or 1
                    local scale = projectile.scale or 1
                    g.setColor(1, 1, 1, alpha)
                    g.draw(img, projectile.x, projectile.y, projectile.angle_rad + extra, scale, scale, ax, ay)
                end
            end
        end

        g.pop()
    end

    g.setColor(1, 1, 1)
    g.pop()
end

return CombatSystem
