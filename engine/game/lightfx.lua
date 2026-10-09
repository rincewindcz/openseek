-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Config = require "engine.core.config"
local json   = require "lib.json"

-- Screen lighting and flash effects. Two independent passes composited over the
-- world (below the HUD):
--
--   draw_night()    A light map applied to the whole world view of a night
--                   stage. The map starts at a per-mission ambient tone and
--                   gathers the vehicle headlights (a long soft beam plus a pool
--                   around the vehicle), the transient point lights of
--                   explosions and muzzle flashes, and the lights carried by
--                   burning things. The world is drawn into a target of its own
--                   (begin_scene) and multiplied by the map on the way back, so
--                   a lit pixel can come out brighter than its art: the night
--                   palette is dark to begin with, and the original's own night
--                   spot doubled what it covered. With Config.night_lighting
--                   off the pass draws that spot instead: the stage in its
--                   bare palette and one disc ahead of each vehicle.
--
--   draw_additive() Oversaturation over everything: brief world-anchored bright
--                   circles at explosions, the glow of live fire and full-screen
--                   colour flashes for big detonations. Additive, so it blows
--                   past 1.0 as bloom. Runs on any stage, night or day.
--
-- Emitters (explosion / muzzle) are fed from the combat and entity code via the
-- World forwarder, which no-ops when the effect system is disabled, so scenes
-- that never draw the passes do not accumulate state. Fire needs no emitter:
-- each tick the live rounds and effects are read for the ones that carry a
-- light (data/lightfx.json "weapons" and "effects").
local LightFX = Class()

local DATA_PATH = "data/lightfx.json"

-- Explosion size string (entity/weapon "explosion_<size>") -> light + burst, and
-- a screen flash for the largest. Radii are in world units (scaled by the camera
-- zoom at draw time); colours are warm firelight.
local EXPLOSIONS = {
    large  = { radius = 130, intensity = 1.5, color = { 1.0, 0.72, 0.38 },
               burst = 95, ttl = 0.45, flash = { 0.10, { 1.0, 0.78, 0.5 } } },
    medium = { radius = 88,  intensity = 1.1, color = { 1.0, 0.72, 0.40 },
               burst = 62, ttl = 0.35 },
    small  = { radius = 72,  intensity = 1.0, color = { 1.0, 0.74, 0.44 },
               burst = 50, ttl = 0.32 },
    flak   = { radius = 62,  intensity = 0.9, color = { 1.0, 0.86, 0.55 },
               burst = 42, ttl = 0.30 },
}

-- Night look of a mission the data file does not list.
local DEFAULT_NIGHT = {
    ambient   = { 0.84, 0.87, 1.0 },
    max_light = 2.4,
    headlight = { color = { 1.0, 0.93, 0.76 }, gap = 6, length = 300, spread_deg = 40,
                  intensity = 1.4, pool_radius = 120, pool_ahead = 24, pool_intensity = 0.35 },
}

local SPOT_SIZE = 256   -- radial gradient sprite resolution
local BEAM_SIZE = 256   -- headlight beam sprite resolution

-- The light map holds light / LIGHT_RANGE, so it can carry up to that many
-- times the art's own brightness in a normalized target.
local LIGHT_RANGE = 4

-- How long a burning effect takes to reach and to leave its full light, as
-- shares of its life.
local EFFECT_FADE_IN  = 0.1
local EFFECT_FADE_OUT = 0.4

-- The original's night light, the only one it has: a disc on the vehicle's
-- axis, 110 px ahead of it, under which every pixel becomes the palette colour
-- nearest to twice its own plus 16 of the 63 steps of a VGA channel. The disc
-- is the mask of the original's spot sprite, 47 px across, which is exactly
-- the pixels within NIGHT_SPOT_REACH (squared) of its centre pixel. Without a
-- palette here the sum is taken as it is.
local NIGHT_SPOT_SIZE  = 47
local NIGHT_SPOT_REACH = 550
local NIGHT_SPOT_AHEAD = 110
local NIGHT_SPOT_GAIN  = 2
local NIGHT_SPOT_LIFT  = 16 / 63

local NIGHT_SPOT_SRC = [[
uniform Image mask;
uniform float gain;
uniform float lift;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
    vec3 art = Texel(tex, uv).rgb;
    vec3 lit = min(art * gain + vec3(lift), vec3(1.0));
    return vec4(mix(art, lit, step(0.5, Texel(mask, uv).r)), 1.0);
}
]]

-- Lights that pile up (a blast inside the beam) stop at max_light times the
-- art, short of burning every sprite under them to white.
local LIGHT_SRC = [[
uniform Image light_map;
uniform float range;
uniform float max_light;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
    vec3 light = min(Texel(light_map, uv).rgb * range, vec3(max_light));
    return vec4(Texel(tex, uv).rgb * light, 1.0);
}
]]

local data

local function load_data()
    if data then return data end
    local raw = love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    decoded = (ok and type(decoded) == "table") and decoded or {}
    data = {
        night   = decoded.night   or {},
        weapons = decoded.weapons or {},
        effects = decoded.effects or {},
    }
    return data
end

local function smoothstep(lo, hi, x)
    local t = math.max(0, math.min(1, (x - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)
end

-- A radial gradient (white core -> transparent edge) used for every soft light.
local function make_spot()
    local image = love.image.newImageData(SPOT_SIZE, SPOT_SIZE)
    local c     = (SPOT_SIZE - 1) / 2
    image:mapPixel(function(x, y)
        local dx, dy = (x - c) / c, (y - c) / c
        return 1, 1, 1, smoothstep(0, 1, 1 - math.sqrt(dx * dx + dy * dy))
    end)
    return love.graphics.newImage(image)
end

-- The mask of the original's night spot, one texel per original pixel.
local function make_night_spot()
    local image = love.image.newImageData(NIGHT_SPOT_SIZE, NIGHT_SPOT_SIZE)
    local c     = (NIGHT_SPOT_SIZE - 1) / 2
    image:mapPixel(function(x, y)
        local inside = (x - c) * (x - c) + (y - c) * (y - c) <= NIGHT_SPOT_REACH
        return 1, 1, 1, inside and 1 or 0
    end)
    local mask = love.graphics.newImage(image)
    mask:setFilter("nearest", "nearest")
    return mask
end

-- The headlight beam, pointing up from the bottom centre of the sprite: a cone
-- that opens from a narrow start, soft at its sides, brightest a little under
-- halfway out and fading to nothing at its far end. Drawn stretched to the
-- beam's length and spread.
local function make_beam()
    local image = love.image.newImageData(BEAM_SIZE, BEAM_SIZE)
    local half  = (BEAM_SIZE - 1) / 2
    image:mapPixel(function(x, y)
        local along = 1 - y / (BEAM_SIZE - 1)
        local side  = math.abs(x - half) / half / (0.12 + 0.88 * along)
        local reach = smoothstep(0, 0.12, along) * (1 - smoothstep(0.5, 1, along))
        return 1, 1, 1, reach * (1 - smoothstep(0, 1, side))
    end)
    return love.graphics.newImage(image)
end

function LightFX:init()
    self.spot         = make_spot()
    self.beam         = make_beam()
    self.night_spot   = make_night_spot()
    self.shader       = love.graphics.newShader(LIGHT_SRC)
    self.spot_shader  = love.graphics.newShader(NIGHT_SPOT_SRC)
    self.enabled      = false
    self.world        = nil     -- the stage being lit, for its players and its fire
    self.night        = nil     -- active night params, or nil on day stages
    self.lights       = {}      -- {x, y, radius, r, g, b, intensity, t, ttl}
    self.bursts       = {}      -- {x, y, radius, r, g, b, t, dur}
    self.flashes      = {}      -- {r, g, b, a, t, dur}
    self.sources      = {}      -- {x, y, spec, strength}: live fire, rebuilt each tick
    self.source_count = 0
    self.scene        = nil     -- the world view of a night stage, before lighting
    self.map          = nil
    self.cw           = 0
    self.ch           = 0
    self.scene_on     = false
    self.scene_prev   = nil
end

-- Enable the system for a stage and pick its night look (nil on day stages).
function LightFX:enter(world)
    self:reset()
    self.enabled = true
    self.world   = world
    if world and world:is_night() then
        local night = load_data().night
        local m     = world.stage_name and world.stage_name:match("^stage(%d)")
        self.night  = night[m] or night.default or DEFAULT_NIGHT
    end
end

function LightFX:reset()
    self.enabled      = false
    self.world        = nil
    self.night        = nil
    self.lights       = {}
    self.bursts       = {}
    self.flashes      = {}
    self.sources      = {}
    self.source_count = 0
    self.scene_on     = false
end

-- emitters

-- Explosion of the given size string: a fading point light (seen at night) plus
-- an additive burst (seen on any stage), and a screen flash for the largest.
function LightFX:explosion(x, y, size)
    if not self.enabled then return end
    local e = EXPLOSIONS[size]
    if not e then return end
    self.lights[#self.lights + 1] = {
        x = x, y = y, radius = e.radius, intensity = e.intensity,
        r = e.color[1], g = e.color[2], b = e.color[3], t = 0, ttl = e.ttl,
    }
    self.bursts[#self.bursts + 1] = {
        x = x, y = y, radius = e.burst,
        r = e.color[1], g = e.color[2], b = e.color[3], t = 0, dur = e.ttl,
    }
    -- A bright white core pop so every explosion reads as a flash, over the warm
    -- burst above.
    self.bursts[#self.bursts + 1] = {
        x = x, y = y, radius = e.burst * 0.55,
        r = 1.0, g = 0.96, b = 0.86, t = 0, dur = 0.12,
    }
    if e.flash then
        local c = e.flash[2]
        self:flash(c[1], c[2], c[3], e.flash[1], 0.35)
    end
end

-- The player vehicle's death: a much larger and longer light + burst than any
-- ordinary explosion, plus a strong full-screen wash, so losing a vehicle reads
-- as a major event.
function LightFX:player_death(x, y)
    if not self.enabled then return end
    self.lights[#self.lights + 1] = {
        x = x, y = y, radius = 270, intensity = 2.4,
        r = 1.0, g = 0.80, b = 0.48, t = 0, ttl = 0.75,
    }
    self.bursts[#self.bursts + 1] = {
        x = x, y = y, radius = 210,
        r = 1.0, g = 0.74, b = 0.42, t = 0, dur = 0.6,
    }
    self.bursts[#self.bursts + 1] = {
        x = x, y = y, radius = 120,
        r = 1.0, g = 0.97, b = 0.90, t = 0, dur = 0.22,
    }
    self:flash(1.0, 0.86, 0.6, 0.55, 0.6)
end

-- Muzzle flash at the gun for any shooter. The point light only reads under the
-- night light map; the bright pop shows on any stage.
function LightFX:muzzle(x, y)
    if not self.enabled then return end
    if self.night then
        self.lights[#self.lights + 1] = {
            x = x, y = y, radius = 34, intensity = 0.9,
            r = 1.0, g = 0.9, b = 0.6, t = 0, ttl = 0.08,
        }
    end
    self.bursts[#self.bursts + 1] = {
        x = x, y = y, radius = 14,
        r = 1.0, g = 0.95, b = 0.7, t = 0, dur = 0.08,
    }
end

-- Full-screen additive colour wash that fades over dur seconds.
function LightFX:flash(r, g, b, a, dur)
    if not self.enabled then return end
    self.flashes[#self.flashes + 1] = { r = r, g = g, b = b, a = a, t = 0, dur = dur }
end

-- update

local function age(list, dt)
    local live, n = {}, 0
    for _, it in ipairs(list) do
        it.t = it.t + dt
        if it.t < (it.ttl or it.dur) then n = n + 1; live[n] = it end
    end
    return live
end

function LightFX:_add_source(x, y, spec, strength)
    local n = self.source_count + 1
    local s = self.sources[n]
    if not s then
        s = {}
        self.sources[n] = s
    end
    s.x, s.y, s.spec, s.strength = x, y, spec, strength
    self.source_count = n
end

-- The lights of everything burning this tick: rounds in flight whose weapon
-- carries one (dimming over their range by the weapon's fade) and ignited
-- effects whose clip does (rising and dying with the effect).
function LightFX:_collect_sources()
    self.source_count = 0
    local combat = self.world and self.world.combat
    if not combat then return end
    local specs = load_data()
    for _, projectile in ipairs(combat.projectiles) do
        local spec = specs.weapons[projectile.weapon]
        if spec and projectile.alive then
            local strength = 1
            if spec.fade and projectile.max_range then
                strength = 1 - spec.fade * math.min(1, projectile.traveled / projectile.max_range)
            end
            self:_add_source(projectile.x, projectile.y, spec, strength)
        end
    end
    for _, effect in ipairs(combat.effects) do
        local spec = specs.effects[effect.clip]
        local life = effect.age - effect.delay
        if spec and life >= 0 then
            local t = effect.lifetime and life / effect.lifetime or effect.anim:progress()
            local strength = math.min(1, t / EFFECT_FADE_IN, (1 - t) / EFFECT_FADE_OUT)
            if strength > 0 then
                self:_add_source(effect.x, effect.y, spec, strength * (effect.scale or 1))
            end
        end
    end
end

function LightFX:update(dt)
    if not self.enabled then return end
    self.lights  = age(self.lights, dt)
    self.bursts  = age(self.bursts, dt)
    self.flashes = age(self.flashes, dt)
    self:_collect_sources()
end

-- draw

function LightFX:_stamp(sx, sy, screen_radius, r, g, b, a)
    local s = (2 * screen_radius) / SPOT_SIZE
    love.graphics.setColor(r * a, g * a, b * a, 1)
    love.graphics.draw(self.spot, sx, sy, 0, s, s, SPOT_SIZE / 2, SPOT_SIZE / 2)
end

-- Brightness of source i this frame: its strength under a flame's flicker, two
-- sines out of step so it never settles into a pulse.
local function flicker(source, i, now)
    local depth = source.spec.flicker or 0
    local wave  = 0.5 + 0.25 * (math.sin(now * 23 + i * 1.7) + math.sin(now * 37 + i * 2.9))
    return source.strength * (1 - depth * wave)
end

-- The headlights of every vehicle still running, into the light map: a pool
-- around the vehicle to see its surroundings by, and the beam ahead of it.
function LightFX:_headlights(camera)
    local combat = self.world and self.world.combat
    if not combat then return end
    local h      = self.night.headlight
    local z      = camera:zoom()
    local col    = h.color
    local width  = 2 * h.length * math.tan(math.rad(h.spread_deg)) * z / BEAM_SIZE
    local length = h.length * z / BEAM_SIZE
    local beam   = h.intensity / LIGHT_RANGE
    for _, p in ipairs(combat.players or {}) do
        if not p.death then
            local sx, sy = camera:project(p.x, p.y)
            local rot    = math.rad(p.angle) + (camera.angle or 0)
            local fx, fy = math.sin(rot), -math.cos(rot)
            local ahead  = (h.pool_ahead or 0) * z
            self:_stamp(sx + fx * ahead, sy + fy * ahead, h.pool_radius * z,
                col[1], col[2], col[3], h.pool_intensity / LIGHT_RANGE)
            love.graphics.setColor(col[1] * beam, col[2] * beam, col[3] * beam, 1)
            love.graphics.draw(self.beam, sx + fx * h.gap * z, sy + fy * h.gap * z, rot,
                width, length, BEAM_SIZE / 2, BEAM_SIZE)
        end
    end
end

function LightFX:_ensure(w, h)
    if self.scene and self.cw == w and self.ch == h then return end
    local g = love.graphics
    -- A float map keeps the dim end of the range smooth; without one the beam
    -- shows faint bands.
    -- LOVE 12 renamed the query and warns on screen about the old name.
    local query   = rawget(g, "getTextureFormats")
    local formats = query and query({ canvas = true }) or g.getCanvasFormats()
    local format  = formats.rgba16f and "rgba16f" or "normal"
    self.scene = g.newCanvas(w, h)
    self.map   = g.newCanvas(w, h, { format = format })
    self.cw, self.ch = w, h
end

-- Start of a world pass. A night stage draws into a target of its own until
-- draw_night lights it; a day stage draws straight through. Keeps the caller's
-- transform and scissor, and clears the whole target so split-screen halves
-- never show each other's pixels.
function LightFX:begin_scene()
    self.scene_on = self.enabled and self.night ~= nil
    if not self.scene_on then return end
    local g = love.graphics
    self:_ensure(g.getDimensions())
    self.scene_prev = g.getCanvas()
    g.setCanvas(self.scene)
    local clip_x, clip_y, clip_w, clip_h = g.getScissor()
    g.setScissor()
    g.clear(0, 0, 0, 1)
    if clip_x then g.setScissor(clip_x, clip_y, clip_w, clip_h) end
end

-- The light map of a night stage: the ambient tone, the headlights, the
-- transient lights and everything burning.
function LightFX:_draw_light_map(camera)
    local g  = love.graphics
    local a  = self.night.ambient
    local br = Config.night_brightness / LIGHT_RANGE   -- lifts the floor toward daylight
    g.clear(a[1] * br, a[2] * br, a[3] * br, 1)
    g.setBlendMode("add")
    self:_headlights(camera)
    local z = camera:zoom()
    for _, l in ipairs(self.lights) do
        local sx, sy = camera:project(l.x, l.y)
        local fade   = 1 - l.t / l.ttl
        self:_stamp(sx, sy, l.radius * z, l.r, l.g, l.b, l.intensity * fade / LIGHT_RANGE)
    end
    local now = love.timer.getTime()
    for i = 1, self.source_count do
        local s      = self.sources[i]
        local spec   = s.spec
        local sx, sy = camera:project(s.x, s.y)
        self:_stamp(sx, sy, spec.radius * z, spec.color[1], spec.color[2], spec.color[3],
            spec.intensity * flicker(s, i, now) / LIGHT_RANGE)
    end
end

-- The original's night spot ahead of every vehicle still running, as a mask.
function LightFX:_draw_spot_mask(camera)
    local g = love.graphics
    g.clear(0, 0, 0, 1)
    local combat = self.world and self.world.combat
    if not combat then return end
    local z = camera:zoom()
    g.setColor(1, 1, 1, 1)
    for _, p in ipairs(combat.players or {}) do
        if not p.death then
            local sx, sy = camera:project(p.x, p.y)
            local rot    = math.rad(p.angle) + (camera.angle or 0)
            g.draw(self.night_spot, sx, sy, rot, z, z, NIGHT_SPOT_SIZE / 2, NIGHT_SPOT_SIZE / 2 + NIGHT_SPOT_AHEAD)
        end
    end
end

-- Pass A: light the world of a night stage and lay it onto the target the
-- pass started on. After the world, entities and effects have been drawn.
function LightFX:draw_night(camera)
    if not self.scene_on then return end
    self.scene_on = false
    local g   = love.graphics
    local lit = Config.night_lighting

    -- The light map (or the spot mask) is built under the caller's transform,
    -- like the world it lights (a split-screen half is translated to its
    -- place), over the whole target; the lit world is then laid down target
    -- for target, inside the caller's scissor.
    local clip_x, clip_y, clip_w, clip_h = g.getScissor()
    g.setCanvas(self.scene_prev)
    g.push("all")
    g.setScissor()
    g.setCanvas(self.map)
    if lit then self:_draw_light_map(camera) else self:_draw_spot_mask(camera) end

    g.origin()
    g.setCanvas(self.scene_prev)
    if clip_x then g.setScissor(clip_x, clip_y, clip_w, clip_h) end
    g.setBlendMode("replace", "premultiplied")
    g.setColor(1, 1, 1, 1)
    if lit then
        self.shader:send("light_map", self.map)
        self.shader:send("range", LIGHT_RANGE)
        self.shader:send("max_light", self.night.max_light or DEFAULT_NIGHT.max_light)
        g.setShader(self.shader)
    else
        self.spot_shader:send("mask", self.map)
        self.spot_shader:send("gain", NIGHT_SPOT_GAIN)
        self.spot_shader:send("lift", NIGHT_SPOT_LIFT)
        g.setShader(self.spot_shader)
    end
    g.draw(self.scene)
    g.pop()
end

-- Pass B: additive oversaturation over the composited scene (any stage). Bursts
-- and the glow of live fire are world-anchored; flashes wash the whole screen.
function LightFX:draw_additive(camera)
    if not (self.enabled and Config.effects_flashes) then return end
    local g = love.graphics
    if #self.bursts == 0 and #self.flashes == 0 and self.source_count == 0 then return end
    local fi = Config.flash_intensity   -- master brightness of the flash layer
    local z  = camera:zoom()
    g.setBlendMode("add")
    for _, b in ipairs(self.bursts) do
        local sx, sy = camera:project(b.x, b.y)
        local k      = 1 - b.t / b.dur
        self:_stamp(sx, sy, b.radius * z, b.r, b.g, b.b, k * k * fi)
    end
    local now = love.timer.getTime()
    for i = 1, self.source_count do
        local s    = self.sources[i]
        local spec = s.spec
        if spec.glow then
            local sx, sy = camera:project(s.x, s.y)
            self:_stamp(sx, sy, (spec.glow_radius or spec.radius) * z,
                spec.color[1], spec.color[2], spec.color[3], spec.glow * flicker(s, i, now) * fi)
        end
    end
    local w, hgt = g.getDimensions()
    for _, f in ipairs(self.flashes) do
        local k = (1 - f.t / f.dur) * fi
        g.setColor(f.r * f.a * k, f.g * f.a * k, f.b * f.a * k, 1)
        g.rectangle("fill", 0, 0, w, hgt)
    end
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
end

return LightFX
