-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local json  = require "lib.json"

-- Weather overlay: a fixed-density field of pixel particles (snow on the winter
-- world, rain on the jungle world, and for maps a blizzard, a thunderstorm or a
-- sandstorm) that reacts to the vehicle. The player is locked upright at screen
-- centre and the whole world pans and rotates around it, so the precipitation is
-- a world-space field: each particle has a world position and is drawn through
-- the camera, so flying past streams it (parallax) and turning rotates the whole
-- field.
--
-- The field is a single T x T world tile tiled infinitely: for each particle only
-- the lattice image nearest the camera is drawn (T is sized larger than the screen
-- diagonal, so the image that "wraps" is always off-screen). That keeps on-screen
-- density perfectly uniform and constant under any pan / turn, with no recycling
-- and no density bursts. Particles fall by a world-space wind and wrap in the tile.
--
-- Flakes are drawn as nearest-neighbour blocks (like the original), sized in "art
-- pixels" (window height / DESIGN_H), so they stay crisp and the field looks the
-- same at any resolution.
--
-- A preset may also carry a gusting wind, a haze over the world view (a flat
-- tint plus drifting banks of a tileable noise, laid in world space and fitted
-- to the stage's wrap period so the seam never shows) and lightning (flashes
-- handed to LightFX, which also lifts a night stage's light map, and thunder
-- after them). Presets are data/weather.json.
local Weather = Class()

local DATA_PATH  = "data/weather.json"
local DESIGN_H   = 240
local COVER      = 1.2   -- tile size vs screen diagonal (>1 keeps the wrap off-screen)
local BANK_SIZE  = 128   -- noise texels per side
local BANK_SHIFT = 41    -- texel offset between bank layers, so they never line up

-- Missing preset fields. wind is the falling drift in WORLD px/sec (fixed in the
-- world; the camera's rotation makes it lean on screen), scaled per particle by
-- speed. area is art pixels per particle. sway is a screen-space horizontal
-- wobble in art pixels. size is the block side in art pixels, large the share of
-- particles one art pixel bigger, streak the trail length in art pixels along
-- the wind.
local DEFAULTS = {
    area    = 300,
    wind    = { 0, 60 },
    speed   = { 1, 1 },
    sway    = 0,
    sway_hz = 0,
    size    = 1,
    large   = 0,
    streak  = 1,
    color   = { 1, 1, 1 },
    alpha   = { 0.5, 0.9 },
}

local presets

local function load_presets()
    if presets then return presets end
    local raw = love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    presets = (ok and type(decoded) == "table") and decoded or {}
    for _, preset in pairs(presets) do
        for key, value in pairs(DEFAULTS) do
            if preset[key] == nil then preset[key] = value end
        end
    end
    return presets
end

local function rand_range(r) return r[1] + math.random() * (r[2] - r[1]) end

local function smoothstep(lo, hi, x)
    local t = math.max(0, math.min(1, (x - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)
end

-- Tileable value noise, a few octaves on lattices that divide the image, shaped
-- into patches: white, the noise in alpha.
local function make_banks()
    local octaves = { { cells = 4, weight = 0.5 }, { cells = 8, weight = 0.3 }, { cells = 16, weight = 0.2 } }
    for _, octave in ipairs(octaves) do
        octave.lattice = {}
        for i = 0, octave.cells * octave.cells - 1 do octave.lattice[i] = math.random() end
    end
    local function sample(octave, x, y)
        local n    = octave.cells
        local fx   = x / BANK_SIZE * n
        local fy   = y / BANK_SIZE * n
        local ix   = math.floor(fx)
        local iy   = math.floor(fy)
        local tx   = smoothstep(0, 1, fx - ix)
        local ty   = smoothstep(0, 1, fy - iy)
        local x0   = ix % n
        local x1   = (ix + 1) % n
        local y0   = (iy % n) * n
        local y1   = ((iy + 1) % n) * n
        local l    = octave.lattice
        local top  = l[y0 + x0] + (l[y0 + x1] - l[y0 + x0]) * tx
        local base = l[y1 + x0] + (l[y1 + x1] - l[y1 + x0]) * tx
        return top + (base - top) * ty
    end
    local image = love.image.newImageData(BANK_SIZE, BANK_SIZE)
    image:mapPixel(function(x, y)
        local n = 0
        for _, octave in ipairs(octaves) do n = n + octave.weight * sample(octave, x, y) end
        return 1, 1, 1, smoothstep(0.35, 0.75, n)
    end)
    local banks = love.graphics.newImage(image)
    banks:setWrap("repeat", "repeat")
    return banks
end

function Weather:init(lightfx, sound)
    self.lightfx   = lightfx
    self.sound     = sound
    self.kind      = nil
    self.night     = false
    self.preset    = nil
    self.particles = {}
    self.t         = 0
    self.cell      = 0
    self.sw        = 0
    self.sh        = 0
    self.view      = nil     -- cached transform for draw(): { cx, cy, z, ang, wx, wy, T }
    self.dirty     = false
    self.gust      = 0       -- -1..1, the wind's swing this frame
    self.drifts    = {}      -- per bank layer: { x, y } world offset the wind has carried it
    self.banks     = nil
    self.bank_quad = nil
    self.strike_in = 0
    self.pulses    = {}      -- lightning: { at, dur, level }
    self.thunders  = {}      -- { at, strength }
end

-- Select the active preset by name, or nil (or an unknown name) for clear skies.
-- night thins the haze by the preset's haze.night: the night light map
-- multiplies it like the ground, and a pale haze under the headlights burns out.
function Weather:set(kind, night)
    night = night == true
    if kind == self.kind and night == self.night then return end
    self.kind      = kind
    self.night     = night
    self.preset    = kind and load_presets()[kind] or nil
    self.particles = {}
    self.view      = nil
    self.dirty     = self.preset ~= nil
    self.t         = 0
    self.gust      = 0
    self.drifts    = {}
    self.pulses    = {}
    self.thunders  = {}
    local lightning = self.preset and self.preset.lightning
    self.strike_in = lightning and rand_range(lightning.interval) * 0.5 or 0
    if self.lightfx then self.lightfx:sky_flash(nil) end
end

-- Tile size (world px) covering the screen diagonal at zoom z.
function Weather:_tile(z)
    return COVER * math.sqrt(self.sw * self.sw + self.sh * self.sh) / z
end

-- (Re)seed the pool. Positions are normalized tile coordinates [0,1); the count is
-- chosen so the on-screen fraction of the tile holds the preset's target density,
-- and it is independent of zoom (both tile area and screen world-area scale as
-- 1/z^2), so zooming never reseeds.
function Weather:_reseed()
    local sw, sh, cell = self.sw, self.sh, self.cell
    local preset    = self.preset
    local on_screen = (sw / cell) * (sh / cell) / preset.area
    local fraction  = (sw * sh) / (COVER * COVER * (sw * sw + sh * sh))
    local count     = math.floor(on_screen / fraction + 0.5)
    local ps = {}
    for i = 1, count do
        ps[i] = {
            x     = math.random(),
            y     = math.random(),
            speed = rand_range(preset.speed),
            phase = math.random() * math.pi * 2,
            alpha = rand_range(preset.alpha),
            large = math.random() < preset.large,
        }
    end
    self.particles = ps
end

-- Two sines out of step, so the wind swells and drops without settling into a beat.
function Weather:_update_gust()
    local gust = self.preset.gust
    if not gust then return 1 end
    local w = self.t * math.pi * 2 / gust.period
    self.gust = 0.5 * (math.sin(w) + math.sin(w * 1.618 + 1.3))
    return 1 + gust.strength * self.gust
end

-- Each strike is a burst of one or more flickers, the first the brightest; its
-- thunder follows, sooner and louder the brighter (the nearer) the strike.
function Weather:_strike(lightning)
    local strength = rand_range(lightning.strength)
    local flickers = math.random(lightning.flickers[1], lightning.flickers[2])
    local at       = self.t
    for i = 1, flickers do
        local dur = rand_range(lightning.duration)
        local level = strength * (i == 1 and 1 or 0.5 + 0.5 * math.random())
        self.pulses[#self.pulses + 1] = { at = at, dur = dur, level = level }
        at = at + dur * 0.5 + rand_range(lightning.gap)
    end
    local lo, hi = lightning.strength[1], lightning.strength[2]
    local near   = hi > lo and (strength - lo) / (hi - lo) or 1
    local delay  = lightning.delay[2] - (lightning.delay[2] - lightning.delay[1]) * near
    self.thunders[#self.thunders + 1] = { at = self.t + delay, strength = near }
end

function Weather:_update_lightning(dt)
    local lightning = self.preset.lightning
    if not lightning then return end
    self.strike_in = self.strike_in - dt
    if self.strike_in <= 0 then
        self:_strike(lightning)
        self.strike_in = rand_range(lightning.interval)
    end

    local level, live = 0, {}
    for _, pulse in ipairs(self.pulses) do
        local k = (self.t - pulse.at) / pulse.dur
        if k < 1 then
            live[#live + 1] = pulse
            if k >= 0 then level = math.max(level, pulse.level * (1 - k) * (1 - k)) end
        end
    end
    self.pulses = live
    if self.lightfx then
        self.lightfx:sky_flash(lightning.color, level * lightning.wash, level * lightning.night)
    end

    local waiting = {}
    for _, thunder in ipairs(self.thunders) do
        if self.t >= thunder.at then
            if self.sound and lightning.thunder then
                local s = thunder.strength
                self.sound:emit_flat(lightning.thunder, {
                    gain = 0.45 + 0.55 * s, lowpass = 0.25 + 0.6 * s, pan = (math.random() * 2 - 1) * 0.6,
                })
            end
        else
            waiting[#waiting + 1] = thunder
        end
    end
    self.thunders = waiting
end

function Weather:update(dt, camera)
    local preset = self.preset
    if not preset then return end

    local sw, sh = love.graphics.getDimensions()
    local cell   = math.max(1, math.floor(sh / DESIGN_H))
    if self.dirty or cell ~= self.cell or sw ~= self.sw or sh ~= self.sh then
        self.cell, self.sw, self.sh = cell, sw, sh
        self:_reseed()
        self.dirty = false
    end
    self.t = self.t + dt
    local blow = self:_update_gust()
    self:_update_lightning(dt)

    -- Drive the field from the discrete target zoom, ignoring the level-start zoom
    -- tween. The world lattice is sized to the zoom (tile ~ 1/z), so following the
    -- smooth intro would resize and reflow it every frame: the camera-in-tile phase
    -- (wx / T) shifts as T changes, sliding the whole field across the screen, which
    -- reads as the flakes briefly racing off in the wrong direction. The player is
    -- stationary during the intro anyway, so there is nothing for the weather to
    -- react to; once the tween ends base_zoom() == zoom() and parallax resumes.
    local z = camera:base_zoom()
    local T = self:_tile(z)

    -- Fall: advance each particle by the wind in normalized tile units, wrapped.
    local wind_x, wind_y = preset.wind[1] * blow, preset.wind[2] * blow
    local dnx = wind_x * dt / T
    local dny = wind_y * dt / T
    for _, p in ipairs(self.particles) do
        p.x = (p.x + dnx * p.speed) % 1
        p.y = (p.y + dny * p.speed) % 1
    end

    local haze = preset.haze
    if haze and haze.banks then
        local period = camera.world_size or 4096
        for i, layer in ipairs(haze.banks) do
            local drift = self.drifts[i] or { x = 0, y = 0 }
            drift.x = (drift.x + wind_x * layer.drift * dt) % period
            drift.y = (drift.y + wind_y * layer.drift * dt) % period
            self.drifts[i] = drift
        end
    end

    local cx, cy = camera:screen_center()
    self.view = { cx = cx, cy = cy, z = z, ang = camera.angle or 0,
                  wx = camera.x, wy = camera.y, T = T }
end

-- World px per bank texel: near the layer's scale, fitted so a whole number of
-- noise images spans the stage's wrap period.
local function bank_scale(layer, period)
    local images = math.max(1, math.floor(period / (BANK_SIZE * layer.scale) + 0.5))
    return period / (images * BANK_SIZE)
end

-- The haze over one world view (w x h at the current origin), seen through
-- camera. Drawn inside the world pass, under the night lighting, so the dark
-- covers it like the ground.
function Weather:draw_haze(camera, w, h)
    local haze = self.preset and self.preset.haze
    if not haze then return end
    local g     = love.graphics
    local c     = haze.color
    local thin  = self.night and (haze.night or 1) or 1
    local alpha = (haze.alpha + (haze.gust or 0) * self.gust) * thin
    if alpha > 0 then
        g.setColor(c[1], c[2], c[3], alpha)
        g.rectangle("fill", 0, 0, w, h)
    end
    if haze.banks then
        if not self.banks then
            self.banks     = make_banks()
            self.bank_quad = g.newQuad(0, 0, 1, 1, BANK_SIZE, BANK_SIZE)
        end
        local period = camera.world_size or 4096
        local z      = camera:zoom()
        local cx, cy = camera:screen_center()
        local diag   = math.sqrt(w * w + h * h)
        for i, layer in ipairs(haze.banks) do
            local drift = self.drifts[i] or { x = 0, y = 0 }
            local scale = bank_scale(layer, period)
            local span  = diag / (scale * z) + 2
            local u     = (camera.x - drift.x) / scale - span / 2 + (i - 1) * BANK_SHIFT
            local v     = (camera.y - drift.y) / scale - span / 2 + (i - 1) * BANK_SHIFT
            self.bank_quad:setViewport(u, v, span, span, BANK_SIZE, BANK_SIZE)
            g.setColor(c[1], c[2], c[3], layer.alpha * thin)
            g.draw(self.banks, self.bank_quad, cx, cy, camera.angle or 0, scale * z, scale * z, span / 2, span / 2)
        end
    end
    g.setColor(1, 1, 1, 1)
end

function Weather:draw()
    local preset = self.preset
    local v      = self.view
    if not (preset and v) then return end
    local g    = love.graphics
    local cell = self.cell
    local c    = preset.color
    local T    = v.T
    local cosa, sina = math.cos(v.ang), math.sin(v.ang)
    local cxT, cyT = v.wx / T, v.wy / T   -- camera in tile units
    local m = cell * 8                    -- off-screen cull margin

    local s     = preset.size * cell
    local sway  = preset.sway * cell
    local swing = self.t * preset.sway_hz * math.pi * 2

    -- A streak trails back along the wind as the screen shows it.
    local streak = preset.streak
    local tx, ty = 0, 0
    if streak > 1 then
        local wx, wy = preset.wind[1], preset.wind[2]
        local sx, sy = wx * cosa - wy * sina, wx * sina + wy * cosa
        local len    = math.sqrt(sx * sx + sy * sy)
        if len > 0 then tx, ty = -sx / len * cell, -sy / len * cell end
    end

    for _, p in ipairs(self.particles) do
        -- Nearest tile image of the particle to the camera, in world tile units.
        local fx = p.x - cxT; fx = fx - math.floor(fx + 0.5)
        local fy = p.y - cyT; fy = fy - math.floor(fy + 0.5)
        local dwx, dwy = fx * T, fy * T
        -- Project to screen (rotate by camera angle, scale by zoom).
        local sx = v.cx + v.z * (dwx * cosa - dwy * sina)
        local sy = v.cy + v.z * (dwx * sina + dwy * cosa)
        if sx > -m and sx < self.sw + m and sy > -m and sy < self.sh + m then
            local rx   = sx + (sway > 0 and sway * math.sin(swing + p.phase) or 0)
            local side = p.large and s + cell or s
            g.setColor(c[1], c[2], c[3], p.alpha)
            for k = 0, streak - 1 do
                g.rectangle("fill", math.floor((rx + tx * k) / cell) * cell,
                    math.floor((sy + ty * k) / cell) * cell, side, side)
            end
        end
    end
    g.setColor(1, 1, 1, 1)
end

return Weather
