-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local Animation = require "engine.core.animation"
local Config    = require "engine.core.config"
local Mathx     = require "engine.core.mathx"

-- Agent drop-off, on the original's rules (building update 0x1fefb0, person
-- update 0x203c90, one tick = 1/70 s). Every drop pad (World.saboteur_pads) is
-- tied to one building. A vehicle on the ground at the pad sends an agent from
-- the vehicle into the building (under its roof: the scenes draw the people
-- below the solid objects), and the pad goes away. The agent comes back
-- out after a moment, or, on a stage whose data asks for it, only once every
-- building has its agent inside. The pad returns, the agent walks to it and
-- waits there to be picked up by a vehicle landing on it again.
--
-- The buildings cannot be shot. One an agent has left loses toughness by the
-- tick and blows up when that runs out; a class of behaviour 5 (the downed
-- helicopters) never does. The phase is done when every agent is back aboard,
-- and failed the moment one of them is killed.
local SaboteurSystem = Class()

local TICK          = 1 / 70
local WALK_SPEED    = 35          -- px/s: half a pixel a tick
local LAND_RADIUS   = 24          -- a vehicle on the ground this close to the pad counts as landed on it
local ENTER_RADIUS  = 4           -- distance to the building's middle at which the agent is inside
local PAD_RADIUS    = 20          -- distance from the pad at which the agent stops to wait
local BOARD_RADIUS  = 10          -- distance to the vehicle at which the agent is aboard
local INSIDE_TIME   = 60 * TICK   -- the agent's stay inside
local BURN_RATE     = 2 * 70      -- toughness a building loses per second once its agent is out
local PAD_FADE      = 0.2         -- seconds for the pad to fade out / in
local HIT_RADIUS    = 6           -- an agent's collision radius when shot

-- Stage global 5 (0x290e7c) at this value holds every agent inside until all
-- are in (0x1ff0fb); the original then waits for a count of 3, the number of
-- pads on the one stage that uses it.
local HOLD_ALL       = 65535
local NO_BLAST_CLASS = 5

function SaboteurSystem:init(world, combat)
    self.world     = world
    self.combat    = combat
    self.sites     = {}
    self.active    = false
    self.failed    = false   -- an agent was killed
    world.saboteur = self
end

function SaboteurSystem:reset()
    self.sites    = {}
    self.failed   = false
    self.hold_all = (self.world.stage.globals or {})[5] == HOLD_ALL
    self.clip     = self.world:walker_clip()
    for _, pad in ipairs(self.world.saboteur_pads) do
        local b   = pad.building
        local cls = self.world.stage.classes[b.class_idx + 1]
        b.protected = true
        b.objective = true               -- white dot on the radar
        pad.ent.sabotage_hidden = true   -- the system draws this pad now, not the renderer
        self.sites[#self.sites + 1] = {
            pad       = pad.ent,
            building  = b,
            blasts    = cls.behaviour ~= NO_BLAST_CLASS,
            px        = pad.ent.x,
            py        = pad.ent.y,
            agent     = nil,     -- the walking agent once dispatched
            phase     = "idle",  -- idle -> to_building -> inside -> to_pad -> waiting -> aboard
            inside_t  = 0,
            burning   = false,   -- the building is on its way to blowing up
            pad_alpha = 1,
        }
    end
    self.active = #self.sites > 0
end

function SaboteurSystem:clear()
    self.sites  = {}
    self.active = false
    self.failed = false
end

function SaboteurSystem:_lander(site)
    for _, p in ipairs(self.combat.players or {}) do
        if p and not p.death and not p:is_airborne() then
            local dx, dy = self.world:delta(p.x, p.y, site.px, site.py)
            if dx * dx + dy * dy <= LAND_RADIUS * LAND_RADIUS then return p end
        end
    end
end

-- Step the agent toward (gx, gy); true once within reach.
function SaboteurSystem:_walk(agent, gx, gy, reach, dt)
    local dx, dy = self.world:delta(gx, gy, agent.x, agent.y)
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= reach then return true end
    agent.anim:update(dt)
    agent.heading = Mathx.heading_deg(dx, dy)
    local step = WALK_SPEED * dt * Config.speed_scale
    local s    = self.world.stage.world_size
    agent.x = (agent.x + dx / d * step) % s
    agent.y = (agent.y + dy / d * step) % s
    return false
end

-- An agent stepping into the open at (x, y), which the guns nearby notice.
function SaboteurSystem:_agent(x, y)
    local agent = { x = x, y = y, heading = 0, anim = Animation.new(self.clip), on_foot = true }
    self.combat:person_out(agent)
    return agent
end

function SaboteurSystem:_all_inside()
    for _, site in ipairs(self.sites) do
        if site.phase ~= "inside" then return false end
    end
    return true
end

function SaboteurSystem:_blow_building(site)
    local b = site.building
    site.burning = false
    b.protected  = false
    if b:is_alive() then
        local dx, dy = self.world:delta(b.x, b.y, site.px, site.py)
        b:take_damage(b.hp + 1, dx, dy)
    end
end

function SaboteurSystem:_update_site(site, dt, release)
    local lander = self:_lander(site)
    local agent  = site.agent
    if site.phase == "idle" then
        if lander and site.building:is_alive() then
            site.agent = self:_agent(lander.x, lander.y)
            site.phase = "to_building"
        end
    elseif site.phase == "to_building" then
        if self:_walk(agent, site.building.x, site.building.y, ENTER_RADIUS, dt) then
            agent.done    = true   -- out of sight: the guns let go
            site.phase    = "inside"
            site.inside_t = INSIDE_TIME
        end
    elseif site.phase == "inside" then
        site.inside_t = math.max(0, site.inside_t - dt)
        if release or (not self.hold_all and site.inside_t <= 0) then
            site.agent   = self:_agent(site.building.x, site.building.y)
            site.phase   = "to_pad"
            site.burning = site.blasts
        end
    elseif site.phase == "to_pad" then
        if self:_walk(agent, site.px, site.py, PAD_RADIUS, dt) then site.phase = "waiting" end
    elseif site.phase == "waiting" then
        if lander and self:_walk(agent, lander.x, lander.y, BOARD_RADIUS, dt) then
            agent.done = true
            site.agent = nil
            site.phase = "aboard"
            site.building.objective = nil   -- off the radar
        end
    end

    if site.burning then
        local b = site.building
        b.hp = b.hp - BURN_RATE * dt
        if b.hp < 1 then self:_blow_building(site) end
    end

    -- The pad is gone while the agent is on the way in or inside, and for good
    -- once the agent is back aboard.
    local shown = site.phase == "idle" or site.phase == "to_pad" or site.phase == "waiting"
    local fade  = dt / PAD_FADE
    site.pad_alpha = shown and math.min(1, site.pad_alpha + fade) or math.max(0, site.pad_alpha - fade)
end

function SaboteurSystem:update(dt)
    if not self.active then return end
    local release = self.hold_all and self:_all_inside()
    for _, site in ipairs(self.sites) do self:_update_site(site, dt, release) end
end

-- A projectile passed (x, y); cut down the agent it touches, which fails the
-- phase. An enemy round only kills the one it was fired at (only); the
-- player's own rounds any, when the friendly-fire option is on. Returns true
-- on a hit.
function SaboteurSystem:projectile_hit(x, y, radius, from_player, vx, vy, only)
    if not self.active then return false end
    if from_player and not Config.friendly_fire_pows then return false end
    for _, site in ipairs(self.sites) do
        local agent = site.agent
        if agent and site.phase ~= "inside" and (only == nil or only == agent) then
            local dx, dy = self.world:delta(agent.x, agent.y, x, y)
            local rr = radius + HIT_RADIUS
            if dx * dx + dy * dy < rr * rr then
                agent.done  = true
                site.agent  = nil
                site.phase  = "lost"
                self.failed = true
                if self.world.rescue then
                    self.world.rescue:add_body(agent.x, agent.y, agent.heading, vx, vy)
                end
                return true
            end
        end
    end
    return false
end

-- objective queries (read by Mission)

function SaboteurSystem:cleared_count()
    local n = 0
    for _, site in ipairs(self.sites) do
        if site.phase == "aboard" then n = n + 1 end
    end
    return n
end

function SaboteurSystem:all_cleared()
    return self:cleared_count() == #self.sites
end

function SaboteurSystem:mission_failed()
    return self.failed
end

-- draw

-- Run fn(self) once per wrapped tile inside the camera transform.
function SaboteurSystem:_draw_tiles(fn)
    local g   = love.graphics
    local cam = self.combat.camera
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        fn(self, cam)
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

-- Ground layer: drop pads and walking agents, under a vehicle on the ground.
function SaboteurSystem:draw_ground()
    if not self.active then return end
    self:_draw_tiles(self._draw_ground_tile)
end

function SaboteurSystem:_draw_ground_tile(cam)
    local g = love.graphics
    -- Pads follow the pickups option: screen-upright (original) or world-rotated.
    local mrot = Config.axis_aligned_pickups and -(cam.angle or 0) or 0
    for _, site in ipairs(self.sites) do
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
        local agent = site.agent
        if agent and site.phase ~= "inside" then
            local img = agent.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1)
                g.draw(img, agent.x, agent.y, agent.heading * math.pi / 180, 1, 1, iw / 2, ih / 2)
            end
        end
    end
end

return SaboteurSystem
