-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local json   = require "lib.json"
local Config = require "engine.core.config"

-- Impact feedback, presentation only: the hit flash on armed enemies (EXTRA
-- hit_flash; buildings and props do not flash) and the camera shake (EXTRA
-- camera_shake). The simulation reaches it one way through the World forwarders (World:hit_flash, :explosion_light, :player_hit,
-- :player_death_light, :weapon_fired) and never reads it back, like LightFX and audio
-- (DETERMINISM.md D2). Timings and strengths are data/impact_fx.json.
--
-- A hit flash redraws the damaged sprite as a white silhouette that fades over
-- hit_flash.time. A shake source sits at a world position and fades with time
-- and with distance from each camera's focus, so a co-op half barely feels its
-- partner's hits; Camera:apply adds the summed offset in world units.
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

function ImpactFX:player_hit(x, y)
    self:_shake(x, y, self.data.shake and self.data.shake.player_hit)
end

function ImpactFX:player_death(x, y)
    self:_shake(x, y, self.data.shake and self.data.shake.player_death)
end

function ImpactFX:update(dt)
    self.clock = self.clock + dt
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

-- queries

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
