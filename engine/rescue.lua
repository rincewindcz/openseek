local Class     = require "engine.class"
local Animation = require "engine.animation"
local Config    = require "engine.config"
local Mathx     = require "engine.core.mathx"

-- POW rescue from POWHERE buildings. Each powhere.bin marker (World.rescue_zones)
-- is a building holding one or more POWs and is paired with the nearest lh.bin
-- "land here" marker. Co-located powhut.bin huts are shielded from damage while
-- the building still holds POWs. When a vehicle sits on the land marker long
-- enough the POWs walk out one by one to the vehicle (rescued on contact) and
-- walk back if the vehicle leaves; a POW can be shot while outside. Once a
-- building is emptied its marker and land pad vanish and its huts become
-- destructible. Stages whose rescue objective is loose civilians (no powhere)
-- are left to the mission's simple fly-over collection instead.
local RescueSystem = Class()

local POW_CLIPS       = { "newdude0", "pow0", "pow1" }
local DWELL_TIME      = 1.0  -- seconds the vehicle must hold the land pad before POWs emerge
local SPAWN_GAP       = 0.7  -- seconds between successive POWs leaving the building
local WALK_SPEED      = 26   -- px/s a POW walks
local LAND_RADIUS     = 40   -- vehicle must be stationary within this of the land marker
local REACH_RADIUS    = 6    -- distance at which a POW reaches the door / vehicle
local POW_HIT_RADIUS  = 6    -- a POW's collision radius when shot
local COLOCATE_RADIUS = 12   -- a building this close under the marker is its paired hull
local POW_ROT         = 0    -- rest-pose facing offset (deg) added to the walk heading
local LH_FADE         = 0.2  -- seconds for the land pad to fade out/in
local ZONE_FADE       = 0.3  -- seconds for the POWHERE marker to fade out once emptied
local EXIT_GAP        = 4    -- px the POW emerges outside the building edge
local CORPSE_PUSH     = 5    -- px a shot POW's body slides in the shot direction
local SLIDE_TIME      = 0.12 -- seconds for that slide to settle

function RescueSystem:init(world, combat)
    self.world      = world
    self.combat     = combat
    self.sites      = {}
    self.active     = false
    self.pow_counts = nil   -- optional per-building POW counts (set before reset)
    world.rescue    = self
end

-- POWs per building: an explicit per-building count (pow_counts, in zone load
-- order) when supplied, otherwise a random 1-3.
function RescueSystem:_count_for(idx)
    local c = self.pow_counts and self.pow_counts[idx]
    return c or math.random(1, 3)
end

function RescueSystem:_nearest_land(zone, taken)
    local best, best_dist
    for _, land_zone in ipairs(self.world.land_zones) do
        if not taken[land_zone] then
            local dx, dy = self.world:delta(land_zone.ent.x, land_zone.ent.y, zone.x, zone.y)
            local d = dx * dx + dy * dy
            if not best_dist or d < best_dist then best, best_dist = land_zone, d end
        end
    end
    return best
end

-- The destructible building directly under the marker (bunker, powhut, ...),
-- paired with it like a tank hull under its turret and shielded until the
-- building is emptied. Matches by co-location regardless of the building asset.
function RescueSystem:_paired_buildings(zone)
    local buildings = {}
    for _, e in ipairs(self.world.objects) do
        local cls = self.world.stage.classes[e.class_idx + 1]
        if cls and cls.kind_name == "structure" then
            local dx, dy = self.world:delta(e.x, e.y, zone.x, zone.y)
            if dx * dx + dy * dy <= COLOCATE_RADIUS * COLOCATE_RADIUS then buildings[#buildings + 1] = e end
        end
    end
    return buildings
end

function RescueSystem:reset()
    self.sites  = {}
    self.active = #self.world.rescue_zones > 0
    if not self.active then return end
    local taken = {}
    for idx, zone in ipairs(self.world.rescue_zones) do
        local land  = self:_nearest_land(zone, taken)
        if land then taken[land] = true end
        local buildings = self:_paired_buildings(zone)
        for _, b in ipairs(buildings) do b.protected = true end
        local total = self:_count_for(idx)
        local lx = land and land.ent.x or zone.x
        local ly = land and land.ent.y or zone.y
        local ex, ey = self:_exit_point(zone, buildings[1], lx, ly)
        self.sites[#self.sites + 1] = {
            zone      = zone,
            land      = land,
            lx        = lx,
            ly        = ly,
            ex        = ex,    -- where POWs emerge / re-enter (the building edge by the pad)
            ey        = ey,
            buildings = buildings,
            total    = total,
            inside   = total,   -- POWs still in the building
            rescued  = 0,
            lost     = 0,       -- POWs shot while outside
            pows     = {},      -- POWs currently walking
            corpses  = {},      -- bodies of POWs shot in the open (persist on the ground)
            dwell     = 0,
            spawn_t   = 0,
            lh_alpha  = 1,      -- land pad opacity (fades out while a vehicle holds it)
            zone_alpha = 1,     -- POWHERE marker opacity (fades out once emptied)
            cleared   = false,
        }
    end
end

-- A point just outside the building's edge on the side facing the land pad, so
-- POWs appear next to the building rather than on top of it.
function RescueSystem:_exit_point(zone, building, lx, ly)
    local building_radius = 12
    if building then
        local r = self.world.images[building.class_idx + 1]
        if r and r.img then
            local iw, ih = r.img:getDimensions()
            building_radius = math.max(iw, ih) / 2
        end
    end
    local ddx, ddy = self.world:delta(lx, ly, zone.x, zone.y)   -- building toward pad
    local pad_distance = math.sqrt(ddx * ddx + ddy * ddy)
    if pad_distance <= 0 then return zone.x, zone.y end
    local exit_offset = math.max(8, math.min(building_radius + EXIT_GAP, pad_distance - 8))
    return zone.x + ddx / pad_distance * exit_offset, zone.y + ddy / pad_distance * exit_offset
end

function RescueSystem:clear()
    self.sites  = {}
    self.active = false
end

-- The shared dead-soldier pose, used as the corpse of a shot POW (cached).
function RescueSystem:_dead_image()
    if self._dead_img == nil then
        local clip = Animation.clip("soldier_dead")
        self._dead_img = (clip and clip.frames[1]) or false
    end
    return self._dead_img or nil
end

-- progress

function RescueSystem:_landed_in_zone(p, site)
    if not p:is_stationary() then return false end
    local dx, dy = self.world:delta(p.x, p.y, site.lx, site.ly)
    return dx * dx + dy * dy <= LAND_RADIUS * LAND_RADIUS
end

function RescueSystem:_emerge(site, target)
    site.inside = site.inside - 1
    site.pows[#site.pows + 1] = {
        x = site.ex, y = site.ey,
        state   = "out",
        target  = target,
        heading = 0,
        anim    = Animation.new(POW_CLIPS[math.random(#POW_CLIPS)]),
    }
end

function RescueSystem:_update_pow(pow, site, dt, lander)
    pow.anim:update(dt)
    -- While a vehicle holds the pad the POW heads for it; otherwise it walks home.
    if lander then
        pow.target = lander
        pow.state  = "out"
    else
        pow.state = "back"
    end

    local gx, gy, reach
    if pow.state == "out" then
        gx, gy = pow.target.x, pow.target.y
        reach  = (pow.target.collision_radius or 8) + REACH_RADIUS
    else
        gx, gy = site.ex, site.ey   -- back to the door, not the building center
        reach  = REACH_RADIUS
    end

    local dx, dy = self.world:delta(gx, gy, pow.x, pow.y)
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= reach then
        if pow.state == "out" then
            site.rescued     = site.rescued + 1
            pow.target.pows  = (pow.target.pows or 0) + 1
            pow.target.score = (pow.target.score or 0) + 150
        else
            site.inside = site.inside + 1   -- back inside, waits to be rescued again
        end
        pow.done = true
        return
    end

    -- Face the way it walks (heading: 0 = north, clockwise; dx,dy point at the goal).
    pow.heading = Mathx.heading_deg(dx, dy)
    local step = WALK_SPEED * dt * Config.speed_scale
    local s    = self.world.stage.world_size
    pow.x = (pow.x + dx / d * step) % s
    pow.y = (pow.y + dy / d * step) % s
end

-- A shot POW drops where it stood: a dead-soldier body that slides a little in the
-- shot direction and then lies there, plus a small hit puff, like a felled soldier.
function RescueSystem:_kill_pow(site, pow, hx, hy)
    local px, py = 0, 0
    local dx, dy = self.world:delta(pow.x, pow.y, hx, hy)   -- impact toward POW = push dir
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0 then px, py = dx / len * CORPSE_PUSH, dy / len * CORPSE_PUSH end
    site.corpses[#site.corpses + 1] = {
        x = pow.x, y = pow.y, ox = 0, oy = 0, px = px, py = py, t = 0,
        heading = pow.heading or 0,
    }
    if self.combat then self.combat:add_effect("smoke2", pow.x, pow.y, {}) end
end

function RescueSystem:_clear_site(site)
    site.cleared = true
    for _, b in ipairs(site.buildings) do b.protected = false end
    site.zone.rescue_hidden = true
end

function RescueSystem:update(dt)
    if not self.active then return end
    local players = self.combat.players or {}
    for _, site in ipairs(self.sites) do
        for _, c in ipairs(site.corpses) do
            if c.t < 1 then
                c.t = math.min(1, c.t + dt / SLIDE_TIME)
                local f = 1 - (1 - c.t) * (1 - c.t)
                c.ox, c.oy = c.px * f, c.py * f
            end
        end
        if site.cleared then
            -- Marker keeps fading after the renderer hands it off (rescue_hidden).
            if site.zone_alpha > 0 then
                site.zone_alpha = math.max(0, site.zone_alpha - dt / ZONE_FADE)
            end
        else
            local lander
            for _, p in ipairs(players) do
                if p and not p.death and self:_landed_in_zone(p, site) then lander = p; break end
            end

            if lander then site.dwell = site.dwell + dt else site.dwell = 0 end

            -- The land pad vanishes the moment a vehicle sits on it and fades back in if
            -- the vehicle leaves before the building is emptied.
            local target = lander and 0 or 1
            local fade   = dt / LH_FADE
            site.lh_alpha = (site.lh_alpha < target)
                and math.min(target, site.lh_alpha + fade)
                or  math.max(target, site.lh_alpha - fade)

            if lander and site.dwell >= DWELL_TIME and site.inside > 0 then
                site.spawn_t = site.spawn_t - dt
                if site.spawn_t <= 0 then
                    site.spawn_t = SPAWN_GAP
                    self:_emerge(site, lander)
                end
            end

            local keep = {}
            for _, pow in ipairs(site.pows) do
                if not pow.done then self:_update_pow(pow, site, dt, lander) end
                if not pow.done then keep[#keep + 1] = pow end
            end
            site.pows = keep

            if site.inside == 0 and #site.pows == 0
            and (site.rescued + site.lost) >= site.total then
                self:_clear_site(site)
            end
        end
    end
end

-- A projectile passed (x, y); kill any POW it touches. Enemy rounds always kill;
-- the player's own rounds only when the friendly-fire option is on. Returns true
-- if a POW was hit so the caller can consume the round.
function RescueSystem:projectile_hit(x, y, radius, from_player)
    if not self.active then return false end
    if from_player and not Config.friendly_fire_pows then return false end
    for _, site in ipairs(self.sites) do
        if not site.cleared then
            for _, pow in ipairs(site.pows) do
                if not pow.done then
                    local dx, dy = self.world:delta(pow.x, pow.y, x, y)
                    local rr = radius + POW_HIT_RADIUS
                    if dx * dx + dy * dy < rr * rr then
                        pow.done  = true
                        site.lost = site.lost + 1
                        self:_kill_pow(site, pow, x, y)
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- objective queries (read by Mission)

function RescueSystem:rescued_count()
    local n = 0
    for _, s in ipairs(self.sites) do n = n + s.rescued end
    return n
end

-- Initial POW total minus those lost, so the objective stays completable.
function RescueSystem:required_count()
    local n = 0
    for _, s in ipairs(self.sites) do n = n + (s.total - s.lost) end
    return n
end

function RescueSystem:all_cleared()
    for _, s in ipairs(self.sites) do
        if not s.cleared then return false end
    end
    return true
end

-- draw

function RescueSystem:draw()
    if not self.active then return end
    local g    = love.graphics
    local cam  = self.combat.camera
    -- Land pads follow the pickups option: screen-upright (original) or world-rotated.
    local mrot = Config.axis_aligned_pickups and -(cam.angle or 0) or 0
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        -- Corpses of shot POWs lie on the ground under the live markers/walkers.
        local dead = self:_dead_image()
        if dead then
            local dw, dh = dead:getDimensions()
            for _, site in ipairs(self.sites) do
                for _, c in ipairs(site.corpses) do
                    local rot = (c.heading + POW_ROT) * math.pi / 180
                    g.setColor(1, 1, 1)
                    g.draw(dead, c.x + c.ox, c.y + c.oy, rot, 1, 1, dw / 2, dh / 2)
                end
            end
        end
        -- Emptied POWHERE markers fade out (the renderer stopped drawing them at clear).
        for _, site in ipairs(self.sites) do
            if site.cleared and site.zone_alpha > 0.01 then
                local e = site.zone
                local r = self.world.images[e.class_idx + 1]
                if r and r.img then
                    g.setColor(1, 1, 1, site.zone_alpha)
                    g.draw(r.img, e.x, e.y, 0, 1, 1, -r.ox, -r.oy)
                end
            end
        end
        for _, site in ipairs(self.sites) do
            if not site.cleared and site.land and site.lh_alpha > 0.01 then
                local r = self.world.images[site.land.ent.class_idx + 1]
                if r and r.img then
                    local iw, ih = r.img:getDimensions()
                    g.setColor(1, 1, 1, site.lh_alpha)
                    g.draw(r.img, site.land.ent.x + r.ox + iw / 2, site.land.ent.y + r.oy + ih / 2,
                        mrot, 1, 1, iw / 2, ih / 2)
                end
            end
        end
        for _, site in ipairs(self.sites) do
            for _, pow in ipairs(site.pows) do
                local img = pow.anim:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    local rot = ((pow.heading or 0) + POW_ROT) * math.pi / 180
                    g.setColor(1, 1, 1)
                    g.draw(img, pow.x, pow.y, rot, 1, 1, iw / 2, ih / 2)
                end
            end
        end
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

return RescueSystem
