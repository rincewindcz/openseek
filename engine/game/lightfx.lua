local Class  = require "engine.core.class"
local Config = require "engine.core.config"

-- Screen lighting and flash effects. Two independent passes composited over the
-- world (below the HUD):
--
--   draw_night()    A multiplicative light map. On night stages the whole scene
--                   is dimmed to a per-mission ambient tone, then brightened by
--                   the vehicle headlight (a soft warm cone plus a lit pool ahead)
--                   and by transient point lights emitted at explosions / muzzle
--                   flashes. Built into an offscreen canvas and drawn back with a
--                   "multiply" blend.
--
--   draw_additive() Oversaturation bursts on top of everything: brief world-
--                   anchored bright circles at explosions and full-screen colour
--                   flashes for big detonations. Additive, so they blow past 1.0
--                   as bloom. Runs on any stage, night or day.
--
-- Emitters (explosion / muzzle) are fed from the combat and entity code via the
-- World forwarder, which no-ops when the effect system is disabled, so scenes
-- that never draw the passes do not accumulate state.
local LightFX = Class()

-- Explosion size string (entity/weapon "explosion_<size>") -> light + burst, and
-- a screen flash for the largest. Radii are in world units (scaled by the camera
-- zoom at draw time); colours are warm firelight.
local EXPLOSIONS = {
    large  = { radius = 130, intensity = 1.5, color = { 1.0, 0.72, 0.38 },
               burst = 95, ttl = 0.45, flash = { 0.10, { 1.0, 0.78, 0.5 } } },
    medium = { radius = 88,  intensity = 1.1, color = { 1.0, 0.72, 0.40 },
               burst = 62, ttl = 0.35 },
    flak   = { radius = 62,  intensity = 0.9, color = { 1.0, 0.86, 0.55 },
               burst = 42, ttl = 0.30 },
}

-- Fallback night look when a mission defines no explicit params.
local DEFAULT_NIGHT = {
    ambient   = { 0.46, 0.49, 0.60 },
    headlight = { reach = 40, radius = 36, spread = 0.6,
                  color = { 1.0, 0.92, 0.72 }, intensity = 1.2, gap = 6 },
}

local SPOT_SIZE = 256   -- radial gradient sprite resolution
local CONE_SEGS = 16    -- headlight cone fan resolution

-- A radial gradient (white core -> transparent edge) used for every soft light.
local function make_spot()
    local data = love.image.newImageData(SPOT_SIZE, SPOT_SIZE)
    local c    = (SPOT_SIZE - 1) / 2
    data:mapPixel(function(x, y)
        local dx, dy = (x - c) / c, (y - c) / c
        local r = math.sqrt(dx * dx + dy * dy)
        local a = math.max(0, 1 - r)
        a = a * a * (3 - 2 * a)          -- smoothstep falloff
        return 1, 1, 1, a
    end)
    return love.graphics.newImage(data)
end

-- Triangle-fan cone pointing straight up (screen -y), apex at the origin, rim at
-- radius 1. Apex carries the light, the rim fades to zero. Rebuilt per stage so
-- the beam spread can vary by mission.
local function make_cone(spread, color, apex_a)
    local verts = { { 0, 0, 0.5, 0.5, color[1], color[2], color[3], apex_a } }
    for i = 0, CONE_SEGS do
        local a  = -math.pi / 2 + (i / CONE_SEGS - 0.5) * spread * 2
        verts[#verts + 1] = { math.cos(a), math.sin(a), 0, 0,
                              color[1], color[2], color[3], 0 }
    end
    local mesh = love.graphics.newMesh(verts, "fan", "static")
    return mesh
end

function LightFX:init()
    self.spot    = make_spot()
    self.cone    = nil
    self.enabled = false
    self.night   = nil     -- active night params, or nil on day stages
    self.lights  = {}      -- {x, y, radius, r, g, b, intensity, t, ttl}
    self.bursts  = {}      -- {x, y, radius, r, g, b, t, dur}
    self.flashes = {}      -- {r, g, b, a, t, dur}
    self.canvas       = nil
    self.cw           = 0
    self.ch           = 0
    self.headlight_on = true   -- cut when the player vehicle is destroyed
end

-- Enable the system for a stage. Reads the world's per-mission night params (nil
-- on day stages) and rebuilds the headlight cone.
function LightFX:enter(world)
    self:reset()
    self.enabled = true
    self.night   = world and world:night_params() or nil
    local h      = (self.night and self.night.headlight) or DEFAULT_NIGHT.headlight
    self.cone    = make_cone(h.spread, h.color, 0.22 * h.intensity)
end

function LightFX:reset()
    self.enabled = false
    self.night   = nil
    self.lights  = {}
    self.bursts  = {}
    self.flashes = {}
    self.headlight_on = true
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

function LightFX:update(dt)
    if not self.enabled then return end
    self.lights  = age(self.lights, dt)
    self.bursts  = age(self.bursts, dt)
    self.flashes = age(self.flashes, dt)
end

-- draw

function LightFX:_stamp(sx, sy, screen_radius, r, g, b, a)
    local s = (2 * screen_radius) / SPOT_SIZE
    love.graphics.setColor(r * a, g * a, b * a, 1)
    love.graphics.draw(self.spot, sx, sy, 0, s, s, SPOT_SIZE / 2, SPOT_SIZE / 2)
end

-- The vehicle headlight, in screen space. The world is drawn rotated so the
-- player always faces up, so the beam is a fixed shape above the focus point: a
-- warm cone from the vehicle widening into a soft lit pool ahead, with a faint
-- flicker.
function LightFX:_headlight(camera)
    local h        = self.night.headlight
    local cx, cy   = camera:screen_center()
    local z        = camera:zoom()
    local flick    = 0.94 + 0.06 * math.sin(love.timer.getTime() * 21)
    local reach    = h.reach * z
    local radius   = h.radius * z
    local apex_y   = cy - h.gap * z

    -- Cone bridging the lamp to the pool.
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(self.cone, cx, apex_y, 0, radius * 1.15, (reach + radius) * flick)

    -- Bright pool ahead of the vehicle.
    self:_stamp(cx, cy - reach, radius, h.color[1], h.color[2], h.color[3],
                h.intensity * flick)
end

-- Pass A: build and composite the multiplicative night light map. Call only on
-- night stages, after the world/entities/effects have been drawn.
function LightFX:draw_night(camera)
    if not (self.enabled and self.night and Config.night_lighting) then return end
    local g    = love.graphics
    local w, h = g.getDimensions()
    if not self.canvas or self.cw ~= w or self.ch ~= h then
        self.canvas = g.newCanvas(w, h)
        self.cw, self.ch = w, h
    end

    local prev = g.getCanvas()
    g.setCanvas(self.canvas)
    local a  = self.night.ambient
    local br = Config.night_brightness   -- lifts the floor toward daylight
    g.clear(math.min(1, a[1] * br), math.min(1, a[2] * br), math.min(1, a[3] * br), 1)
    g.setBlendMode("add")
    if self.headlight_on then self:_headlight(camera) end
    local z = camera:zoom()
    for _, l in ipairs(self.lights) do
        local sx, sy = camera:project(l.x, l.y)
        local fade   = 1 - l.t / l.ttl
        self:_stamp(sx, sy, l.radius * z, l.r, l.g, l.b, l.intensity * fade)
    end
    g.setCanvas(prev)

    g.setBlendMode("multiply", "premultiplied")
    g.setColor(1, 1, 1, 1)
    g.draw(self.canvas)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
end

-- Pass B: additive oversaturation over the composited scene (any stage). Bursts
-- are world-anchored; flashes wash the whole screen.
function LightFX:draw_additive(camera)
    if not (self.enabled and Config.effects_flashes) then return end
    local g = love.graphics
    if #self.bursts == 0 and #self.flashes == 0 then return end
    local fi = Config.flash_intensity   -- master brightness of the flash layer
    local z  = camera:zoom()
    g.setBlendMode("add")
    for _, b in ipairs(self.bursts) do
        local sx, sy = camera:project(b.x, b.y)
        local k      = 1 - b.t / b.dur
        self:_stamp(sx, sy, b.radius * z, b.r, b.g, b.b, k * k * fi)
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
