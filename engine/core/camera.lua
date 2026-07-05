local Class = require "engine.core.class"

local ZOOMS = { 0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8 }

local Camera = Class()

function Camera:init(world_size)
    self.world_size = world_size or 4096
    self.x          = self.world_size / 2
    self.y          = self.world_size / 2
    self.zoom_index = 4     -- index into ZOOMS; default 1x
    self.angle      = nil   -- radians; nil = no rotation (viewer mode)
    self.view_oy    = 0     -- screen-space vertical offset of the focus point (px)
    self.vw         = nil   -- viewport size; nil = full window (split screen sets these)
    self.vh         = nil
    self.zoom_anim  = nil   -- continuous-scale tween for the level-start zoom-in
end

-- Viewport size this camera renders into: the full window, unless a split-screen
-- half has been assigned (vw/vh). The caller translates to the viewport origin.
function Camera:dims()
    if self.vw then return self.vw, self.vh end
    return love.graphics.getDimensions()
end

-- Screen pixel the focus point (camera x,y) maps to. In game mode the vehicle
-- sits below center so more of the world ahead is visible.
function Camera:screen_center()
    local w, h = self:dims()
    return w / 2, h / 2 + self.view_oy
end

function Camera:zoom()
    local za = self.zoom_anim
    if za then
        local k = math.min(1, za.t / za.dur)
        k = 1 - (1 - k) * (1 - k) * (1 - k)   -- ease-out cubic
        return za.from + (za.to - za.from) * k
    end
    return ZOOMS[self.zoom_index]
end

-- The discrete target zoom, ignoring any in-progress intro tween. Used where a
-- value must stay fixed across the smooth zoom (e.g. the weather field's tile
-- size, so the lattice does not reflow while the intro animates).
function Camera:base_zoom()
    return ZOOMS[self.zoom_index]
end

-- Ratio of the (possibly mid-intro) zoom to the discrete target zoom: 1.0 in
-- normal play, <1 during the level-start zoom-in. Screen-space sprites such as
-- the player scale by this so they grow with the animated world.
function Camera:zoom_ratio()
    return self:zoom() / ZOOMS[self.zoom_index]
end

-- Smoothly zoom from `from_scale` to the current discrete zoom over `dur`
-- seconds (the level-start intro). Cleared automatically when it completes.
function Camera:start_zoom_intro(from_scale, dur)
    self.zoom_anim = { from = from_scale, to = ZOOMS[self.zoom_index], t = 0, dur = dur or 1.0 }
end

function Camera:tick_zoom(dt)
    local za = self.zoom_anim
    if not za then return end
    za.t = za.t + dt
    if za.t >= za.dur then self.zoom_anim = nil end
end

function Camera:set_zoom(zoom_index, mx, my)
    self.zoom_anim = nil
    zoom_index = math.max(1, math.min(#ZOOMS, zoom_index))
    if zoom_index == self.zoom_index then return end
    local w, h = self:dims()
    mx = mx or w / 2
    my = my or h / 2
    local old_z = self:zoom()
    local wx = self.x + (mx - w / 2) / old_z
    local wy = self.y + (my - h / 2) / old_z
    self.zoom_index = zoom_index
    local new_z = self:zoom()
    self.x = wx - (mx - w / 2) / new_z
    self.y = wy - (my - h / 2) / new_z
    self:clamp()
end

function Camera:clamp()
    self.x = math.max(0, math.min(self.world_size, self.x))
    self.y = math.max(0, math.min(self.world_size, self.y))
end

-- Free-roam pan (viewer mode only; not called in game mode).
function Camera:update(dt)
    local speed = 600 / self:zoom() * dt
    local kb = love.keyboard.isDown
    if kb("a") or kb("left")  then self.x = self.x - speed end
    if kb("d") or kb("right") then self.x = self.x + speed end
    if kb("w") or kb("up")    then self.y = self.y - speed end
    if kb("s") or kb("down")  then self.y = self.y + speed end
    self:clamp()
end

function Camera:on_wheel(dy)
    local mx, my = love.mouse.getPosition()
    self:set_zoom(self.zoom_index + (dy > 0 and 1 or -1), mx, my)
end

-- Apply the camera transform.  When self.angle is set, the world is rotated
-- around screen center so the player always faces up.
function Camera:apply()
    local cx, cy = self:screen_center()
    love.graphics.translate(cx, cy)
    love.graphics.scale(self:zoom())
    if self.angle then
        love.graphics.rotate(self.angle)
    end
    love.graphics.translate(-self.x, -self.y)
end

-- World point -> screen pixel under this camera (inverse of the math baked into
-- apply()). Used to place an off-center sprite, e.g. the co-op teammate.
function Camera:project(wx, wy)
    local cx, cy = self:screen_center()
    local z = self:zoom()
    local dx, dy = wx - self.x, wy - self.y
    -- Pick the nearest wrapped copy so an off-center sprite across the seam still
    -- projects next to the focus point (e.g. the co-op teammate at the map edge).
    local s = self.world_size
    if s then
        dx = dx % s; if dx > s * 0.5 then dx = dx - s end
        dy = dy % s; if dy > s * 0.5 then dy = dy - s end
    end
    local a = self.angle or 0
    local rx = dx * math.cos(a) - dy * math.sin(a)
    local ry = dx * math.sin(a) + dy * math.cos(a)
    return cx + rx * z, cy + ry * z
end

-- Viewport in world coordinates (expanded for rotation so culling stays correct).
function Camera:viewport(margin)
    margin = margin or 64
    local w, h = self:dims()
    local z = self:zoom()
    if self.angle then
        -- Rotated viewport: expand margin to cover the full screen diagonal.
        local diag = math.sqrt(w * w + h * h) / 2 / z
        margin = math.max(margin, diag)
    end
    return {
        x0 = self.x - w / 2 / z - margin,
        x1 = self.x + w / 2 / z + margin,
        y0 = self.y - h / 2 / z - margin,
        y1 = self.y + h / 2 / z + margin,
    }
end

-- World-copy offsets {ox, oy} that overlap the current viewport, so the seamless
-- (toroidal) map can be drawn by translating world-space passes once per copy.
-- One tile inland, two across a seam, four at a corner; more only when zoomed far
-- enough out that several map copies fit on screen.
function Camera:tiles()
    local s  = self.world_size
    local vp = self:viewport()
    local tiles = {}
    for kx = math.floor(vp.x0 / s), math.floor(vp.x1 / s) do
        for ky = math.floor(vp.y0 / s), math.floor(vp.y1 / s) do
            tiles[#tiles + 1] = { ox = kx * s, oy = ky * s }
        end
    end
    return tiles
end

return Camera
