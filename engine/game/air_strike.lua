-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local Config    = require "engine.core.config"
local Animation = require "engine.core.animation"
local Shadow    = require "engine.game.shadow"

-- Air strike, reimagined from the original (SEEK.EXE 0x1fa5d0). Calling one
-- fixes a target point target_distance ahead of the vehicle and, delay seconds
-- later, a level-dependent barrage lands on the area around it: offshore
-- artillery shells (level 1), a chopper rocket run (level 2) or a jet bomb
-- carpet (level 3). The original dealt one flat hit to everything in range;
-- here every impact damages what is around it, so targets blow up where the
-- rounds land. One strike per caller may be pending at a time.
--
-- Simulation: the whole impact schedule (time, position) is drawn from
-- world.rng when the strike is called, and impacts detonate on world.time.
-- Damage is given in the original's units (class toughness, the real health in
-- SEEK.EXE) and converted to each target's openSEEK hit points, so every level
-- keeps the manual's outcome whatever a class's score-derived hp.
--
-- Presentation (EXTRA air_strike_fx): the chopper and jet levels fly their
-- craft over the area, rockets and bombs leaving them to land exactly on the
-- scheduled impacts. Craft positions are a pure function of the strike record
-- and world.time; a strike stays listed until its craft have flown out of
-- range, but only counts as pending until its last impact.
local AirStrike = Class()

local TWO_PI = math.pi * 2

function AirStrike:init(world, combat)
    self.world   = world
    self.combat  = combat
    self.strikes = {}   -- {shooter, def, spec, x, y, angle, t0, impacts, next, warned}
end

function AirStrike:reset()
    self.strikes = {}
end

-- True until strike's last impact has landed.
function AirStrike:landing(strike)
    return strike.next <= #strike.impacts
end

-- shooter's pending strike, or nil.
function AirStrike:pending(shooter)
    for _, strike in ipairs(self.strikes) do
        if strike.shooter == shooter and self:landing(strike) then return strike end
    end
    return nil
end

-- Heading unit vectors for angle_deg (0 = north, clockwise): forward and right.
local function axes(angle_deg)
    local rad = (angle_deg - 90) * math.pi / 180
    local fx, fy = math.cos(rad), math.sin(rad)
    return fx, fy, -fy, fx
end

-- Craft c's lane (world units across the heading), its lag behind the leader
-- (seconds) and the along-heading speed that carries it through its rounds.
local function lane_of(spec, c)
    return (c - (spec.craft + 1) / 2) * spec.lane_spacing
end

local function lag_of(spec, c)
    return math.abs(c - (spec.craft + 1) / 2) * (spec.lag or 0)
end

local function craft_speed(def, spec)
    return 2 * def.radius * spec.reach / spec.window
end

-- Along-heading position of craft c, tau seconds after the strike's first
-- impact: its rounds land beneath it (bombs) or standoff ahead of it (rockets).
local function craft_along(def, spec, c, tau)
    return craft_speed(def, spec) * (tau - lag_of(spec, c)) - def.radius * spec.reach - (spec.standoff or 0)
end

-- Impact offsets {t, along, across, craft} (seconds after the first impact,
-- world units along and across the strike heading, the craft that delivers it)
-- for one level's pattern.
function AirStrike:_pattern(def, spec)
    local rng     = self.world.rng
    local radius  = def.radius
    local impacts = {}
    local function add(t, along, across, craft)
        impacts[#impacts + 1] = { t = t, along = along, across = across, craft = craft }
    end
    if spec.strike == "artillery" then
        -- Shells scattered uniformly over the disc, landing in random order.
        for _ = 1, spec.impacts do
            local r = radius * math.sqrt(rng:random())
            local a = rng:random() * TWO_PI
            add(rng:random() * spec.window, r * math.cos(a), r * math.sin(a))
        end
    else
        -- Craft fly abreast along the heading. Each lays its rounds in a line
        -- through the area, front to back in the order it reaches them; the
        -- outer craft of a jet V trail the leader by lag seconds.
        local rounds = spec.rounds
        for c = 1, spec.craft do
            local lane = lane_of(spec, c)
            local lag  = lag_of(spec, c)
            for i = 1, rounds do
                local p     = (rounds > 1) and (i - 1) / (rounds - 1) or 0.5
                local along = radius * spec.reach * (2 * p - 1)
                local t     = lag + p * spec.window
                add(t,
                    along + (rng:random() * 2 - 1) * spec.jitter,
                    lane + (rng:random() * 2 - 1) * spec.jitter,
                    c)
            end
        end
    end
    table.sort(impacts, function(a, b) return a.t < b.t end)
    return impacts
end

-- Call a strike for shooter at level_idx, aimed along angle_deg from (x, y).
-- Returns false when that shooter already has one pending (no ammo is spent).
function AirStrike:call(x, y, angle_deg, def, level_idx, shooter)
    if self:pending(shooter) then return false end
    local spec = def.levels[level_idx] or def.levels[1]
    local fx, fy = axes(angle_deg)
    local size   = self.world.stage.world_size
    local strike = {
        shooter = shooter,
        def     = def,
        spec    = spec,
        x       = (x + fx * def.target_distance) % size,
        y       = (y + fy * def.target_distance) % size,
        angle   = angle_deg,
        t0      = self.world.time,
        next    = 1,
        warned  = false,
    }
    strike.impacts = self:_pattern(def, spec)
    -- Listed until the last craft has flown approach past the area.
    strike.until_t = strike.t0 + def.delay + strike.impacts[#strike.impacts].t
    if spec.craft then
        local out = 0
        for c = 1, spec.craft do
            local tau = lag_of(spec, c)
                + (spec.approach + def.radius * spec.reach + (spec.standoff or 0)) / craft_speed(def, spec)
            out = math.max(out, tau)
        end
        strike.until_t = math.max(strike.until_t, strike.t0 + def.delay + out)
    end
    self.strikes[#self.strikes + 1] = strike
    self.world:say("voice.air_strike_call")
    return true
end

-- Seconds until strike's first impact (negative once it is landing).
function AirStrike:time_to_impact(strike)
    return strike.t0 + strike.def.delay - self.world.time
end

-- Damage in original toughness units, converted to e's current hp pool (the
-- turret while it stands). A class with toughness 0 dies to any hit, as in
-- the original.
function AirStrike:_hp_damage(e, amount)
    local cls, max_hp
    if e.turret_alive then
        cls, max_hp = e.turret_class, e.turret_max_hp
    else
        cls, max_hp = self.world.stage.classes[e.class_idx + 1], e.max_hp
    end
    local toughness = cls and cls.toughness or 0
    if toughness <= 0 then return max_hp end
    return amount * max_hp / toughness
end

function AirStrike:_detonate(strike, impact)
    local spec = strike.spec
    local fx, fy, rx, ry = axes(strike.angle)
    local size = self.world.stage.world_size
    local x    = (strike.x + fx * impact.along + rx * impact.across) % size
    local y    = (strike.y + fy * impact.along + ry * impact.across) % size
    self.combat:add_effect(spec.explosion, x, y, { scale = spec.explosion_scale or 1 })
    if spec.debris then self.world:spawn_debris(x, y, spec.debris, 1.2) end
    local r2 = spec.impact_radius ^ 2
    for _, e in ipairs(self.world.hittable) do
        if e:is_alive() and not e.hide_shielded then
            local dx, dy = self.world:delta(e.x, e.y, x, y)
            if dx * dx + dy * dy < r2 then
                e:on_hit()
                local killed = e:take_damage(self:_hp_damage(e, spec.damage), dx, dy)
                if killed then self.combat:_credit_kill(strike.shooter, e, killed) end
            end
        end
    end
end

function AirStrike:update()
    if #self.strikes == 0 then return end
    local live = {}
    for _, strike in ipairs(self.strikes) do
        local left = self:time_to_impact(strike)
        if not strike.warned and left <= strike.def.incoming and self:landing(strike) then
            strike.warned = true
            self.world:say("voice.air_strike_incoming")
        end
        while self:landing(strike) and strike.impacts[strike.next].t <= -left do
            self:_detonate(strike, strike.impacts[strike.next])
            strike.next = strike.next + 1
        end
        if self:landing(strike) or self.world.time < strike.until_t then live[#live + 1] = strike end
    end
    self.strikes = live
end

-- presentation

-- World position of a point along / across strike's heading from its target.
local function strike_point(strike, along, across)
    local fx, fy, rx, ry = axes(strike.angle)
    return strike.x + fx * along + rx * across, strike.y + fy * along + ry * across
end

-- The night variant of clip name when the stage is at night and one exists.
function AirStrike:_clip(name)
    if self.world:is_night() and Animation.clip(name .. "n") then name = name .. "n" end
    local clip = Animation.clip(name)
    return clip and not clip:is_empty() and clip or nil
end

-- Craft art for strike: a jet image, or a chopper body (a skin other than the
-- caller's) plus its rotor clip. A pack without the jet art flies choppers.
function AirStrike:_craft_art(strike)
    if strike.spec.strike == "jets" then
        local jet = self:_clip(strike.spec.craft_clip)
        if jet then return jet.frames[1], nil end
    end
    local skin = ((strike.shooter and strike.shooter.chopper_skin or 1) % 3) + 1
    local body = self:_clip("choppit" .. skin)
    return body and body.frames[1], self:_clip("bladep")
end

-- Calls fn(x, y, craft) for every craft of strike within approach of the area.
function AirStrike:_each_craft(strike, fn)
    local def, spec = strike.def, strike.spec
    local tau = self.world.time - strike.t0 - def.delay
    for c = 1, spec.craft do
        local along = craft_along(def, spec, c, tau)
        if math.abs(along) <= spec.approach then
            local x, y = strike_point(strike, along, lane_of(spec, c))
            fn(x, y, c)
        end
    end
end

-- Calls fn(strike) inside the camera transform, once per world tile, for every
-- strike with craft. Nothing when EXTRA (air_strike_fx) is off.
function AirStrike:_draw_world(fn)
    if not Config.air_strike_fx or #self.strikes == 0 then return end
    local g   = love.graphics
    local cam = self.combat.camera
    g.push()
    cam:apply()
    for _, t in ipairs(cam:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        for _, strike in ipairs(self.strikes) do
            if strike.spec.craft then fn(strike) end
        end
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

-- EXTRA (air_strike_fx): craft ground shadows, cast altitude world units toward
-- the fixed sun like the helicopters'. soft adds the rotor disc.
function AirStrike:draw_shadows(soft)
    if not self.world:shadows_enabled() then return end
    self:_draw_world(function(strike)
        local body, rotor = self:_craft_art(strike)
        if not body then return end
        local spec   = strike.spec
        local rot    = strike.angle * math.pi / 180
        local offset = spec.altitude
        local bw, bh = body:getDimensions()
        self:_each_craft(strike, function(x, y)
            local sx, sy = x + Shadow.DIR_X * offset, y + Shadow.DIR_Y * offset
            Shadow.draw(body, sx, sy, rot, 1, 1, bw / 2, bh / 2, Shadow.ALPHA)
            if soft and rotor then
                local img    = rotor.frames[1]
                local fx, fy = axes(strike.angle)
                local rw, rh = img:getDimensions()
                Shadow.draw(img, sx + fx * spec.rotor_offset, sy + fy * spec.rotor_offset, 0, 1, 1,
                    rw / 2, rh / 2, Shadow.ROTOR_ALPHA)
            end
        end)
    end)
end

-- Rockets (chopper level) and bombs (jet level) on their way to the impacts not
-- yet landed: each leaves its craft lead seconds before its impact and ends
-- exactly on it. A bomb shrinks as it falls away from the camera.
function AirStrike:_draw_munitions(strike)
    local def, spec = strike.def, strike.spec
    local clip = self:_clip(spec.munition_clip)
    if not clip then return end
    local img    = clip.frames[1]
    local iw, ih = img:getDimensions()
    local lead   = spec.munition_time
    local rot    = strike.angle * math.pi / 180
    local tau    = self.world.time - strike.t0 - def.delay
    local g      = love.graphics
    for i = strike.next, #strike.impacts do
        local impact = strike.impacts[i]
        local p      = (tau - (impact.t - lead)) / lead
        if p >= 0 and p < 1 then
            local from   = craft_along(def, spec, impact.craft, impact.t - lead)
            local x0, y0 = strike_point(strike, from, lane_of(spec, impact.craft))
            local x1, y1 = strike_point(strike, impact.along, impact.across)
            local scale  = 1 - (1 - (spec.munition_min_scale or 1)) * p * p
            g.setColor(1, 1, 1)
            g.draw(img, x0 + (x1 - x0) * p, y0 + (y1 - y0) * p, rot, scale, scale, iw / 2, ih / 2)
        end
    end
end

-- EXTRA (air_strike_fx): the craft and their rounds, drawn over the enemy
-- helicopters. Choppers spin a single rotor frame group, like the player's at
-- full forward pitch.
function AirStrike:draw()
    self:_draw_world(function(strike)
        self:_draw_munitions(strike)
        local body, rotor = self:_craft_art(strike)
        if not body then return end
        local spec   = strike.spec
        local rot    = strike.angle * math.pi / 180
        local bw, bh = body:getDimensions()
        local g      = love.graphics
        local blade  = rotor and rotor.frames[math.floor(self.world.time * spec.rotor_fps) % 8 + 1]
        local fx, fy = axes(strike.angle)
        g.setColor(1, 1, 1)
        self:_each_craft(strike, function(x, y)
            g.draw(body, x, y, rot, 1, 1, bw / 2, bh / 2)
            if blade then
                local rw, rh = blade:getDimensions()
                g.draw(blade, x + fx * spec.rotor_offset, y + fy * spec.rotor_offset, rot, 1, 1,
                    rw / 2, rh / 2)
            end
        end)
    end)
end

return AirStrike
