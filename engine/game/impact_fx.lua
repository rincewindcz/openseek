-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local json   = require "lib.json"
local Config = require "engine.core.config"

-- Impact feedback, presentation only: the hit flash on armed enemies (EXTRA
-- hit_flash; buildings and props do not flash), the camera shake (EXTRA
-- camera_shake) and the low armor warning over a player's view (EXTRA
-- low_armor_fx, damage_flash; drawn by PostFX). The simulation reaches it one
-- way through the World forwarders (World:hit_flash, :explosion_light,
-- :player_hit, :player_death_light, :weapon_fired) and never reads it back, like
-- LightFX and audio. Timings and strengths are data/impact_fx.json.
--
-- A hit flash redraws the damaged sprite as a white silhouette that fades over
-- hit_flash.time. A shake source sits at a world position and fades with time
-- and with distance from each camera's focus, so a co-op half barely feels its
-- partner's hits; Camera:apply adds the summed offset in world units. The low
-- armor warning keeps a level per player that eases toward how far its armor is
-- below low_armor.threshold, and a pulse phase that quickens as the armor drops.
local ImpactFX = Class()

local DATA_PATH = "data/impact_fx.json"

local SILHOUETTE_SRC = [[
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen)
{
    return vec4(color.rgb, Texel(tex, uv).a * color.a);
}
]]

function ImpactFX:init()
    local raw       = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    self.data       = raw and json.decode(raw) or {}
    self.flashes    = setmetatable({}, { __mode = "k" })   -- target -> seconds left
    self.shakes     = {}                                   -- {x, y, amount, radius, time, t, phase}
    self.alarms     = setmetatable({}, { __mode = "k" })   -- player -> {level, phase, hit}
    self.alarm      = {}                                   -- reused PostFX parameters
    self.world_size = nil
    self.clock      = 0
    self.shader     = nil
end

function ImpactFX:enter(world)
    self:reset()
    self.world_size = world and world.stage and world.stage.world_size or nil
end

function ImpactFX:reset()
    self.flashes = setmetatable({}, { __mode = "k" })
    self.shakes  = {}
    self.alarms  = setmetatable({}, { __mode = "k" })
end

-- emitters

-- EXTRA (hit_flash): target was damaged this tick.
function ImpactFX:hit(target)
    local spec = self.data.hit_flash
    if not Config.hit_flash or not spec then return end
    self.flashes[target] = spec.time
end

-- EXTRA (camera_shake): a shake source from a data/impact_fx.json shake entry.
function ImpactFX:_shake(x, y, spec)
    if not Config.camera_shake or not spec then return end
    self.shakes[#self.shakes + 1] = {
        x = x, y = y, amount = spec.amount, radius = spec.radius, time = spec.time,
        t = 0, phase = math.random() * 2 * math.pi,
    }
end

function ImpactFX:explosion(x, y, size)
    local shake = self.data.shake
    self:_shake(x, y, shake and shake.explosion and shake.explosion[size])
end

-- A weapon fired at (x, y); only weapons listed under shake.fire shake.
function ImpactFX:fire(x, y, weapon_name)
    local fire = self.data.shake and self.data.shake.fire
    self:_shake(x, y, fire and fire[weapon_name])
end

function ImpactFX:player_hit(x, y, player)
    self:_shake(x, y, self.data.shake and self.data.shake.player_hit)
    -- EXTRA (damage_flash): every hit flashes the view's edges.
    local spec = self.data.low_armor
    if Config.damage_flash and spec and player then
        self:_alarm_state(player).hit = spec.hit_time
    end
end

function ImpactFX:player_death(x, y)
    self:_shake(x, y, self.data.shake and self.data.shake.player_death)
end

function ImpactFX:update(dt, players)
    self.clock = self.clock + dt
    self:_update_alarms(dt, players)
    for target, left in pairs(self.flashes) do
        left = left - dt
        self.flashes[target] = left > 0 and left or nil
    end
    local live = {}
    for _, s in ipairs(self.shakes) do
        s.t = s.t + dt
        if s.t < s.time then live[#live + 1] = s end
    end
    self.shakes = live
end

-- How far below low_armor.threshold the player's armor is: 0 at or above it
-- (or once destroyed), 1 at no armor.
function ImpactFX:_armor_short(player, spec)
    if player.death then return 0 end
    local max_armor = player.max_armor or 100
    local fraction  = max_armor > 0 and player.armor / max_armor or 1
    if fraction >= spec.threshold then return 0 end
    return 1 - fraction / spec.threshold
end

function ImpactFX:_alarm_state(player)
    local state = self.alarms[player]
    if not state then
        state = { level = 0, phase = 0, hit = 0 }
        self.alarms[player] = state
    end
    return state
end

-- EXTRA (low_armor_fx): ease each player's level toward its armor shortfall
-- (low_armor.floor at the threshold, 1 at no armor) at low_armor.fade per second.
function ImpactFX:_update_alarms(dt, players)
    local spec = self.data.low_armor
    if not spec then return end
    for _, p in ipairs(players or {}) do
        local state  = self:_alarm_state(p)
        local short  = Config.low_armor_fx and self:_armor_short(p, spec) or 0
        local target = short > 0 and (spec.floor + (1 - spec.floor) * short) or 0
        local step   = dt * spec.fade
        if state.level < target then
            state.level = math.min(target, state.level + step)
        else
            state.level = math.max(target, state.level - step)
        end
        local hz    = spec.pulse_hz[1] + (spec.pulse_hz[2] - spec.pulse_hz[1]) * short
        state.phase = (state.phase + dt * hz) % 1
        state.hit   = math.max(0, state.hit - dt)
    end
end

-- queries

-- EXTRA (low_armor_fx, damage_flash): the PostFX warning parameters for the view
-- of player, or nil when it shows nothing. The returned table is reused.
function ImpactFX:low_armor(player)
    local spec  = self.data.low_armor
    local state = spec and player and self.alarms[player]
    if not state then return nil end
    local pulse = 0.5 + 0.5 * math.sin(state.phase * 2 * math.pi)
    local edge  = state.level * spec.edge * (1 - spec.pulse + spec.pulse * pulse)
                + spec.hit_edge * state.hit / spec.hit_time
    local desaturate = state.level * spec.desaturate
    if edge <= 0 and desaturate <= 0 then return nil end
    local alarm      = self.alarm
    alarm.edge       = math.min(1, edge)
    alarm.desaturate = desaturate
    alarm.color      = spec.color
    alarm.inner      = spec.inner
    alarm.outer      = spec.outer
    return alarm
end

-- Shortest wrapped distance between two world points on the seamless map.
function ImpactFX:_distance(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local size = self.world_size
    if size then
        dx = dx % size; if dx > size * 0.5 then dx = dx - size end
        dy = dy % size; if dy > size * 0.5 then dy = dy - size end
    end
    return math.sqrt(dx * dx + dy * dy)
end

-- EXTRA (camera_shake): summed offset, in world units, for a camera focused at
-- (x, y). Each source falls off quadratically in time and linearly with
-- distance; the total is capped at shake.max. Config.camera_shake_amount
-- scales both.
function ImpactFX:shake_offset(x, y)
    local spec = self.data.shake
    if not spec or #self.shakes == 0 then return 0, 0 end
    local ox, oy = 0, 0
    for _, s in ipairs(self.shakes) do
        local reach = 1 - self:_distance(x, y, s.x, s.y) / s.radius
        if reach > 0 then
            local fade = (1 - s.t / s.time) ^ 2
            local amp  = s.amount * reach * fade
            local w    = self.clock * spec.hz * 2 * math.pi
            ox = ox + amp * math.sin(w + s.phase)
            oy = oy + amp * math.sin(w * 1.31 + s.phase * 1.7)
        end
    end
    local scale = Config.camera_shake_amount
    local cap   = spec.max * scale
    ox, oy = ox * scale, oy * scale
    local len = math.sqrt(ox * ox + oy * oy)
    if len > cap then
        ox, oy = ox * cap / len, oy * cap / len
    end
    return ox, oy
end

-- EXTRA (hit_flash): draws a flashing target's sprite again as a white
-- silhouette, with the same arguments as the love.graphics.draw that drew it.
-- No-op when the target is not flashing.
function ImpactFX:draw_flash(target, img, ...)
    local left = self.flashes[target]
    local spec = self.data.hit_flash
    if not left or not spec then return end
    local g = love.graphics
    self.shader = self.shader or g.newShader(SILHOUETTE_SRC)
    local r, gr, b, a = g.getColor()
    g.setShader(self.shader)
    g.setColor(1, 1, 1, spec.strength * left / spec.time)
    g.draw(img, ...)
    g.setShader()
    g.setColor(r, gr, b, a)
end

return ImpactFX
