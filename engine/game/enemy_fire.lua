-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local json       = require "lib.json"
local Config     = require "engine.core.config"
local Mathx      = require "engine.core.mathx"
local Difficulty = require "engine.game.difficulty"

-- Enemy fire as the original game runs it. Every gun plays one of the twenty
-- firing routines its stage class names (Entity.fire_routine): which rounds
-- leave on a volley, how the volleys group into bursts, and how long the reload
-- is on each difficulty. Soldiers, helicopters and proximity mines have their
-- own rules. data/enemy_weapons.json holds all of it in the original's units:
-- times in ticks of 1 / tick_rate seconds, three values meaning EASY / MEDIUM /
-- HARD. The rounds themselves are the enemy_* entries of data/weapons.json.
-- Driven by CombatSystem:_update_ai; simulation code.
local EnemyFire = Class()

local DATA_PATH = "data/enemy_weapons.json"

function EnemyFire:init(world, combat)
    self.world  = world
    self.combat = combat
    local raw = love.filesystem.read(DATA_PATH)
    if not raw then error("enemy_fire: missing " .. DATA_PATH) end
    self.data      = json.decode(raw)
    self.tick_rate = self.data.tick_rate or 70
end

-- A tick count (plain, or one per difficulty) for the current fire level.
local function level_ticks(value)
    if type(value) == "table" then return value[Difficulty.fire_level()] or 0 end
    return value or 0
end

function EnemyFire:_seconds(ticks)
    return ticks / self.tick_rate
end

-- Turn e's aim toward heading target (degrees) by at most step. Returns the
-- error left, 0 once the aim is on it.
local function turn_toward(e, target, step)
    local diff = ((target - e.aim_angle + 180) % 360) - 180
    if math.abs(diff) <= step then
        e.aim_angle = target
        return 0
    end
    e.aim_angle = (e.aim_angle + (diff > 0 and step or -step)) % 360
    return math.abs(diff) - step
end

function EnemyFire:routine(id)
    return self.data.routines[tostring(id)]
end

-- Radius within which e tracks a player (its kind's detection_radius): the
-- original only runs a unit that is on screen, which the simulation may not
-- depend on.
function EnemyFire:active_radius(e)
    return (e.type_data.detection_radius or 0) * Config.enemy_aggression
end

-- One round of a volley: forward and side are pixels along and to the right
-- of the barrel, a side list alternates per volley, angle is degrees off it.
function EnemyFire:_shoot(e, shot, aim)
    local side = shot.side or 0
    if type(side) == "table" then side = side[(e.volleys - 1) % #side + 1] end
    local forward = shot.forward or 0
    local rad     = (aim - 90) * math.pi / 180
    local fx, fy  = math.cos(rad), math.sin(rad)
    self.combat:fire(e.x + fx * forward - fy * side, e.y + fy * forward + fx * side,
        (aim + (shot.angle or 0)) % 360, shot.weapon, e, 1)
end

-- Fire spec's volley from e along aim. A shot marked reloading only leaves
-- between volleys; in a cycle, a shot leaves on its own volley of it.
function EnemyFire:volley(e, spec, aim)
    e.volleys = (e.volleys or 0) + 1
    local turn = spec.cycle and ((e.volleys - 1) % spec.cycle + 1)
    for _, shot in ipairs(spec.shots) do
        if not shot.reloading and (not shot.volley or shot.volley == turn) then
            self:_shoot(e, shot, aim)
        end
    end
end

-- Seconds until e's next volley: the reload, a random extra, and the pause
-- that closes a burst.
function EnemyFire:_reload(e, spec)
    local ticks = level_ticks(spec.reload)
    if spec.reload_random then ticks = ticks + self.world.rng:random(0, spec.reload_random) end
    if spec.burst then
        e.burst_count = (e.burst_count or 0) + 1
        if e.burst_count >= spec.burst then
            e.burst_count = 0
            ticks = ticks + level_ticks(spec.pause)
        end
    end
    return self:_seconds(ticks) / Config.enemy_fire_rate
end

-- A gun, standing or on a tank hull: it turns toward the player (dx, dy away,
-- d2 squared), and fires its routine once the player is within its kind's
-- attack_range and the aim has stayed inside the routine's arc for the settle
-- time.
function EnemyFire:turret(e, dx, dy, d2, dt, can_fire)
    local spec   = self:routine(e.fire_routine)
    local common = self.data.turret
    if not spec then return end
    local step  = (spec.turn or common.turn) * dt * Config.speed_scale
    local off   = turn_toward(e, Mathx.heading_deg(dx, dy), step)
    local range = (e.type_data.attack_range or 0) * Config.enemy_aggression
    if not can_fire or d2 > range * range then return end
    if off > (spec.arc or common.arc) then
        e.reload = self:_seconds(common.settle)
        return
    end
    local before = e.reload
    e.reload = e.reload - dt
    -- Side rounds that leave each time the reload passes a multiple of `every`.
    for _, shot in ipairs(spec.shots) do
        if shot.every and e.reload > 0 then
            local period = self:_seconds(shot.every) / Config.enemy_fire_rate
            if math.floor(before / period) > math.floor(e.reload / period) then
                e.volleys = e.volleys or 1
                self:_shoot(e, shot, e.aim_angle)
            end
        end
    end
    if e.reload <= 0 then
        self:volley(e, spec, e.aim_angle)
        -- Added to the overshoot, so a reload of a few ticks keeps its rate.
        e.reload = e.reload + self:_reload(e, spec)
    end
end

-- A soldier snaps round to the player and fires when facing it. fire_mode
-- (the class behaviour) picks the weapon: a bullet, or a homing missile.
function EnemyFire:soldier(e, dx, dy, dt)
    local spec = self.data.soldier
    local off  = turn_toward(e, Mathx.heading_deg(dx, dy), spec.turn * dt * Config.speed_scale)
    e.reload = math.max(0, e.reload - dt)
    if off > 0 or e.reload > 0 then return end
    local weapon = spec.weapons[tostring(e.fire_mode or 0)] or spec.weapons["0"]
    self.combat:fire(e.x, e.y, e.aim_angle, weapon, e, 1)
    local ticks = spec.reload + self.world.rng:random(0, spec.reload_random or 0)
    e.reload = self:_seconds(ticks) / Config.enemy_fire_rate
end

-- A proximity mine: a player (p, the nearest live one or nil) coming within
-- the trigger radius lights its fuse; when it runs out the mine blows and takes
-- armor if a player is still that close.
function EnemyFire:mine(e, p, dt)
    local spec = self.data.mine
    local near = false
    if p then
        local dx, dy = self.world:delta(p.x, p.y, e.x, e.y)
        near = dx * dx + dy * dy < spec.trigger * spec.trigger
    end
    if not e.mine_fuse then
        if near then e.mine_fuse = spec.fuse end
        return
    end
    e.mine_fuse = e.mine_fuse - dt
    if e.mine_fuse > 0 then return end
    if near and not p.unlimited then
        p.armor        = math.max(0, p.armor - spec.damage[Difficulty.damage_level()] * Config.enemy_damage)
        p.damage_cause = "enemy_mine"
    end
    e:take_damage(e.hp + 1)
end

-- Seconds between a homing round's bearing updates. kind is "ground" or
-- "air"; every radar (ground) or radio tower (air) destroyed this phase makes
-- the missiles of that kind track more loosely.
function EnemyFire:homing_refresh(kind)
    local spec  = self.data.homing
    local ticks = level_ticks(spec.refresh[kind])
        + (spec.penalty or 0) * (self.world.homing_jam[kind] or 0)
    return self:_seconds(ticks)
end

-- An enemy helicopter's weapon for its class behaviour: {weapon, reload,
-- reload_random, turn_scale}.
function EnemyFire:heli_mode(behaviour)
    local modes = self.data.helicopter.modes
    return modes[tostring(behaviour or 0)] or modes["0"]
end

-- Seconds until a helicopter's next shot.
function EnemyFire:heli_reload(mode)
    local ticks = mode.reload + (mode.reload_random and self.world.rng:random(0, mode.reload_random) or 0)
    return self:_seconds(ticks) / Config.enemy_fire_rate
end

return EnemyFire
