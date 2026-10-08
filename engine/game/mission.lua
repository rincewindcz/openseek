-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local json  = require "lib.json"
local Log   = require "engine.core.log"

local Mission = Class()

local defs = {}   -- stage_name -> mission def, loaded once

-- Half the side of the box around the home pad a vehicle has to be down in
-- (0x20e2cd). Two vehicles do not fit in it, so a team gets a wider one.
local HOME_RADIUS      = 24
local HOME_RADIUS_TEAM = 48

-- Stage class behaviour of the building held back until only it is left of
-- the targets (0x1f640c, 0x1fe7ab).
local COMMANDER_CLASS = 2

local FAIL_ALLIES = { "ALLIES EXTERMINATED", "PHASE FAILED" }
local FAIL_AGENT  = { "OBJECTIVE IMPOSSIBLE", "PHASE FAILED" }
local NOTICE_COMMANDER = "DESTROY THE COMMANDERS BUILDING"

function Mission.load(path)
    local raw = love.filesystem.read(path)
    if not raw then Log.warn("mission", "missing %s", path) end
    defs = raw and json.decode(raw) or {}
end

-- The objectives a stage's own data asks for, as the original counts them at
-- load: every is_target entity destroyed (0x290e58), everybody on the stage
-- picked up (0x290e4a) and every agent back aboard (0x290e76).
local function objectives_from_stage(world)
    local def = { objectives = {} }
    if #world.targets > 0 then def.objectives[#def.objectives + 1] = { type = "destroy_targets" } end
    if world.rescue and world.rescue.total > 0 then
        def.objectives[#def.objectives + 1] = { type = "rescue_people" }
    end
    if world.saboteur and #world.saboteur.sites > 0 then
        def.objectives[#def.objectives + 1] = { type = "sabotage" }
    end
    return #def.objectives > 0 and def or nil
end

-- Build a mission for the named stage: an explicit missions.json def if one
-- exists, otherwise what the stage's data asks for. nil when neither yields an
-- objective. players is the list contributing to the goals: one entry in
-- single player, both in co-op, so every mode runs the same rules. The rescue
-- and saboteur systems must be reset for the stage first.
function Mission.for_stage(world, players, stage_name)
    local def = defs[stage_name]
    if not (def and def.objectives) then
        def = objectives_from_stage(world)
    end
    if not def then return nil end
    return Mission:new(world, players, def)
end

-- Vehicle a stage forces ("tank" locks the equip screen to the tank, like the
-- original's tank-only phases), or nil when the player may choose.
function Mission.required_vehicle(stage_name)
    local def = defs[stage_name]
    return def and def.vehicle or nil
end

-- True if entity e satisfies a spec's filters: asset (.bin) filename, kind_name,
-- and a minimum sprite size (largest dimension), any of which may be omitted.
local function entity_matches(world, e, spec)
    if spec.target then
        local f = world:asset_file(e.class_idx)
        if not f or f:lower() ~= spec.target:lower() then return false end
    end
    if spec.kind then
        local cls = world.stage.classes[e.class_idx + 1]
        if not cls or cls.kind_name ~= spec.kind then return false end
    end
    if spec.min_size then
        local r = world.images[e.class_idx + 1]
        local w, h = 0, 0
        if r and r.img then w, h = r.img:getDimensions() end
        if math.max(w, h) < spec.min_size then return false end
    end
    return true
end

function Mission:init(world, players, def)
    self.world       = world
    self.players     = players
    self.player      = players[1]
    self.def         = def
    self.briefing    = def.briefing
    self.home_radius = def.home_radius or (#players > 1 and HOME_RADIUS_TEAM or HOME_RADIUS)
    self.age         = 0          -- seconds since start (briefing shows while young)
    -- active -> return_to_base -> won. "failed" is every vehicle down, which a
    -- respawn lifts again; "phase_failed" is an objective lost for good
    -- (fail_lines says which) and ends the phase.
    self.state       = "active"
    self.fail_lines  = nil
    self.notice      = nil        -- standing on-screen order (the commander's building)
    self.objectives  = {}
    for _, spec in ipairs(def.objectives or {}) do
        self.objectives[#self.objectives + 1] = self:_make_objective(spec)
    end

    -- The phase flagged with a special end (0x2909e8 bit 0) keeps its commander
    -- building out of the world until every other target is gone, and is over
    -- the moment the building falls: no flight home.
    local flags = world.stage.objectives
    self.special_end = flags and flags.special_end or false
    self.commanders  = {}
    if self.special_end then
        for _, e in ipairs(world.targets) do
            local cls = world.stage.classes[e.class_idx + 1]
            if cls.kind_name == "structure" and cls.behaviour == COMMANDER_CLASS then
                e.dormant, e.protected = true, true
                self.commanders[#self.commanders + 1] = e
            end
        end
    end

    -- Return-to-base point: an explicit pad sprite for stages whose friendly base
    -- is not the auto-detected basecirc.bin / h.bin, otherwise the world's home pad.
    if def.home_base_asset then
        local e = self:_collect({ target = def.home_base_asset })[1]
        if e then self.home_x, self.home_y = e.x, e.y end
    end
    if not self.home_x then self.home_x, self.home_y = world:home_base() end

    local labels = {}
    for i, o in ipairs(self.objectives) do labels[i] = self:objective_label(o) end
    Log.info("mission", "%s: %s", world.stage_name, #labels > 0 and table.concat(labels, "; ") or "no objectives")
end

function Mission:_collect(spec)
    local list = {}
    for _, e in ipairs(self.world.entities) do
        if entity_matches(self.world, e, spec) then list[#list + 1] = e end
    end
    return list
end

function Mission:_make_objective(spec)
    local o = { spec = spec, type = spec.type, done = false, progress = 0 }
    if spec.type == "destroy" then
        o.matching = self:_collect(spec)
        o.counted  = {}
        o.target   = (spec.count == nil or spec.count == "all")
            and #o.matching or math.min(spec.count, #o.matching)
    elseif spec.type == "rescue" then
        o.zones     = self:_collect(spec)
        o.collected = {}
        o.radius    = spec.radius or 40
        o.target    = spec.count or #o.zones
    elseif spec.type == "sabotage" then
        -- Driven by the SaboteurSystem, which owns the drop pads and their buildings.
        o.target = self.world.saboteur and #self.world.saboteur.sites or 0
    elseif spec.type == "destroy_targets" then
        -- Every is_target entity collected by World:load (the decoded fallback,
        -- and stages whose target asset is shared with a non-target class).
        o.list   = self.world.targets
        o.target = #o.list
    elseif spec.type == "rescue_people" then
        -- Driven by the RescueSystem. The stage says whether the rescue is the
        -- phase's objective (0x2909e8 bit 1) or a chance taken on the way.
        local flags = self.world.stage.objectives
        o.optional = spec.optional
        if o.optional == nil then o.optional = not (flags and flags.rescue) end
        o.target = self.world.rescue and self.world.rescue.total or 0
    end
    if o.optional == nil then o.optional = spec.optional or false end
    -- An objective with nothing to act on is satisfied so it can never block a win.
    local known = o.type == "destroy" or o.type == "rescue" or o.type == "sabotage"
        or o.type == "destroy_targets" or o.type == "rescue_people"
    if not known or o.target == 0 then
        o.done = true
    end
    return o
end

-- per-frame progress

-- Co-op fail only when every player is down (a lone survivor can still finish).
function Mission:_all_dead()
    if #self.players == 0 then return false end
    for _, p in ipairs(self.players) do
        if not p.death then return false end
    end
    return true
end

function Mission:_fail_phase(lines)
    if self.state == "phase_failed" or self.state == "won" then return end
    self.state      = "phase_failed"
    self.fail_lines = lines
    Log.info("mission", "%s", table.concat(lines, " - "))
end

-- The commander building comes up, with its standing order, once it is the
-- only target left.
function Mission:_update_commanders()
    if #self.commanders == 0 or self.notice then return end
    local left = 0
    for _, e in ipairs(self.world.targets) do
        if e:is_alive() then left = left + 1 end
    end
    if left > #self.commanders then return end
    for _, e in ipairs(self.commanders) do e.dormant, e.protected = nil, nil end
    self.notice = NOTICE_COMMANDER
end

function Mission:update(dt)
    if self.state == "won" or self.state == "failed" or self.state == "phase_failed" then return end
    self.age = self.age + dt
    if self:_all_dead() then self.state = "failed"; return end
    -- An agent killed leaves its pad open for good (0x1fe911).
    if self.world.saboteur and self.world.saboteur:mission_failed() then
        self:_fail_phase(FAIL_AGENT)
        return
    end
    self:_update_commanders()

    -- Optional objectives (e.g. a secondary POW rescue) are tracked but never block
    -- the return-to-base / win once every required objective is done.
    local all_done, cleared = true, false
    for _, o in ipairs(self.objectives) do
        if not o.done then
            self:_update_objective(o)
            if o.done then
                cleared = true
                Log.info("mission", "objective done: %s", self:objective_label(o))
            end
            if not o.done and not o.optional then all_done = false end
        end
    end
    if self.state == "phase_failed" then return end
    -- An objective finishing is called out, except the last one: that rolls
    -- straight into the return-to-base line below.
    if cleared and not all_done then self.world:say("voice.objective_cleared") end

    if all_done then
        if self.special_end then
            self.state  = "won"
            self.notice = nil
            self.world:say("voice.mission_complete")
            return
        end
        if self.state == "active" then
            self.state = "return_to_base"
            self.world:say("voice.return_to_base")
            Log.info("mission", "objectives done, return to base")
        end
        if self:_at_home_base() then
            self.state = "won"
            self.world:say("voice.mission_complete")
        end
    end
end

-- A vehicle went down. Whoever was aboard dies with it, which fails the phase
-- when nobody is left to bring home. Call before deciding what the crash means.
function Mission:vehicle_lost(p)
    if self.state == "won" or self.state == "phase_failed" then return end
    if not self.world.rescue then return end
    self.world.rescue:vehicle_lost(p)
    for _, o in ipairs(self.objectives) do
        if o.type == "rescue_people" then self:_update_rescue_people(o) end
    end
end

function Mission:_update_objective(o)
    if     o.type == "destroy"         then self:_update_destroy(o)
    elseif o.type == "rescue"          then self:_update_rescue(o)
    elseif o.type == "sabotage"        then self:_update_sabotage(o)
    elseif o.type == "destroy_targets" then self:_update_destroy_targets(o)
    elseif o.type == "rescue_people"   then self:_update_rescue_people(o) end
end

function Mission:_update_destroy_targets(o)
    local rem = 0
    for _, e in ipairs(o.list) do
        if e:is_alive() then rem = rem + 1 end
    end
    o.progress = o.target - rem
    if rem == 0 then o.done = true end
end

-- Done when nobody is left to pick up; those lost on the way stop counting
-- (0x1fe901). A rescue that is the phase's objective fails once every one of
-- them is dead (0x1fe680).
function Mission:_update_rescue_people(o)
    local r = self.world.rescue
    if not r then o.done = true; return end
    o.progress = r:aboard_count()
    o.target   = r:alive_count()
    if r:remaining_count() == 0 then o.done = true end
    if o.target == 0 and not o.optional then self:_fail_phase(FAIL_ALLIES) end
end

function Mission:_update_destroy(o)
    for _, e in ipairs(o.matching) do
        if not o.counted[e.id] and not e:is_alive() then
            o.counted[e.id] = true
            o.progress = o.progress + 1
        end
    end
    if o.progress >= o.target then o.done = true end
end

function Mission:_update_rescue(o)
    for _, p in ipairs(self.players) do
        if p:is_stationary() then
            for _, z in ipairs(o.zones) do
                if not o.collected[z.id] then
                    local dx, dy = self.world:delta(p.x, p.y, z.x, z.y)
                    if dx * dx + dy * dy <= o.radius * o.radius then
                        o.collected[z.id] = true
                        o.progress = o.progress + 1
                        p.pows = (p.pows or 0) + 1
                        z.objective = nil   -- off the radar
                    end
                end
            end
        end
    end
    if o.progress >= o.target then o.done = true end
end

-- Progress mirrors the SaboteurSystem: a pad clears once its agent is back
-- aboard; the objective is done when every pad is cleared.
function Mission:_update_sabotage(o)
    local s = self.world.saboteur
    if not s then o.done = true; return end
    o.progress = s:cleared_count()
    o.target   = #s.sites
    if s:all_cleared() then o.done = true end
end

-- A player down on the home pad: on the ground inside its box. A stage without
-- a pad counts everyone home.
function Mission:player_home(p)
    if not self.home_x then return true end
    if p:is_airborne() then return false end
    local dx, dy = self.world:delta(p.x, p.y, self.home_x, self.home_y)
    return math.abs(dx) < self.home_radius and math.abs(dy) < self.home_radius
end

-- Every player still in the phase has to be parked on the home pad, so a co-op
-- phase ends when the whole team is home rather than when the first one lands.
-- A wrecked player (waiting to respawn, or out of vehicles) is not waited for.
function Mission:_at_home_base()
    if not self.home_x then return true end   -- no pad on this stage: win on objectives
    local home = 0
    for _, p in ipairs(self.players) do
        if not p.death then
            if not self:player_home(p) then return false end
            home = home + 1
        end
    end
    return home > 0
end

-- presentation

function Mission:objective_label(o)
    local s = o.spec
    if o.type == "destroy" then
        return string.format("%s  %d/%d",
            s.label or ("Destroy " .. (s.target or s.kind or "targets")), o.progress, o.target)
    elseif o.type == "rescue" then
        return string.format("%s  %d/%d", s.label or "Rescue people", o.progress, o.target)
    elseif o.type == "sabotage" then
        return string.format("%s  %d/%d", s.label or "RECOVER AGENTS", o.progress, o.target)
    elseif o.type == "destroy_targets" then
        return string.format("%s  %d/%d", s.label or "DESTROY TARGETS", o.progress, o.target)
    elseif o.type == "rescue_people" then
        return string.format("%s  %d/%d", s.label or "RESCUE", o.progress, o.target)
    end
    return s.label or o.type
end

-- Short shared-state line for the co-op banner: the first unfinished objective,
-- or the return-to-base prompt once they are all done.
function Mission:status_line()
    if self.state == "won"          then return "MISSION COMPLETE" end
    if self.state == "failed"       then return "MISSION FAILED" end
    if self.state == "phase_failed" then return table.concat(self.fail_lines, " - ") end
    if self.briefing and self.age < 5 then return self.briefing end
    -- Required objectives drive the banner; optional ones never hold up the prompt.
    for _, o in ipairs(self.objectives) do
        if not o.done and not o.optional then return self:objective_label(o) end
    end
    return "RETURN TO BASE"
end

return Mission
