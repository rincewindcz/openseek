-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local Animation = require "engine.core.animation"
local Config    = require "engine.core.config"
local Mathx     = require "engine.core.mathx"

-- People to bring home, on the original's rules (building update 0x1fefb0,
-- person update 0x203c90, one tick = 1/70 s).
--
-- A building holds the number of people its class names (World: entity.pows)
-- and is tied to one pickup pad (World.land_zones). While a vehicle sits on the
-- ground at the pad they run out one at a time and board on reaching it; when
-- it leaves, those still outside walk back in. They start and end under the
-- building's roof (the scenes draw the people below the solid objects), so
-- they are seen coming out of it and going back into it. The building cannot
-- be damaged until the last one is out, and its POWHERE flag and pad show only
-- while somebody is inside. People placed on the stage (the crash-site crews,
-- World.rescue_people) wait by their wreck and run over once a vehicle is down
-- near it. Anyone outside can be shot, and those aboard die with the vehicle.
local RescueSystem = Class()

local TICK         = 1 / 70
local WALK_SPEED   = 35          -- px/s: half a pixel a tick
local LAND_RADIUS  = 24          -- a vehicle on the ground this close to the pad calls them out
local CREW_RADIUS  = 50          -- the same for a placed crew, measured from their wreck
local BOARD_RADIUS = 16          -- distance to the vehicle at which a person is aboard
local ENTER_RADIUS = 4           -- distance to the building's middle at which one walking back is inside
local FIRST_GAP    = 2 * TICK    -- wait before the first person shows
local EMERGE_GAP   = 120 * TICK  -- wait between two people leaving; cut short when one boards or dies
local RETURN_GAP   = 60 * TICK   -- wait after one walked back in
local HIT_RADIUS   = 6           -- a person's collision radius when shot
local PAD_FADE     = 0.2         -- seconds for the pad to fade out / in
local ZONE_FADE    = 0.3         -- seconds for the POWHERE flag to fade out
local BODY_TIME    = 42 * TICK   -- a body is flung for two turns of its 32-step spin (0x1fb870)
local BODY_SPIN    = 1.5 * 70 * 360 / 32   -- deg/s: one and a half of those steps a tick
local BODY_BOOST   = 4           -- a body leaves at this many times the round's speed (0x203a9c),
local BODY_SPEED   = 280         -- at most this fast along either axis (px/s)

function RescueSystem:init(world, combat)
    self.world   = world
    self.combat  = combat
    self.sites   = {}
    self.crew    = {}
    self.bodies  = {}
    self.carried = {}   -- player -> people aboard that vehicle
    self.total   = 0
    self.lost    = 0
    self.active  = false
    world.rescue = self
end

function RescueSystem:reset()
    self.sites, self.crew, self.bodies, self.carried = {}, {}, {}, {}
    self.total, self.lost = 0, 0
    self.walk_clip = self.world:walker_clip()
    self.body_clip = self.world:walker_clip("_dead")
    for _, zone in ipairs(self.world.land_zones) do
        local building = zone.building
        local count    = building.pows or 0
        if count > 0 then
            building.protected = true
            self.sites[#self.sites + 1] = {
                pad        = zone.ent,
                building   = building,
                marker     = building.pow_marker,
                px         = zone.ent.x,
                py         = zone.ent.y,
                inside     = count,
                walkers    = {},
                timer      = FIRST_GAP,
                pad_alpha  = 1,
                zone_alpha = 0,     -- the flag, once the renderer hands it over to fade out
            }
            self.total = self.total + count
        end
    end
    for _, person in ipairs(self.world.rescue_people) do
        person.ent.rescue_hidden = true   -- drawn here from now on
        self.crew[#self.crew + 1] = {
            ent     = person.ent,
            home    = person.home,
            x       = person.ent.x,
            y       = person.ent.y,
            heading = 0,
            anim    = Animation.new(self.walk_clip),
            on_foot = true,
        }
        self.total = self.total + 1
    end
    self.active = self.total > 0
end

function RescueSystem:clear()
    for _, person in ipairs(self.crew) do person.ent.rescue_hidden = nil end
    self.sites, self.crew, self.bodies, self.carried = {}, {}, {}, {}
    self.total, self.lost = 0, 0
    self.active = false
end

-- progress

-- The first vehicle sitting on the ground within radius of (x, y). The original
-- asks only for altitude 0, so a tank counts while it drives through.
function RescueSystem:_lander(x, y, radius)
    for _, p in ipairs(self.combat.players or {}) do
        if p and not p.death and not p:is_airborne() then
            local dx, dy = self.world:delta(p.x, p.y, x, y)
            if dx * dx + dy * dy <= radius * radius then return p end
        end
    end
end

-- Step a person toward (gx, gy); true once within reach.
function RescueSystem:_walk(person, gx, gy, reach, dt)
    local dx, dy = self.world:delta(gx, gy, person.x, person.y)
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= reach then return true end
    person.anim:update(dt)
    -- Face the way it walks (heading: 0 = north, clockwise; dx,dy point at the goal).
    person.heading = Mathx.heading_deg(dx, dy)
    local step = WALK_SPEED * dt * Config.speed_scale
    local s    = self.world.stage.world_size
    person.x = (person.x + dx / d * step) % s
    person.y = (person.y + dy / d * step) % s
    return false
end

function RescueSystem:_board(player)
    self.carried[player] = (self.carried[player] or 0) + 1
    player.pows          = (player.pows or 0) + 1
    self.world:say("voice.pow_aboard")
end

-- The building can be hit again from the moment its last occupant is aboard or
-- dead, even with others still on their way (0x203fba, 0x1fe8ef).
function RescueSystem:_release_building(site)
    if site.inside == 0 then site.building.protected = false end
end

function RescueSystem:_update_site(site, dt)
    if site.inside > 0 and not site.building:is_alive() then
        self.lost   = self.lost + site.inside   -- brought down with people still inside
        site.inside = 0
    end
    local lander = self:_lander(site.px, site.py, LAND_RADIUS)
    site.timer = math.max(0, site.timer - dt)
    local building = site.building
    if site.inside > 0 and lander and site.timer <= 0 then
        site.inside = site.inside - 1
        site.timer  = EMERGE_GAP
        local walker = {
            x = building.x, y = building.y, heading = 0, anim = Animation.new(self.walk_clip), on_foot = true,
        }
        site.walkers[#site.walkers + 1] = walker
        self.combat:person_out(walker)
    end

    local keep = {}
    for _, walker in ipairs(site.walkers) do
        if lander then
            if self:_walk(walker, lander.x, lander.y, BOARD_RADIUS, dt) then
                walker.done = true
                site.timer  = 0
                self:_board(lander)
                self:_release_building(site)
                if site.inside == 0 and #site.walkers == 1 then self.world:say("voice.pow_delivered") end
            end
        elseif self:_walk(walker, building.x, building.y, ENTER_RADIUS, dt) then
            walker.done = true
            site.inside = site.inside + 1   -- back inside, waits to be called out again
            site.timer  = RETURN_GAP
        end
        if not walker.done then keep[#keep + 1] = walker end
    end
    site.walkers = keep

    -- The flag and the pad stand only while somebody is inside (0x1ff044).
    local held = site.inside > 0
    if site.marker then
        if held then
            site.marker.rescue_hidden, site.marker.objective, site.zone_alpha = false, true, 1
        else
            site.marker.rescue_hidden, site.marker.objective = true, nil
            site.zone_alpha = math.max(0, site.zone_alpha - dt / ZONE_FADE)
        end
    end
    local fade = dt / PAD_FADE
    site.pad_alpha = held and math.min(1, site.pad_alpha + fade) or math.max(0, site.pad_alpha - fade)
end

function RescueSystem:_update_crew(dt)
    local keep = {}
    for _, person in ipairs(self.crew) do
        local lander = self:_lander(person.home.x, person.home.y, CREW_RADIUS)
        if lander and self:_walk(person, lander.x, lander.y, BOARD_RADIUS, dt) then
            person.done          = true
            person.ent.objective = nil   -- off the radar
            self:_board(lander)
        end
        if not person.done then keep[#keep + 1] = person end
    end
    self.crew = keep
end

function RescueSystem:update(dt)
    -- A body is thrown clear, spinning, and is gone when the spin runs out.
    local live = {}
    for _, body in ipairs(self.bodies) do
        body.t = body.t + dt
        if body.t < BODY_TIME then
            local s = self.world.stage.world_size
            body.x   = (body.x + body.vx * dt) % s
            body.y   = (body.y + body.vy * dt) % s
            body.rot = body.rot + BODY_SPIN * dt
            live[#live + 1] = body
        end
    end
    self.bodies = live
    if not self.active then return end
    for _, site in ipairs(self.sites) do self:_update_site(site, dt) end
    self:_update_crew(dt)
end

local function body_speed(v)
    return math.max(-BODY_SPEED, math.min(BODY_SPEED, (v or 0) * BODY_BOOST))
end

-- A person shot at (x, y) by a round moving at (vx, vy) px/s. Also used for the
-- SaboteurSystem's agents, who fall the same way.
function RescueSystem:add_body(x, y, heading, vx, vy)
    self.bodies[#self.bodies + 1] = {
        x   = x,
        y   = y,
        rot = heading or 0,
        t   = 0,
        vx  = body_speed(vx),
        vy  = body_speed(vy),
    }
end

function RescueSystem:_shot(person, x, y, radius)
    local dx, dy = self.world:delta(person.x, person.y, x, y)
    local rr = radius + HIT_RADIUS
    return dx * dx + dy * dy < rr * rr
end

-- A projectile passed (x, y); kill the person it touches. An enemy round only
-- kills the one it was fired at (only); the player's own rounds anyone, when
-- the friendly-fire option is on. Returns true if somebody was hit so the
-- caller can consume the round.
function RescueSystem:projectile_hit(x, y, radius, from_player, vx, vy, only)
    if not self.active then return false end
    if from_player and not Config.friendly_fire_pows then return false end
    for _, site in ipairs(self.sites) do
        for i, walker in ipairs(site.walkers) do
            if (only == nil or only == walker) and self:_shot(walker, x, y, radius) then
                walker.done = true
                table.remove(site.walkers, i)
                site.timer = 0
                self.lost  = self.lost + 1
                self:add_body(walker.x, walker.y, walker.heading, vx, vy)
                self:_release_building(site)
                return true
            end
        end
    end
    for i, person in ipairs(self.crew) do
        if (only == nil or only == person) and self:_shot(person, x, y, radius) then
            person.done = true
            table.remove(self.crew, i)
            person.ent.objective = nil
            self.lost = self.lost + 1
            self:add_body(person.x, person.y, person.heading, vx, vy)
            return true
        end
    end
    return false
end

-- Whoever is aboard dies with the vehicle (0x1fbae0).
function RescueSystem:vehicle_lost(player)
    local n = self.carried[player] or 0
    if n == 0 then return end
    self.carried[player] = 0
    self.lost   = self.lost + n
    player.pows = math.max(0, (player.pows or 0) - n)
end

-- objective queries (read by Mission)

-- People still to be picked up: inside, on their way, or waiting by a wreck.
function RescueSystem:remaining_count()
    local n = #self.crew
    for _, site in ipairs(self.sites) do n = n + site.inside + #site.walkers end
    return n
end

function RescueSystem:aboard_count()
    local n = 0
    for _, count in pairs(self.carried) do n = n + count end
    return n
end

-- Everyone not lost so far; the phase is failed when this reaches 0.
function RescueSystem:alive_count()
    return self.total - self.lost
end

-- draw

function RescueSystem:_draw_person(person)
    local img = person.anim:current_image()
    if not img then return end
    local iw, ih = img:getDimensions()
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(img, person.x, person.y, person.heading * math.pi / 180, 1, 1, iw / 2, ih / 2)
end

function RescueSystem:_draw_tile(cam)
    local g = love.graphics
    -- Pads follow the pickups option: screen-upright (original) or world-rotated.
    local mrot = Config.axis_aligned_pickups and -(cam.angle or 0) or 0
    for _, site in ipairs(self.sites) do
        -- The flag fades out once the building is empty (the renderer stopped drawing it).
        local marker = site.marker
        if marker and marker.rescue_hidden and site.zone_alpha > 0.01 then
            local r = self.world.images[marker.class_idx + 1]
            if r and r.img then
                g.setColor(1, 1, 1, site.zone_alpha)
                g.draw(r.img, marker.x, marker.y, 0, 1, 1, -r.ox, -r.oy)
            end
        end
        if site.pad_alpha > 0.01 then
            local r = self.world.images[site.pad.class_idx + 1]
            if r and r.img then
                local iw, ih = r.img:getDimensions()
                g.setColor(1, 1, 1, site.pad_alpha)
                g.draw(r.img, site.px + r.ox + iw / 2, site.py + r.oy + ih / 2, mrot, 1, 1, iw / 2, ih / 2)
            end
        end
    end
    for _, site in ipairs(self.sites) do
        for _, walker in ipairs(site.walkers) do self:_draw_person(walker) end
    end
    for _, person in ipairs(self.crew) do self:_draw_person(person) end
    local clip = Animation.clip(self.body_clip)
    local body = clip and clip.frames[1]
    if body then
        local bw, bh = body:getDimensions()
        g.setColor(1, 1, 1)
        for _, b in ipairs(self.bodies) do
            g.draw(body, b.x, b.y, b.rot * math.pi / 180, 1, 1, bw / 2, bh / 2)
        end
    end
end

-- Everything here is on the ground (pads, people, bodies), so the scenes draw
-- it under a vehicle on the ground.
function RescueSystem:draw()
    if not self.active and #self.bodies == 0 then return end
    local g   = love.graphics
    local cam = self.combat.camera
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        self:_draw_tile(cam)
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

return RescueSystem
