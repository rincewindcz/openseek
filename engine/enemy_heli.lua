local Class     = require "engine.class"
local Animation = require "engine.animation"
local Config    = require "engine.config"
local Shadow    = require "engine.shadow"
local Mathx     = require "engine.core.mathx"

-- Each spawned heli gets exactly one of these, picked at random. air_to_air uses
-- its locking level so the missile homes (the original game's heli weapon);
-- machine_gun is the per-mission tracer streak. Firing is bursty: it looses a
-- volley of `burst` shots `intra` seconds apart, then waits `cooldown` seconds so
-- the player gets a clear window to dodge and shoot back.
local WEAPON_POOL = {
    { weapon = "chaingun",    level = 1, burst = 3, intra = 0.13, cooldown = 1.8 },
    { weapon = "homing_missile", level = 1, burst = 1, intra = 0,    cooldown = 3.2 },
    { weapon = "air_to_air",  level = 2, burst = 1, intra = 0,    cooldown = 3.0 },
    { weapon = "machine_gun", level = 1, burst = 4, intra = 0.11, cooldown = 2.0 },
}

local SPEED      = 110    -- forward cruise (px/s); slower than the player so it can be engaged
local TURN_RATE  = 120    -- deg/s heading slew
local ORBIT_R    = 270    -- radius it tries to circle the player at
local ATTACK_R   = 360    -- range within which it will fire
local FIRE_CONE  = 32     -- deg; the nose must be this close to the player to shoot
local HIT_RADIUS   = 13
local MAX_HP       = 60
local SPAWN_DELAY  = 2.5 -- gap between spawns while below the cap
local DYING_TIME   = 1.1 -- fall/burn time before the wreck blows, like the player heli
local BLAST_RADIUS = 70
local BLAST_DAMAGE = 40
local SPRITE_ROT   = 0   -- extra rotation if the badheli frame 0 is not nose-north
local ROTOR_SPEED  = 15  -- rad/s the rotor disc spins (one blade frame, rotated)

local HeliSystem = Class()

function HeliSystem:init(world, combat)
    self.world  = world
    self.combat = combat
    self.helis  = {}
    self.spawns = {}
    self.sprite = nil
    self.max    = 0
    self.timer  = SPAWN_DELAY
    self.rotor_img = nil
    self.rotor_ax, self.rotor_ay = 0, 0
    self.kills  = 0   -- enemy helicopters shot down (end-of-phase stats)
end

-- Read the stage's spawn markers and the badheli render image. Called on each
-- stage load / player spawn.
function HeliSystem:reset()
    self.helis  = {}
    self.spawns = self.world.heli_spawns or {}
    self.max    = #self.spawns
    self.timer  = SPAWN_DELAY
    self.kills  = 0
    self.world.air_units = self.helis
    self.sprite = nil
    for _, c in ipairs(self.world.stage.classes) do
        if c.kind_name == "enemy_helicopter" then
            local r = self.world.images[c.index + 1]
            if r and r.img then self.sprite = r.img; break end
        end
    end
    -- Single rotor frame, spun with love2d rotation rather than cycling the blur
    -- arc frames (which looked wrong top-down). Anchor on the blade's art center.
    local clip = Animation.clip("blade")
    if clip and clip.frames[1] then
        self.rotor_img = clip.frames[1]
        self.rotor_ax, self.rotor_ay = clip:anchor(1)
    end
end

function HeliSystem:clear()
    self.helis = {}
    self.max   = 0
    self.world.air_units = self.helis
end

function HeliSystem:_view_radius()
    local cam = self.combat.camera
    local vw, vh = cam:dims()
    return math.max(vw, vh) / cam:zoom() / 2
end

function HeliSystem:_spawn_one(player)
    if #self.spawns == 0 or not self.sprite then return end
    -- Prefer a marker currently off-screen so the heli flies in from outside view.
    local vr = self:_view_radius() * 1.1
    local choices = {}
    for _, s in ipairs(self.spawns) do
        local dx, dy = self.world:delta(s.x, s.y, player.x, player.y)
        if dx * dx + dy * dy > vr * vr then choices[#choices + 1] = s end
    end
    if #choices == 0 then choices = self.spawns end
    local s    = choices[math.random(#choices)]
    local pick = WEAPON_POOL[math.random(#WEAPON_POOL)]
    local dx, dy = self.world:delta(player.x, player.y, s.x, s.y)
    local heli = {
        x = s.x, y = s.y,
        heading = Mathx.heading_deg(dx, dy),
        hp = MAX_HP, max_hp = MAX_HP,
        weapon = pick.weapon, level = pick.level,
        burst = pick.burst, intra = pick.intra, cooldown = pick.cooldown,
        burst_left = pick.burst,
        dir = (math.random() < 0.5) and 1 or -1,
        phase = math.random() * math.pi * 2,
        reload = 0.8,
        smoke = {}, smoke_t = 0, hitfx = {},
        rotor_spin = math.random() * math.pi * 2,
        hit_radius = HIT_RADIUS,
        state = "alive",
    }
    self.helis[#self.helis + 1] = heli
end

-- Player projectile landed on this heli (called from CombatSystem:_check_hit).
function HeliSystem:hit(heli, dmg, shooter)
    if heli.state ~= "alive" then return end
    heli.hp = heli.hp - dmg
    -- A scorch burst on the hull at each hit, like the original (fire loops, so it
    -- needs a lifetime; smoke2 plays once and culls itself).
    local clip = math.random() < 0.5 and "fire" or "smoke2"
    heli.hitfx[#heli.hitfx + 1] = {
        anim     = Animation.new(clip), age = 0,
        lifetime = clip == "fire" and 0.5 or nil,
        ox = (math.random() - 0.5) * 18, oy = (math.random() - 0.5) * 18,
    }
    if heli.hp <= 0 then
        heli.hp    = 0
        heli.state = "dying"
        heli.die_t = 0
        self.kills = (self.kills or 0) + 1
        if shooter then
            shooter.score = (shooter.score or 0) + 70
            if shooter.stat_kills then
                shooter.stat_kills.chopper = (shooter.stat_kills.chopper or 0) + 1
            end
        end
    end
end

function HeliSystem:update(dt)
    if self.max == 0 then return end

    local live = 0
    for _, heli in ipairs(self.helis) do if heli.state ~= "removed" then live = live + 1 end end
    self.timer = self.timer - dt
    if live < self.max and self.timer <= 0 then
        local p = self.combat.player
        if p and not p.death and (p.armor or 0) > 0 then
            self:_spawn_one(p)
            self.timer = SPAWN_DELAY
        end
    end

    local keep = {}
    for _, heli in ipairs(self.helis) do
        self:_update_heli(heli, dt)
        if heli.state ~= "removed" then keep[#keep + 1] = heli end
    end
    self.helis = keep
    self.world.air_units = self.helis
end

function HeliSystem:_advance(heli, dt, factor)
    local rad  = (heli.heading - 90) * math.pi / 180
    local step = SPEED * (factor or 1) * dt * Config.speed_scale
    local s    = self.world.stage.world_size
    heli.x = (heli.x + math.cos(rad) * step) % s
    heli.y = (heli.y + math.sin(rad) * step) % s
end

function HeliSystem:_update_heli(heli, dt)
    heli.rotor_spin = (heli.rotor_spin + dt * ROTOR_SPEED) % (math.pi * 2)
    self:_update_smoke(heli, dt)
    self:_update_hitfx(heli, dt)
    if heli.state == "dying" then return self:_update_dying(heli, dt) end

    local p = self.combat:_nearest_player(heli.x, heli.y)
    if not p then self:_advance(heli, dt); return end

    local dx, dy   = self.world:delta(p.x, p.y, heli.x, heli.y)   -- player relative to heli
    local dist     = math.sqrt(dx * dx + dy * dy)
    local toplayer = Mathx.heading_deg(dx, dy)

    -- Far: head straight at the player. Near: circle, sweeping the nose between
    -- nearly tangential and pointing at the player so it lines up to shoot.
    local target
    if dist > ORBIT_R * 1.25 then
        target = toplayer
    else
        heli.phase = heli.phase + dt * 1.7 * Config.speed_scale
        local offset = 55 + 50 * math.sin(heli.phase)   -- 5..105 deg off the player
        target = (toplayer + heli.dir * offset) % 360
    end

    local diff = ((target - heli.heading + 180) % 360) - 180
    local step = TURN_RATE * dt * Config.speed_scale
    if math.abs(diff) <= step then heli.heading = target
    else heli.heading = (heli.heading + (diff > 0 and step or -step)) % 360 end

    self:_advance(heli, dt)

    heli.reload = heli.reload - dt
    local face   = math.abs(((toplayer - heli.heading + 180) % 360) - 180)
    local mid    = heli.burst_left < heli.burst                  -- already firing this volley
    local can_start = dist <= ATTACK_R and face <= FIRE_CONE
    -- A volley only starts when the nose is on the player and in range; once it has,
    -- it commits to all `burst` rounds (the burst is brief, so the nose barely
    -- drifts) and then waits out the long cooldown. That makes a clear shoot/pause
    -- rhythm instead of a constant stream.
    if heli.reload <= 0 and (mid or can_start) then
        self.combat:tick_swing(heli, heli.weapon)
        self.combat:fire(heli.x, heli.y, heli.heading, heli.weapon, heli, heli.level, ATTACK_R * 1.2)
        heli.burst_left = heli.burst_left - 1
        if heli.burst_left > 0 then
            heli.reload = heli.intra
        else
            heli.burst_left = heli.burst
            heli.reload = heli.cooldown
        end
    end
end

-- Downed heli: like the player's, it falls (spins, shrinks, trailing fire/smoke)
-- then blows up with the shared explosion, shrapnel/dust, and a small blast.
function HeliSystem:_update_dying(heli, dt)
    heli.die_t = heli.die_t + dt
    heli.spin  = (heli.spin or 0) + dt * 320
    heli.fall  = math.min(1, (heli.fall or 0) + dt / DYING_TIME)
    self:_advance(heli, dt, 0.5)
    heli.fire_t = (heli.fire_t or 0) - dt
    if heli.fire_t <= 0 then
        heli.fire_t = 0.12
        heli.smoke[#heli.smoke + 1] = {
            x = heli.x + (math.random() - 0.5) * 16, y = heli.y + (math.random() - 0.5) * 16,
            vx = 0, vy = 0, lifetime = 0.6,
            anim = Animation.new(math.random() < 0.5 and "fire" or "smoke"),
        }
    end
    if heli.die_t >= DYING_TIME then
        self.combat:add_effect("explosion_large", heli.x, heli.y, {})
        self.world:spawn_debris(heli.x, heli.y, 5 + math.random(0, 3), 1.3)
        self:_blast(heli)
        heli.state = "removed"
        self.timer = math.min(self.timer, SPAWN_DELAY)
    end
end

function HeliSystem:_blast(heli)
    for _, p in ipairs(self.combat.players) do
        if p and (p.armor or 0) > 0 and not p.death and not p.unlimited then
            local dx, dy = self.world:delta(p.x, p.y, heli.x, heli.y)
            if dx * dx + dy * dy < BLAST_RADIUS * BLAST_RADIUS then
                p.armor = math.max(0, p.armor - BLAST_DAMAGE)
            end
        end
    end
end

-- One-shot fire/smoke2 scorches riding on the hull where rounds connect.
function HeliSystem:_update_hitfx(heli, dt)
    if #heli.hitfx == 0 then return end
    local live = {}
    for _, fx in ipairs(heli.hitfx) do
        fx.anim:update(dt)
        fx.age = fx.age + dt
        local expired = (fx.lifetime and fx.age >= fx.lifetime) or fx.anim:is_done()
        if not expired then live[#live + 1] = fx end
    end
    heli.hitfx = live
end

function HeliSystem:_update_smoke(heli, dt)
    local live = {}
    for _, s in ipairs(heli.smoke) do
        s.age = (s.age or 0) + dt
        s.x = s.x + (s.vx or 0) * dt
        s.y = s.y + (s.vy or 0) * dt
        s.anim:update(dt)
        if not (s.anim:is_done() or (s.lifetime and s.age >= s.lifetime)) then live[#live + 1] = s end
    end
    heli.smoke = live
    if heli.state ~= "alive" then return end

    -- Damage smoke ramps with lost armor, like the player vehicle, drifting along
    -- the heading at a fraction of cruise speed so it streams behind.
    local pct    = heli.hp / heli.max_hp
    local target = 0
    if pct < 0.6  then target = 1 end
    if pct < 0.35 then target = 2 end
    if pct < 0.2  then target = 3 end
    local n = 0
    for _, s in ipairs(heli.smoke) do if s.dmg then n = n + 1 end end
    if n < target then
        heli.smoke_t = heli.smoke_t - dt
        if heli.smoke_t <= 0 then
            heli.smoke_t = 0.06 + math.random() * 0.1
            local rad   = (heli.heading - 90) * math.pi / 180
            local drift = (0.3 + math.random() * 0.4) * SPEED
            heli.smoke[#heli.smoke + 1] = {
                x = heli.x + (math.random() - 0.5) * 14, y = heli.y + (math.random() - 0.5) * 14,
                vx = math.cos(rad) * drift, vy = math.sin(rad) * drift,
                dmg = true, anim = Animation.new("smoke"),
            }
        end
    end
end

-- Ground shadows for every live heli, drawn before the hulls (a flat black body
-- silhouette slid out in the fixed world bottom-right). The offset is in world
-- space so the camera rotation swings it around like the player's; a downed heli's
-- shadow shrinks to nothing as it falls. Disabled on night missions.
function HeliSystem:draw_shadows()
    if #self.helis == 0 or not self.sprite then return end
    if not self.world:shadows_enabled() then return end
    local g   = love.graphics
    local cam = self.combat.camera
    local iw, ih = self.sprite:getDimensions()
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        for _, heli in ipairs(self.helis) do
            if heli.state ~= "removed" then
                local alt = 1 - (heli.fall or 0)
                if alt > 0 then
                    local shadow_offset = Shadow.OFFSET * alt
                    local rot           = (heli.heading + (heli.spin or 0) + SPRITE_ROT) * math.pi / 180
                    local fall_scale    = 1 - 0.5 * (heli.fall or 0)
                    Shadow.draw(self.sprite,
                        heli.x + Shadow.DIR_X * shadow_offset, heli.y + Shadow.DIR_Y * shadow_offset,
                        rot, fall_scale, fall_scale, iw / 2, ih / 2, Shadow.ALPHA * alt)
                end
            end
        end
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

function HeliSystem:draw()
    if #self.helis == 0 or not self.sprite then return end
    local g   = love.graphics
    local cam = self.combat.camera
    local iw, ih = self.sprite:getDimensions()
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        for _, heli in ipairs(self.helis) do
            for _, s in ipairs(heli.smoke) do
                local img = s.anim:current_image()
                if img then
                    local img_w, img_h = img:getDimensions()
                    g.setColor(1, 1, 1, 0.85)
                    g.draw(img, s.x, s.y, 0, 1, 1, img_w / 2, img_h / 2)
                end
            end
            if heli.state ~= "removed" then
                local rot        = (heli.heading + (heli.spin or 0) + SPRITE_ROT) * math.pi / 180
                local fall_scale = 1 - 0.5 * (heli.fall or 0)
                g.setColor(1, 1, 1)
                g.draw(self.sprite, heli.x, heli.y, rot, fall_scale, fall_scale, iw / 2, ih / 2)
                -- Spinning rotor disc on top: one blade frame rotated, not the blur arc.
                if self.rotor_img then
                    g.draw(self.rotor_img, heli.x, heli.y, heli.rotor_spin, fall_scale, fall_scale,
                        self.rotor_ax, self.rotor_ay)
                end
                -- Hit scorches (fire / smoke2) ride on top of the hull.
                for _, fx in ipairs(heli.hitfx) do
                    local img = fx.anim:current_image()
                    if img then
                        local fw, fh = img:getDimensions()
                        g.draw(img, heli.x + fx.ox, heli.y + fx.oy, 0, 1, 1, fw / 2, fh / 2)
                    end
                end
            end
        end
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

return HeliSystem
