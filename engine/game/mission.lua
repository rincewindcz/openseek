-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local json  = require "lib.json"
local Log   = require "engine.core.log"

local Mission = Class()

local defs = {}   -- stage_name -> mission def, loaded once

-- Objective types. destroy / rescue are the data/missions.json forms (by
-- sprite, kind or count); destroy_targets, rescue_people and sabotage follow
-- from a stage's content; a player-made map adds destroy by its own pick,
-- reach, survive, collect, protect and air (engine/game/map_compiler.lua).
Mission.TYPES = {
    destroy = true, rescue = true, sabotage = true, destroy_targets = true, rescue_people = true,
    reach = true, survive = true, collect = true, protect = true, air = true,
}

-- Half the side of the box around the home pad a vehicle has to be down in
-- (0x20e2cd). Two vehicles do not fit in it, so a team gets a wider one.
local HOME_RADIUS      = 24
local HOME_RADIUS_TEAM = 48

-- Stage class behaviour of the building held back until only it is left of
-- the targets (0x1f640c, 0x1fe7ab).
local COMMANDER_CLASS = 2

-- World px around a place a "reach" objective is met within, when it names none.
local REACH_RADIUS = 48

local FAIL_ALLIES = { "ALLIES EXTERMINATED", "PHASE FAILED" }
local FAIL_AGENT  = { "OBJECTIVE IMPOSSIBLE", "PHASE FAILED" }
local FAIL_GUARD  = { "OBJECTIVE LOST", "PHASE FAILED" }
local FAIL_TIME   = { "OUT OF TIME", "PHASE FAILED" }
local FAIL_EVENT  = { "MISSION ABORTED", "PHASE FAILED" }
local NOTICE_COMMANDER = "DESTROY THE COMMANDERS BUILDING"

-- The objectives a stage's content asks for, in the original's order.
local DERIVED = { "destroy_targets", "rescue_people", "sabotage" }

function Mission.load(path)
    local raw = love.filesystem.read(path)
    if not raw then Log.warn("mission", "missing %s", path) end
    defs = raw and json.decode(raw) or {}
end

-- The objectives a stage's own data asks for, as the original counts them at
-- load: every is_target entity destroyed (0x290e58), everybody on the stage
-- picked up (0x290e4a) and every agent back aboard (0x290e76).
-- A map (stage.mission, engine/game/map_compiler.lua) lists objectives of its
-- own among them, in the order it wants them, and words them all; one its
-- content asks for and it does not list follows the listed ones. An objective
-- of a map may carry events (spec.on_open, spec.on_done), fired as it comes
-- up or is done, and the map's own events (own.events) fire when what sets
-- them off happens (Mission:_update_events). What an event does is
-- Mission:_fire's.
local function objectives_from_stage(world)
    local own = world.stage.mission or {}
    local def = { objectives = {}, no_return = own.no_return, ordered = own.ordered,
                  time_limit = own.time_limit, events = own.events, announce = world.stage.mission ~= nil }
    local asked = {
        destroy_targets = #world.targets > 0,
        rescue_people   = world.rescue ~= nil and world.rescue.total > 0,
        sabotage        = world.saboteur ~= nil and #world.saboteur.sites > 0,
    }
    for _, spec in ipairs(own.objectives or {}) do
        if asked[spec.type] == nil then
            def.objectives[#def.objectives + 1] = spec
        elseif asked[spec.type] then
            def.objectives[#def.objectives + 1] = spec
            asked[spec.type] = false
        end
    end
    for _, kind in ipairs(DERIVED) do
        if asked[kind] then def.objectives[#def.objectives + 1] = { type = kind } end
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

-- The data/missions.json entry of a stage, or nil.
function Mission.def(stage_name)
    return defs[stage_name]
end

-- True if entity e satisfies a spec's filters: asset (.bin) filename, kind_name,
-- one of several kind names (kinds: what of them can be destroyed, mines and
-- the home base aside) and a minimum sprite size (largest dimension), any of which may be
-- omitted.
local function entity_matches(world, e, spec)
    if spec.kinds then
        local cls   = world.stage.classes[e.class_idx + 1]
        local found = false
        for _, kind in ipairs(spec.kinds) do
            if cls and cls.kind_name == kind then found = true end
        end
        if not found or e.max_hp <= 0 or e.mine or e.base_building then return false end
    end
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
    self.messages    = {}         -- what a map's events said, in order (the scene shows each once)
    self.time_limit  = def.time_limit   -- a map's events may move it
    self.objectives  = {}
    self.guards      = {}         -- "protect" objectives: nothing to do, something to lose
    for _, spec in ipairs(def.objectives or {}) do
        local o = self:_make_objective(spec)
        self.objectives[#self.objectives + 1] = o
        if o.type == "protect" and o.target > 0 then self.guards[#self.guards + 1] = o end
        -- An objective with nothing to do never comes up: its events hold nothing.
        if not o.done then
            self:_prepare(spec.on_open)
            self:_prepare(spec.on_done)
        end
    end
    self.events = {}              -- { spec, next_at, left, targets }: a map's events still to fire
    for _, spec in ipairs(def.events or {}) do
        self.events[#self.events + 1] = { spec = spec, next_at = spec.at, left = spec.times or 1,
                                          targets = spec.targets and self:_placed(spec.targets) }
        self:_prepare(spec)
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

-- The entities a map's objective names by their place in the stage's entity
-- list: each once (a turret is its hull), and only what can be destroyed.
function Mission:_placed(indices)
    local list, seen = {}, {}
    for _, index in ipairs(indices) do
        local e = self.world.placed[index]
        if e and not seen[e] and e.max_hp > 0 then
            seen[e] = true
            list[#list + 1] = e
        end
    end
    return list
end

function Mission:_make_objective(spec)
    local o = { spec = spec, type = spec.type, done = false, progress = 0 }
    if spec.type == "destroy" then
        o.matching = spec.entities and self:_placed(spec.entities) or self:_collect(spec)
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
    elseif spec.type == "reach" then
        -- Get to a place; with land, be down or stopped there.
        o.x, o.y = spec.x or 0, spec.y or 0
        o.radius = spec.radius or REACH_RADIUS
        o.target = 1
    elseif spec.type == "survive" then
        o.target = math.max(0, spec.seconds or 0)
    elseif spec.type == "collect" then
        o.target = math.max(0, spec.count or 0)
    elseif spec.type == "air" then
        -- Enemy helicopters shot down. They are no entities: the helicopter
        -- system counts them on the world, and says how many the phase can
        -- ever put up (none without a post, no more than the posts when none
        -- comes back).
        local world = self.world
        o.target = math.max(0, math.min(spec.count or 0, world.air_supply or #(world.heli_spawns or {})))
    elseif spec.type == "protect" then
        -- Never in the way of a win: the phase fails once more of them fell
        -- than the objective allows.
        o.matching = self:_placed(spec.entities or {})
        o.allowed  = spec.losses or 0
        o.target   = #o.matching
        o.progress = o.target
        o.done     = true
    end
    if o.optional == nil then o.optional = spec.optional or false end
    -- An objective with nothing to act on is satisfied so it can never block a win.
    if not Mission.TYPES[o.type] or o.target == 0 then
        o.done = true
    end
    return o
end

-- An objective comes up: at the start of the phase, or when the ones before it
-- are done on a map that wants them in order. What a map's objective is about
-- goes on the radar from here.
function Mission:_open(o)
    o.open = true
    if o.type == "destroy" and o.spec.mark then
        o.marked = {}
        self:_mark(o)
    elseif o.type == "reach" then
        o.mark = { x = o.x, y = o.y }
        table.insert(self.world.marks, o.mark)
    end
    self:_fire(o.spec.on_open)
end

-- Put what an open objective of a map is about on the radar: whatever of it
-- is there and not marked yet.
function Mission:_mark(o)
    for _, e in ipairs(o.matching) do
        if e:is_alive() and not e.objective then
            e.objective = true
            o.marked[#o.marked + 1] = e
        end
    end
end

-- Hold back or bring in what is placed at index of the stage's entity list:
-- an entity, or a helicopter post. Returns true when an entity came in.
function Mission:_hold(index, held)
    local world = self.world
    local e     = world.placed[index]
    if e then
        if held and e:is_alive() then
            e.held = true
        elseif not held and e.held then
            e.held = nil
            return true
        end
    elseif world.placed_posts[index] and world.combat and world.combat.heli_sys then
        local helis = world.combat.heli_sys
        if held then helis:hold(world.placed_posts[index]) else helis:release(world.placed_posts[index]) end
    end
    return false
end

function Mission:_hold_pickup(index, held)
    local powerups = self.world.powerups
    if not powerups then return end
    if held then powerups:hold(index) else powerups:release(index) end
end

-- What a map's event waits to do is kept from happening until it fires: what
-- it brings in is not there, the units it sets off stand, the guns it opens
-- fire with are silent.
function Mission:_prepare(event)
    if not event then return end
    local world = self.world
    for _, index in ipairs(event.show or {}) do self:_hold(index, true) end
    for _, index in ipairs(event.show_pickups or {}) do self:_hold_pickup(index, true) end
    for _, index in ipairs(event.drive or {}) do
        if world.placed[index] then world.placed[index].parked = true end
    end
    for _, index in ipairs(event.open_fire or {}) do
        if world.placed[index] then world.placed[index].silent = true end
    end
end

-- An event of a map: in this order, objects come in (show) and go
-- (hide), blow up (destroy), set off on their routes (drive), open or hold
-- fire, shelling is called on a place (shell), the time limit moves
-- (add_time), the weather changes, its line is said, and the phase may end
-- won or lost (ends).
function Mission:_fire(event)
    if not event then return end
    local world = self.world
    local shown = false
    for _, index in ipairs(event.show or {}) do shown = self:_hold(index, false) or shown end
    for _, index in ipairs(event.show_pickups or {}) do self:_hold_pickup(index, false) end
    if shown then
        for _, o in ipairs(self.objectives) do
            if o.marked and not o.done then self:_mark(o) end
        end
    end
    for _, index in ipairs(event.hide or {}) do self:_hold(index, true) end
    for _, index in ipairs(event.hide_pickups or {}) do self:_hold_pickup(index, true) end
    for _, index in ipairs(event.destroy or {}) do
        if world.placed[index] then world.placed[index]:blow_up() end
    end
    for _, index in ipairs(event.drive or {}) do
        if world.placed[index] then world.placed[index].parked = nil end
    end
    for _, index in ipairs(event.open_fire or {}) do
        if world.placed[index] then world.placed[index].silent = nil end
    end
    for _, index in ipairs(event.hold_fire or {}) do
        if world.placed[index] then world.placed[index].silent = true end
    end
    if event.shell and world.combat then
        world.combat.air_strike:shell(event.shell.x, event.shell.y, event.shell.radius)
    end
    if event.add_time and self.time_limit then
        self.time_limit = math.max(self.age, self.time_limit + event.add_time)
    end
    if event.weather then world.env.weather = event.weather ~= "none" and event.weather or nil end
    if event.say and event.say ~= "" then self.messages[#self.messages + 1] = event.say end
    if event.ends == "win" then
        self:_win()
    elseif event.ends == "fail" then
        self:_fail_phase(FAIL_EVENT)
    end
end

function Mission:_win()
    if self.state == "phase_failed" or self.state == "won" then return end
    self.state  = "won"
    self.notice = nil
    self.world:say("voice.mission_complete")
end

-- Whether the phase is over, won or lost for good.
function Mission:_over()
    return self.state == "won" or self.state == "phase_failed"
end

-- Whether a player is inside the circle; with land, one that is down or stopped.
function Mission:_player_at(x, y, radius, land)
    for _, p in ipairs(self.players) do
        if not p.death and (not land or p:is_stationary()) then
            local dx, dy = self.world:delta(p.x, p.y, x, y)
            if dx * dx + dy * dy <= radius * radius then return true end
        end
    end
    return false
end

-- Whether what sets off a map's event has happened: its time has come, a
-- player got to its place, the last of its objects is destroyed (never when
-- none of them can be).
function Mission:_triggered(event)
    local spec = event.spec
    if spec.when == "area" then
        local place = spec.place
        return self:_player_at(place.x, place.y, place.radius or REACH_RADIUS, place.land)
    elseif spec.when == "destroyed" then
        if #event.targets == 0 then return false end
        for _, e in ipairs(event.targets) do
            if not e:is_destroyed() then return false end
        end
        return true
    end
    return self.age >= event.next_at
end

-- Fire the map's events that are set off, in the order the map lists them;
-- one at a time with every fires again that much later, times in all.
function Mission:_update_events()
    local waiting = {}
    for _, event in ipairs(self.events) do
        local again = true
        if self:_triggered(event) then
            self:_fire(event.spec)
            event.left = event.left - 1
            again      = event.spec.every ~= nil and event.left > 0
            if again then event.next_at = event.next_at + event.spec.every end
        end
        if again then waiting[#waiting + 1] = event end
    end
    self.events = waiting
end

function Mission:_close(o)
    for _, e in ipairs(o.marked or {}) do e.objective = nil end
    o.marked = nil
    if o.mark then
        for i, mark in ipairs(self.world.marks) do
            if mark == o.mark then
                table.remove(self.world.marks, i)
                break
            end
        end
        o.mark = nil
    end
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
        if not e:is_destroyed() then left = left + 1 end
    end
    if left > #self.commanders then return end
    for _, e in ipairs(self.commanders) do e.dormant, e.protected = nil, nil end
    self.notice = NOTICE_COMMANDER
end

function Mission:update(dt)
    if self.state == "won" or self.state == "failed" or self.state == "phase_failed" then return end
    self.age = self.age + dt
    self:_update_events()
    if self:_over() then return end
    if self:_all_dead() then self.state = "failed"; return end
    -- An agent killed leaves its pad open for good (0x1fe911).
    if self.world.saboteur and self.world.saboteur:mission_failed() then
        self:_fail_phase(FAIL_AGENT)
        return
    end
    self:_update_commanders()
    self:_update_guards()

    -- Optional objectives (e.g. a secondary POW rescue) are tracked but never block
    -- the return-to-base / win once every required objective is done. On a map
    -- that wants its objectives in order, one is only worked on once every
    -- required one before it is done.
    local all_done, cleared, reachable = true, false, true
    for _, o in ipairs(self.objectives) do
        if not o.done and reachable then
            if not o.open then self:_open(o) end
            self:_update_objective(o, dt)
            if o.done then
                cleared = true
                self:_close(o)
                self:_fire(o.spec.on_done)
                Log.info("mission", "objective done: %s", self:objective_label(o))
            end
        end
        if not o.done and not o.optional then
            all_done = false
            if self.def.ordered then reachable = false end
        end
    end
    if self:_over() then return end
    if not all_done and self.time_limit and self.age >= self.time_limit then
        self:_fail_phase(FAIL_TIME)
        return
    end
    -- An objective finishing is called out, except the last one: that rolls
    -- straight into the return-to-base line below.
    if cleared and not all_done then self.world:say("voice.objective_cleared") end

    if all_done then
        -- The special end, and a map that asks for no flight home.
        if self.special_end or self.def.no_return then
            self:_win()
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

function Mission:_update_objective(o, dt)
    if     o.type == "destroy"         then self:_update_destroy(o)
    elseif o.type == "rescue"          then self:_update_rescue(o)
    elseif o.type == "sabotage"        then self:_update_sabotage(o)
    elseif o.type == "destroy_targets" then self:_update_destroy_targets(o)
    elseif o.type == "rescue_people"   then self:_update_rescue_people(o)
    elseif o.type == "reach"           then self:_update_reach(o)
    elseif o.type == "survive"         then self:_update_survive(o, dt)
    elseif o.type == "collect"         then self:_update_collect(o)
    elseif o.type == "air"             then self:_update_air(o) end
end

-- A vehicle inside the place's circle; with land, one that is down or stopped.
function Mission:_update_reach(o)
    if self:_player_at(o.x, o.y, o.radius, o.spec.land) then
        o.progress = 1
        o.done     = true
    end
end

-- The clock of a hold-out runs while the objective is the one being worked on.
function Mission:_update_survive(o, dt)
    o.progress = math.min(o.target, o.progress + dt)
    if o.progress >= o.target then o.done = true end
end

-- Medals picked up this phase, by the whole team.
function Mission:_update_collect(o)
    local medals = 0
    for _, p in ipairs(self.players) do medals = medals + (p.medals or 0) end
    o.progress = math.min(o.target, medals)
    if medals >= o.target then o.done = true end
end

-- Enemy helicopters shot down this phase, by anybody.
function Mission:_update_air(o)
    o.progress = math.min(o.target, self.world.air_kills or 0)
    if o.progress >= o.target then o.done = true end
end

-- What a map wants kept: the phase is lost with one more of them than it allows.
function Mission:_update_guards()
    for _, o in ipairs(self.guards) do
        local lost = 0
        for _, e in ipairs(o.matching) do
            if e:is_destroyed() then lost = lost + 1 end
        end
        o.progress = o.target - lost
        if lost > o.allowed then self:_fail_phase(FAIL_GUARD) end
    end
end

function Mission:_update_destroy_targets(o)
    local rem = 0
    for _, e in ipairs(o.list) do
        if not e:is_destroyed() then rem = rem + 1 end
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
        if not o.counted[e.id] and e:is_destroyed() then
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
    if o.type == "destroy" and (s.entities or s.kinds) then
        return string.format("%s  %d/%d", s.label or "DESTROY", o.progress, o.target)
    elseif o.type == "destroy" then
        return string.format("%s  %d/%d",
            s.label or ("Destroy " .. (s.target or s.kind or "targets")), o.progress, o.target)
    elseif o.type == "reach" then
        return s.label or "GET TO THE MARKED PLACE"
    elseif o.type == "survive" then
        return s.label or "HOLD OUT"
    elseif o.type == "collect" then
        return string.format("%s  %d/%d", s.label or "COLLECT MEDALS", o.progress, o.target)
    elseif o.type == "protect" then
        return string.format("%s  %d/%d", s.label or "KEEP INTACT", o.progress, o.target)
    elseif o.type == "air" then
        return string.format("%s  %d/%d", s.label or "SHOOT DOWN HELICOPTERS", o.progress, o.target)
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

-- The first unfinished required objective, or nil. Optional ones never hold
-- up the prompts.
function Mission:_current()
    for _, o in ipairs(self.objectives) do
        if not o.done and not o.optional then return o end
    end
    return nil
end

-- Short shared-state line for the co-op banner: the first unfinished objective,
-- or the return-to-base prompt once they are all done.
function Mission:status_line()
    if self.state == "won"          then return "MISSION COMPLETE" end
    if self.state == "failed"       then return "MISSION FAILED" end
    if self.state == "phase_failed" then return table.concat(self.fail_lines, " - ") end
    if self.briefing and self.age < 5 then return self.briefing end
    local o = self:_current()
    return o and self:objective_label(o) or "RETURN TO BASE"
end

-- The objective at hand as a player-made map words it, for the scene to show
-- when it changes; nil on a stage of the original, which says nothing.
function Mission:order()
    if not self.def.announce or self.state ~= "active" then return nil end
    local o = self:_current()
    return o and self:objective_label(o) or nil
end

-- Seconds left on the phase's clock: the hold-out when that is the objective
-- at hand, else the time limit of a map, else a hold-out running beside other
-- objectives. nil when no clock runs.
function Mission:clock()
    if self.state ~= "active" then return nil end
    local at_hand = self:_current()
    if at_hand and at_hand.type == "survive" and at_hand.open then return at_hand.target - at_hand.progress end
    if self.time_limit then return math.max(0, self.time_limit - self.age) end
    for _, o in ipairs(self.objectives) do
        if o.type == "survive" and o.open and not o.done then return o.target - o.progress end
    end
    return nil
end

return Mission
