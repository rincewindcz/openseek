-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local Animation = require "engine.core.animation"
local World     = require "engine.game.world"

local Renderer = Class()

function Renderer:init(world, camera)
    self.world         = world
    self.camera        = camera
    self.highlight     = nil        -- Entity to tint (debug selection / hover)
end

-- Pulsing additive pass over a just-drawn sprite to mark the debug selection.
function Renderer:_glow(img, x, y, rot, sx, sy, ox, oy)
    local g = love.graphics
    local p = 0.30 + 0.18 * math.sin(love.timer.getTime() * 6)
    g.setBlendMode("add")
    g.setColor(p * 0.5, p * 0.8, p, 1)
    g.draw(img, x, y, rot, sx, sy, ox, oy)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1)
end

-- EXTRA (target_glint): the light sweep across a mission objective's sprite,
-- just drawn at (x, y) with rotation rot and origin (ox, oy).
function Renderer:_glint(img, x, y, rot, ox, oy)
    if not self.detailfx then return end
    self.detailfx:draw_glint("target_glint", img, x, y, rot, ox, oy,
        rot + (self.camera.angle or 0), self.world.time)
end

-- draw

function Renderer:draw()
    self:_draw_world()
end

function Renderer:_draw_world()
    self:draw_ground()
    self:draw_objects()
    self:draw_explosions()
end

-- Run a layer function once per overlapping map copy so the world reads as
-- seamless across the wrapped (toroidal) edges; culling uses the copy-local
-- viewport. Shared by the ground and object passes.
function Renderer:_world_pass(fn)
    local g  = love.graphics
    local vp = self.camera:viewport()
    g.push()
    self.camera:apply()
    for _, t in ipairs(self.camera:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        fn(self, {
            x0 = vp.x0 - t.ox, x1 = vp.x1 - t.ox,
            y0 = vp.y0 - t.oy, y1 = vp.y1 - t.oy,
        })
        g.pop()
    end
    g.pop()
end

-- Ground pass: terrain fill, decals, and craters. Everything a vehicle on the
-- ground (a tank, or a chopper on its skids) sits on top of; drawn before the
-- object layer so trees/buildings can occlude it. Grounded players are drawn
-- between this and draw_objects.
function Renderer:draw_ground()
    love.graphics.clear(self.world:ground_color())
    self:_world_pass(self._draw_ground_layers)
end

-- Object pass. mode selects which objects to draw relative to a vehicle on the
-- ground: "under" draws only flat ground clutter (non-solid scenery, decals, foot
-- units) that a tank drives over; "over" draws the solid props (trees, buildings,
-- turrets) that stand above it; nil draws everything
-- (the normal path when no vehicle is on the ground to split around).
function Renderer:draw_objects(mode)
    self:_world_pass(function(_, vp) self:_draw_object_layers(vp, mode) end)
end

-- Smoke over the objects: muzzle smoke and smoking wrecks (EXTRA tank_recoil,
-- wreck_smoke).
function Renderer:draw_detail_air()
    if not self.detailfx then return end
    self:_world_pass(function() self.detailfx:draw_air() end)
end

function Renderer:_draw_ground_layers(vp)
    local g = love.graphics
    local w = self.world

    -- Lowest layer: dust kicked up where shrapnel landed, under decals and trees.
    self:_draw_ground_fx(vp)

    self:_draw_entities(w.decals, w.decal_index, vp)
    if self.tracks then self.tracks:draw() end   -- EXTRA (tank_tracks)
    if self.detailfx then self.detailfx:draw_ground() end   -- EXTRA (shell_casings, tread_dust)
    self:_draw_lying_debris(vp)

    g.setLineStyle("rough")
    g.setLineWidth(1)
    for _, s in ipairs(w.stage.segments) do
        g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255)
        g.line(s.x1, s.y1, s.x2, s.y2)
    end
    g.setColor(1, 1, 1)

    self:_draw_craters(vp)
end

function Renderer:_draw_object_layers(vp, mode)
    self:_draw_entities(self.world.objects, self.world.object_index, vp, mode)
end

-- Objects tall enough to stand over a ground vehicle: solid props (trees,
-- buildings, turrets, enemy vehicles). Flat clutter the tank drives over (scenery
-- stones/dunes, decals, foot soldiers) is non-solid and stays under it. A
-- POWHERE flag rides with the solid pass so its building never covers it.
local function is_occluder(e)
    return e.rescue_zone or (e.type_data and e.type_data.solid) or false
end

-- mode (optional) filters against the ground-vehicle split: "under" draws only
-- non-occluders, "over" only occluders, nil draws all. index is the list's
-- World y lookup; only entries near the viewport band are visited.
function Renderer:_draw_entities(list, index, vp, mode)
    love.graphics.setColor(1, 1, 1)
    World.each_in_y(list, index, vp.y0, vp.y1, self._draw_entity, self, vp, mode)
end

function Renderer:_draw_entity(e, vp, mode)
    if e.x < vp.x0 or e.x > vp.x1 or e.y < vp.y0 or e.y > vp.y1 then return end
    if mode == "under" and is_occluder(e) then return end
    if mode == "over" and not is_occluder(e) then return end
    local cls = self.world.stage.classes[e.class_idx + 1]
    -- Skip emptied POW building markers (rescue_hidden) and a building the
    -- mission holds back (dormant).
    if e.rescue_hidden or e.sabotage_hidden or e.dormant then return end
    local g      = love.graphics
    local images = self.world.images
    if e.type_data and e.type_data.sprite then
        -- Units with explicit alive/dead sprites (soldiers) draw
        -- axis-aligned and persist as a corpse once dead.
        self:_draw_unit(e)
    elseif e:is_alive() then
        local r = images[e.class_idx + 1]
        if r then
            -- Two-part tanks keep a fixed hull (turret does the aiming) unless they
            -- patrol, in which case the hull faces its travel heading; a hangar tank
            -- keeps its fixed facing; everything else rotates its sprite to face.
            local rot
            if e.hide_angle then
                rot = e.hide_angle * math.pi / 180
            elseif e.turret_render and not e.route_points then
                rot = 0
            else
                rot = e:draw_angle_rad(cls.angle_steps)
            end
            g.draw(r.img, e.x, e.y, rot, 1, 1, -r.ox, -r.oy)
            -- EXTRA (hit_flash)
            local impactfx = self.world.impactfx
            if impactfx then impactfx:draw_flash(e, r.img, e.x, e.y, rot, 1, 1, -r.ox, -r.oy) end
            if e.objective then self:_glint(r.img, e.x, e.y, rot, -r.ox, -r.oy) end
            if e == self.highlight then
                self:_glow(r.img, e.x, e.y, rot, 1, 1, -r.ox, -r.oy)
            end
        else
            g.setColor(1, 0, 1)
            g.circle("fill", e.x, e.y, 3)
            g.setColor(1, 1, 1)
        end

        -- Two-part enemy tank: the turret spins on the fixed hull from aim_angle;
        -- its destruction explosion plays over the hull until the hull itself dies.
        if e.turret_render then
            if e.turret_alive then
                local tr  = e.turret_render
                local rot = e.aim_angle * math.pi / 180
                g.draw(tr.img, e.x, e.y, rot, 1, 1, tr.ax, tr.ay)
                local impactfx = self.world.impactfx
                if impactfx then impactfx:draw_flash(e, tr.img, e.x, e.y, rot, 1, 1, tr.ax, tr.ay) end
            end
            if e.turret_fx then
                local img = e.turret_fx:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
                end
            end
        end
        -- overlay animation (non-destructive: hit flash, etc.)
        if e.state == "animating" and e.anim then
            local img = e.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
            end
        end

        -- Damage smoke emitters (persistent, threshold-based)
        for _, se in ipairs(e._damage_smokes) do
            local img = se.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1, 0.85)
                g.draw(img, e.x + se.ox, e.y + se.oy, 0, 1, 1, iw / 2, ih / 2)
                g.setColor(1, 1, 1)
            end
        end

        -- One-shot hit smokes (SMOKE2)
        for _, hs in ipairs(e._hit_smokes) do
            local img = hs.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.draw(img, e.x + hs.ox, e.y + hs.oy, 0, 1, 1, iw / 2, ih / 2)
            end
        end
    end
    -- Not alive: the persistent crater is drawn earlier (see _draw_craters) and
    -- the death explosion later (draw_explosions), over the pickups it drops.
end

-- Death explosions of the objects, drawn after the pickups so a building's
-- blast is not hidden by the powerup it leaves behind.
function Renderer:draw_explosions()
    local w = self.world
    self:_world_pass(function(_, vp)
        love.graphics.setColor(1, 1, 1)
        World.each_in_y(w.objects, w.object_index, vp.y0, vp.y1, self._draw_explosion, self, vp)
    end)
end

function Renderer:_draw_explosion(e, vp)
    if e.state ~= "exploding" or not e.anim or (e.type_data and e.type_data.sprite)
    or e.x < vp.x0 or e.x > vp.x1 or e.y < vp.y0 or e.y > vp.y1 then return end
    local img = e.anim:current_image()
    if img then
        local iw, ih = img:getDimensions()
        love.graphics.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
    end
end

-- Destruction craters: a dead building's hole is a ground feature, so it is drawn
-- under every object (before the object pass) instead of at the building's own
-- y-position, keeping tanks and other entities on top of it.
function Renderer:_draw_craters(vp)
    local w = self.world
    love.graphics.setColor(1, 1, 1)
    World.each_in_y(w.objects, w.object_index, vp.y0, vp.y1, self._draw_crater, self, vp)
end

function Renderer:_draw_crater(e, vp)
    if e.crater_img and not e:is_alive()
    and e.x >= vp.x0 and e.x <= vp.x1 and e.y >= vp.y0 and e.y <= vp.y1 then
        local iw, ih = e.crater_img:getDimensions()
        love.graphics.draw(e.crater_img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
    end
end

-- Ground dust (lowest layer): drawn before decals so even trees sit above it.
function Renderer:_draw_ground_fx(vp)
    local g = love.graphics
    for _, fx in ipairs(self.world.ground_fx) do
        if fx.x >= vp.x0 and fx.x <= vp.x1 and fx.y >= vp.y0 and fx.y <= vp.y1 then
            local img = fx.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1)
                g.draw(img, fx.x, fx.y, 0, 1, 1, iw / 2, ih / 2)
            end
        end
    end
end

-- Shards that came to lie on the ground, fading out at the end of their stay.
function Renderer:_draw_lying_debris(vp)
    local g      = love.graphics
    local debris = self.world.debris
    local tint   = debris.data.lie_tint or 1
    for _, d in ipairs(debris.lying) do
        if d.image and d.x >= vp.x0 and d.x <= vp.x1 and d.y >= vp.y0 and d.y <= vp.y1 then
            local iw, ih = d.image:getDimensions()
            g.setColor(tint, tint, tint, d.alpha)
            g.draw(d.image, d.x, d.y, 0, 1, 1, iw / 2, ih / 2)
        end
    end
    g.setColor(1, 1, 1)
end

-- Flying iron/metal shrapnel from explosions (buildings and bombs). Drawn as its
-- own overlay (after the explosion effects) so the chunks stay visible on top of
-- the blast; tiled like the world so it wraps at the seam.
function Renderer:draw_debris()
    local w = self.world
    if #w.debris.pieces == 0 and #w.debris.puffs == 0 then return end
    local g  = love.graphics
    local vp = self.camera:viewport()
    g.push()
    self.camera:apply()
    for _, t in ipairs(self.camera:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        self:_draw_debris({
            x0 = vp.x0 - t.ox, x1 = vp.x1 - t.ox,
            y0 = vp.y0 - t.oy, y1 = vp.y1 - t.oy,
        })
        g.pop()
    end
    g.pop()
end

function Renderer:_draw_debris(vp)
    local g = love.graphics
    g.setColor(1, 1, 1)
    for _, puff in ipairs(self.world.debris.puffs) do
        if puff.x >= vp.x0 and puff.x <= vp.x1 and puff.y >= vp.y0 and puff.y <= vp.y1 then
            local img = puff.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.draw(img, puff.x, puff.y, 0, 1, 1, iw / 2, ih / 2)
            end
        end
    end
    for _, d in ipairs(self.world.debris.pieces) do
        if d.x >= vp.x0 and d.x <= vp.x1 and d.y >= vp.y0 and d.y <= vp.y1 then
            local img = d.image
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1, d.alpha)
                g.draw(img, d.x, d.y, 0, 1, 1, iw / 2, ih / 2)
            end
        end
    end
    g.setColor(1, 1, 1)
end

-- Persistent damage smoke and one-shot hit smoke for an entity.
function Renderer:_draw_smokes(e)
    local g = love.graphics
    for _, se in ipairs(e._damage_smokes) do
        local img = se.anim:current_image()
        if img then
            local iw, ih = img:getDimensions()
            g.setColor(1, 1, 1, 0.85)
            g.draw(img, e.x + se.ox, e.y + se.oy, 0, 1, 1, iw / 2, ih / 2)
            g.setColor(1, 1, 1)
        end
    end
    for _, hs in ipairs(e._hit_smokes) do
        local img = hs.anim:current_image()
        if img then
            local iw, ih = img:getDimensions()
            g.draw(img, e.x + hs.ox, e.y + hs.oy, 0, 1, 1, iw / 2, ih / 2)
        end
    end
end

function Renderer:_draw_unit(e)
    local g  = love.graphics
    local td = e.type_data
    local x, y = e.x + e.death_ox, e.y + e.death_oy
    local rot  = (e.aim_angle + (td.sprite_rot or 0)) * math.pi / 180

    -- Prefer the stage's own asset sprite (frame 0 alive, dead-pose frame as the
    -- corpse) so every stage shows its own unit art; fall back to the named clip
    -- only if the stage lacks a render image.
    local r   = self.world.images[e.class_idx + 1]
    local img = r and (e:is_alive() and r.img or (r.dead or r.img)) or nil
    if not img then
        local clip = Animation.clip(e:is_alive() and td.sprite or (td.dead_sprite or td.sprite))
        img = clip and clip.frames[1] or nil
    end
    if img then
        local iw, ih = img:getDimensions()
        g.setColor(1, 1, 1)
        g.draw(img, x, y, rot, 1, 1, iw / 2, ih / 2)
        if e.objective and e:is_alive() then self:_glint(img, x, y, rot, iw / 2, ih / 2) end
        if e == self.highlight then
            self:_glow(img, x, y, rot, 1, 1, iw / 2, ih / 2)
        end
    end
    if e:is_alive() then self:_draw_smokes(e) end
end

return Renderer
