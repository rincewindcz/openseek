local Class     = require "engine.core.class"
local Animation = require "engine.core.animation"
local Config    = require "engine.core.config"
local Mathx     = require "engine.core.mathx"

-- Saboteur / demolition objective (mission 1 phases). Each landhere.bin pad is
-- paired with the nearest target building (asset set from missions.json). The
-- building is shielded from weapons; the only way to destroy it is to land a
-- vehicle on the pad, which sends a friendly saboteur (effects/pow1) walking from
-- the vehicle into the building to plant a charge. Two detonation styles, chosen
-- per stage:
--   * "individual" - the building self-detonates a fixed time after its own charge
--     is planted; the saboteur walks back out to the pad meanwhile (stage11).
--   * "all"        - every building holds until every charge is planted, then they
--     all blow at once and the agents run back out to their pads (stage13).
-- The saboteur waits on its pad to be picked up. A site clears once its building is
-- destroyed and its saboteur recovered; the objective completes when every site is
-- cleared. On "killable" stages an agent cut down in the open fails the mission.
local SaboteurSystem = Class()

local SABOTEUR_CLIP = "pow1"
local DWELL_TIME    = 1.0   -- seconds a vehicle must hold the pad before the saboteur emerges
local WALK_SPEED    = 26    -- px/s the saboteur walks
local LAND_RADIUS   = 40    -- vehicle must be stationary within this of the pad
local REACH_RADIUS  = 6     -- distance at which the saboteur reaches the door / pad
local INSIDE_TIME   = 5.0   -- (individual) seconds the saboteur stays inside planting the charge
local DETONATE_TIME = 10.0  -- (individual) seconds from charge planted until the building blows
local LH_FADE       = 0.2   -- seconds for the pad to fade out/in under a vehicle
local ZONE_FADE     = 0.3   -- seconds for the pad to fade out once its site is cleared
local EXIT_GAP      = 4     -- px the saboteur stands off the building edge
local POW_ROT       = 0     -- rest-pose facing offset (deg) added to the walk heading
local HIT_RADIUS    = 6     -- an exposed saboteur's collision radius when shot

function SaboteurSystem:init(world, combat)
    self.world    = world
    self.combat   = combat
    self.sites    = {}
    self.active   = false
    self.spec     = nil    -- the missions.json sabotage objective spec (set before reset)
    self.blown    = false  -- ("all" mode) the synchronized detonation has fired
    self.failed   = false  -- a saboteur was killed on a "killable" stage
    world.saboteur = self
end

function SaboteurSystem:_nearest_building(pad, taken, buildings)
    local best, best_dist
    for _, b in ipairs(buildings) do
        if not taken[b] then
            local dx, dy = self.world:delta(b.x, b.y, pad.ent.x, pad.ent.y)
            local d = dx * dx + dy * dy
            if not best_dist or d < best_dist then best, best_dist = b, d end
        end
    end
    return best
end

-- A point just outside the building's edge on the side facing the pad, so the
-- saboteur appears next to the door rather than on top of the building.
function SaboteurSystem:_exit_point(building, px, py)
    local radius = 12
    local r = self.world.images[building.class_idx + 1]
    if r and r.img then
        local iw, ih = r.img:getDimensions()
        radius = math.max(iw, ih) / 2
    end
    local ddx, ddy = self.world:delta(px, py, building.x, building.y)   -- building toward pad
    local dist = math.sqrt(ddx * ddx + ddy * ddy)
    if dist <= 0 then return building.x, building.y end
    local offset = math.max(8, math.min(radius + EXIT_GAP, dist - 8))
    return building.x + ddx / dist * offset, building.y + ddy / dist * offset
end

function SaboteurSystem:reset()
    self.sites  = {}
    self.blown  = false
    self.failed = false
    local spec = self.spec
    self.mode          = (spec and spec.detonate) or "individual"
    self.killable      = spec and spec.killable or false
    self.inside_time   = spec and spec.inside_time or INSIDE_TIME
    self.detonate_time = spec and spec.detonate_time or DETONATE_TIME
    self.active = spec ~= nil and spec.target ~= nil and #self.world.saboteur_pads > 0
    if not self.active then return end

    local buildings = {}
    for _, e in ipairs(self.world.objects) do
        if e.asset_file == spec.target then buildings[#buildings + 1] = e end
    end

    local taken = {}
    for _, pad in ipairs(self.world.saboteur_pads) do
        local b = self:_nearest_building(pad, taken, buildings)
        if b then
            taken[b]    = true
            b.protected = true
            b.objective = true               -- white dot on the radar
            pad.ent.sabotage_hidden = true   -- the system draws this pad now, not the renderer
            local ex, ey = self:_exit_point(b, pad.ent.x, pad.ent.y)
            self.sites[#self.sites + 1] = {
                pad        = pad,
                building   = b,
                px         = pad.ent.x,
                py         = pad.ent.y,
                ex         = ex,    -- the building door the saboteur enters / exits
                ey         = ey,
                state      = "idle",     -- idle -> dispatched
                dwell      = 0,
                lh_alpha   = 1,          -- pad opacity (fades out while a vehicle holds it)
                saboteur   = nil,        -- the walking unit once dispatched
                planted    = false,      -- charge set (saboteur reached the building)
                armed      = false,      -- (individual) detonation counting down
                detonate_t = 0,
                detonated  = false,
                recovered  = false,
                cleared    = false,
                lost       = false,      -- saboteur killed in the open
            }
        end
    end
    self.active = #self.sites > 0
end

function SaboteurSystem:clear()
    self.sites  = {}
    self.active = false
    self.blown  = false
    self.failed = false
end

function SaboteurSystem:_landed_on_pad(p, site)
    if not p:is_stationary() then return false end
    local dx, dy = self.world:delta(p.x, p.y, site.px, site.py)
    return dx * dx + dy * dy <= LAND_RADIUS * LAND_RADIUS
end

function SaboteurSystem:_dispatch(site, lander)
    site.saboteur = {
        x        = lander.x,
        y        = lander.y,
        heading  = 0,
        phase    = "to_building",
        inside_t = 0,
        anim     = Animation.new(SABOTEUR_CLIP),
    }
    site.state = "dispatched"
end

-- Walk the saboteur toward (gx, gy); returns true on arrival.
function SaboteurSystem:_walk_to(sab, gx, gy, reach, dt)
    local dx, dy = self.world:delta(gx, gy, sab.x, sab.y)
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= reach then return true end
    sab.heading = Mathx.heading_deg(dx, dy)
    local step = WALK_SPEED * dt * Config.speed_scale
    local s    = self.world.stage.world_size
    sab.x = (sab.x + dx / d * step) % s
    sab.y = (sab.y + dy / d * step) % s
    return false
end

function SaboteurSystem:_blow_building(site)
    local b = site.building
    b.protected = false
    if b:is_alive() then
        local dx, dy = self.world:delta(b.x, b.y, site.ex, site.ey)
        b:take_damage((b.hp or 1) + 1, dx, dy)
    end
    self.combat:add_effect("explosion_large", b.x, b.y, { scale = 1.5 })
    site.detonated = true
end

function SaboteurSystem:_all_planted()
    for _, site in ipairs(self.sites) do
        if not site.planted then return false end
    end
    return true
end

function SaboteurSystem:_update_saboteur(site, dt, lander)
    local sab = site.saboteur
    sab.anim:update(dt)
    if sab.phase == "to_building" then
        if self:_walk_to(sab, site.ex, site.ey, REACH_RADIUS, dt) then
            site.planted = true
            sab.phase    = "inside"
            if self.mode == "individual" then
                sab.inside_t    = self.inside_time
                site.armed      = true
                site.detonate_t = self.detonate_time
            end
        end
    elseif sab.phase == "inside" then
        -- "individual": step back out on the charge timer. "all": wait inside until
        -- the synchronized blast releases every agent at once.
        if self.mode == "individual" then
            sab.inside_t = sab.inside_t - dt
            if sab.inside_t <= 0 then
                sab.x, sab.y = site.ex, site.ey
                sab.phase = "to_pad"
            end
        end
    elseif sab.phase == "to_pad" then
        if self:_walk_to(sab, site.px, site.py, REACH_RADIUS, dt) then
            sab.phase = "pickup"
        end
    elseif sab.phase == "pickup" then
        if lander then
            site.recovered = true
            lander.pows  = (lander.pows or 0) + 1
            lander.score = (lander.score or 0) + 150
        end
    end
end

function SaboteurSystem:update(dt)
    if not self.active then return end
    local players = self.combat.players or {}

    -- "all" mode: once every charge is planted the whole set blows at once and the
    -- agents step out of the rubble to run home.
    if self.mode == "all" and not self.blown and self:_all_planted() then
        for _, site in ipairs(self.sites) do
            self:_blow_building(site)
            local sab = site.saboteur
            if sab then sab.x, sab.y = site.ex, site.ey; sab.phase = "to_pad" end
        end
        self.blown = true
    end

    for _, site in ipairs(self.sites) do
        if site.cleared then
            if site.lh_alpha > 0 then
                site.lh_alpha = math.max(0, site.lh_alpha - dt / ZONE_FADE)
            end
        else
            local lander
            for _, p in ipairs(players) do
                if p and not p.death and self:_landed_on_pad(p, site) then lander = p; break end
            end

            -- The pad fades out while a vehicle sits on it, back in when it leaves.
            local target = lander and 0 or 1
            local fade   = dt / LH_FADE
            site.lh_alpha = (site.lh_alpha < target)
                and math.min(target, site.lh_alpha + fade)
                or  math.max(target, site.lh_alpha - fade)

            if site.state == "idle" then
                if lander then site.dwell = site.dwell + dt else site.dwell = 0 end
                if site.dwell >= DWELL_TIME then self:_dispatch(site, lander) end
            elseif site.saboteur then
                self:_update_saboteur(site, dt, lander)
            end

            -- "individual" mode: each building blows on its own charge timer.
            if self.mode == "individual" and site.armed and not site.detonated then
                site.detonate_t = site.detonate_t - dt
                if site.detonate_t <= 0 then self:_blow_building(site) end
            end

            if site.detonated and site.recovered then site.cleared = true end
        end
    end
end

-- A projectile passed (x, y); cut down any exposed saboteur it touches on a
-- killable stage, which fails the mission. Enemy rounds always kill; the player's
-- own rounds only when the friendly-fire option is on. Returns true on a hit.
function SaboteurSystem:projectile_hit(x, y, radius, from_player)
    if not self.active or not self.killable then return false end
    if from_player and not Config.friendly_fire_pows then return false end
    for _, site in ipairs(self.sites) do
        local sab = site.saboteur
        if sab and not site.lost and (sab.phase == "to_building" or sab.phase == "to_pad") then
            local dx, dy = self.world:delta(sab.x, sab.y, x, y)
            local rr = radius + HIT_RADIUS
            if dx * dx + dy * dy < rr * rr then
                site.lost     = true
                site.saboteur = nil
                self.failed   = true
                self.combat:add_effect("smoke2", x, y, {})
                return true
            end
        end
    end
    return false
end

-- objective queries (read by Mission)

function SaboteurSystem:cleared_count()
    local n = 0
    for _, s in ipairs(self.sites) do
        if s.cleared then n = n + 1 end
    end
    return n
end

function SaboteurSystem:all_cleared()
    for _, s in ipairs(self.sites) do
        if not s.cleared then return false end
    end
    return true
end

function SaboteurSystem:mission_failed()
    return self.failed
end

-- draw

-- Four L-shaped corners forming a target reticle around (cx, cy).
function SaboteurSystem:_corner_box(cx, cy, hw, hh)
    local g = love.graphics
    local l = math.max(3, math.min(hw, hh) * 0.5)
    local x0, y0, x1, y1 = cx - hw, cy - hh, cx + hw, cy + hh
    g.line(x0, y0, x0 + l, y0); g.line(x0, y0, x0, y0 + l)
    g.line(x1, y0, x1 - l, y0); g.line(x1, y0, x1, y0 + l)
    g.line(x0, y1, x0 + l, y1); g.line(x0, y1, x0, y1 - l)
    g.line(x1, y1, x1 - l, y1); g.line(x1, y1, x1, y1 - l)
end

function SaboteurSystem:draw()
    if not self.active then return end
    local g   = love.graphics
    local cam = self.combat.camera
    -- Pads follow the pickups option: screen-upright (original) or world-rotated.
    local mrot = Config.axis_aligned_pickups and -(cam.angle or 0) or 0
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)

        for _, site in ipairs(self.sites) do
            if site.lh_alpha > 0.01 then
                local r = self.world.images[site.pad.ent.class_idx + 1]
                if r and r.img then
                    local iw, ih = r.img:getDimensions()
                    g.setColor(1, 1, 1, site.lh_alpha)
                    g.draw(r.img, site.pad.ent.x + r.ox + iw / 2, site.pad.ent.y + r.oy + ih / 2,
                        mrot, 1, 1, iw / 2, ih / 2)
                end
            end
        end

        -- Reticle every live target building so the player can find them.
        g.setLineWidth(2 / cam:zoom())
        g.setColor(1, 0.5, 0.2, 0.7 + 0.3 * math.sin(love.timer.getTime() * 5))
        for _, site in ipairs(self.sites) do
            local b = site.building
            if not site.detonated and b:is_alive() then
                local hw, hh, cx, cy = 9, 9, b.x, b.y
                local r = self.world.images[b.class_idx + 1]
                if r and r.img then
                    local iw, ih = r.img:getDimensions()
                    hw, hh = iw / 2 + 4, ih / 2 + 4
                    cx, cy = b.x + r.ox + iw / 2, b.y + r.oy + ih / 2
                end
                self:_corner_box(cx, cy, hw, hh)
            end
        end
        g.setLineWidth(1)

        for _, site in ipairs(self.sites) do
            local sab = site.saboteur
            if sab and sab.phase ~= "inside" then
                local img = sab.anim:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    local rot = ((sab.heading or 0) + POW_ROT) * math.pi / 180
                    g.setColor(1, 1, 1)
                    g.draw(img, sab.x, sab.y, rot, 1, 1, iw / 2, ih / 2)
                end
            end
        end
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

return SaboteurSystem
