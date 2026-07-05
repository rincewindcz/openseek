local Class = require "engine.core.class"

-- Weather overlay: a fixed-density field of pixel particles (snow on the winter
-- world, rain on the jungle world) that reacts to the vehicle. The player is
-- locked upright at screen centre and the whole world pans and rotates around it,
-- so the precipitation is a world-space field: each particle has a world position
-- and is drawn through the camera, so flying past streams it (parallax) and
-- turning rotates the whole field.
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
local Weather = Class()

local DESIGN_H = 240
local COVER    = 1.2   -- tile size vs screen diagonal (>1 keeps the wrap off-screen)

-- Presets. wind is the falling drift in WORLD px/sec (fixed in the world; the
-- camera's rotation makes it lean on screen), scaled per particle by spd_var.
-- sway is a screen-space horizontal wobble in art pixels (snow only). size is the
-- block side in art pixels. alpha is a per-particle range.
local PRESETS = {
    snow = {
        density = 1 / 380,
        wind    = { 4, 20 }, spd_var = { 0.7, 1.3 },
        sway    = 7, sway_hz = 0.5,
        size    = 1,
        color   = { 1, 1, 1 }, alpha = { 0.55, 0.95 },
    },
    rain = {
        density = 1 / 210,
        wind    = { 24, 220 }, spd_var = { 0.85, 1.15 },
        sway    = 0, sway_hz = 0,
        size    = 1,
        color   = { 0.72, 0.8, 1.0 }, alpha = { 0.4, 0.7 },
    },
}

local function rand_range(r) return r[1] + math.random() * (r[2] - r[1]) end

function Weather:init()
    self.kind      = nil
    self.preset    = nil
    self.particles = {}
    self.t         = 0
    self.cell      = 0
    self.sw        = 0
    self.sh        = 0
    self.view      = nil     -- cached transform for draw(): { cx, cy, z, ang, wx, wy, T }
    self.dirty     = false
end

-- Select the active preset by name ("snow" / "rain"), or nil for clear skies.
function Weather:set(kind)
    if kind == self.kind then return end
    self.kind      = kind
    self.preset    = kind and PRESETS[kind] or nil
    self.particles = {}
    self.view      = nil
    self.dirty     = self.preset ~= nil
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
    local on_screen = (sw / cell) * (sh / cell) * self.preset.density
    local fraction  = (sw * sh) / (COVER * COVER * (sw * sw + sh * sh))
    local count     = math.floor(on_screen / fraction + 0.5)
    local ps = {}
    for i = 1, count do
        ps[i] = {
            x   = math.random(),
            y   = math.random(),
            spd = rand_range(self.preset.spd_var),
            ph  = math.random() * math.pi * 2,
            a   = rand_range(self.preset.alpha),
        }
    end
    self.particles = ps
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

    -- Project with the live (possibly mid-intro) zoom, but size the tile from the
    -- discrete target zoom so the world lattice does not reflow while the level's
    -- zoom-in tween animates. Reflowing it would slide the whole field across the
    -- screen (cxT = wx / T shifts when T changes), which reads as the flakes
    -- briefly racing off in the wrong direction. min() keeps full screen coverage
    -- if an intro ever zooms in from below the target instead of out toward it.
    local z = camera:zoom()
    local T = self:_tile(math.min(z, camera:base_zoom()))

    -- Fall: advance each particle by the wind in normalized tile units, wrapped.
    local dnx = preset.wind[1] * dt / T
    local dny = preset.wind[2] * dt / T
    for _, p in ipairs(self.particles) do
        p.x = (p.x + dnx * p.spd) % 1
        p.y = (p.y + dny * p.spd) % 1
    end

    local cx, cy = camera:screen_center()
    self.view = { cx = cx, cy = cy, z = z, ang = camera.angle or 0,
                  wx = camera.x, wy = camera.y, T = T }
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

    local s   = preset.size * cell
    local swA = preset.sway * cell
    local swW = self.t * preset.sway_hz * math.pi * 2

    for _, p in ipairs(self.particles) do
        -- Nearest tile image of the particle to the camera, in world tile units.
        local fx = p.x - cxT; fx = fx - math.floor(fx + 0.5)
        local fy = p.y - cyT; fy = fy - math.floor(fy + 0.5)
        local dwx, dwy = fx * T, fy * T
        -- Project to screen (rotate by camera angle, scale by zoom).
        local sx = v.cx + v.z * (dwx * cosa - dwy * sina)
        local sy = v.cy + v.z * (dwx * sina + dwy * cosa)
        if sx > -m and sx < self.sw + m and sy > -m and sy < self.sh + m then
            local rx = sx + (swA > 0 and swA * math.sin(swW + p.ph) or 0)
            g.setColor(c[1], c[2], c[3], p.a)
            g.rectangle("fill", math.floor(rx / cell) * cell, math.floor(sy / cell) * cell, s, s)
        end
    end
    g.setColor(1, 1, 1, 1)
end

return Weather
