local Class = require "engine.core.class"
local json  = require "lib.json"

local Mission = Class()

local defs = {}   -- stage_name -> mission def, loaded once

function Mission.load(path)
    local raw = love.filesystem.read(path)
    defs = raw and json.decode(raw) or {}
end

-- Build a generic objective def from the stage's decoded objectives block
-- (destroy all targets / rescue all people, then return to base), or nil when
-- the stage has no destroy/rescue goal (pure free play).
local function objectives_from_stage(obj)
    if not obj or not (obj.destroy or obj.rescue) then return nil end
    local def = { objectives = {} }
    if obj.destroy then def.objectives[#def.objectives + 1] = { type = "destroy_targets" } end
    if obj.rescue  then def.objectives[#def.objectives + 1] = { type = "rescue_people"  } end
    return def
end

-- Build a mission for the named stage: an explicit missions.json def if one
-- exists, otherwise the stage's own decoded objectives. nil when neither yields
-- an objective.
function Mission.for_stage(world, player, stage_name)
    local def = defs[stage_name]
    if not (def and def.objectives) then
        def = objectives_from_stage(world.stage.objectives)
    end
    if not def then return nil end
    return Mission:new(world, { player }, def)
end

-- Shared co-op objective from the stage's decoded objectives block; both players
-- contribute to the same goals.
function Mission.coop(world, players)
    local def = objectives_from_stage(world.stage.objectives)
    -- The saboteur objective lives in missions.json, not the stage's decoded block;
    -- fold it into the shared co-op objective when its system is active.
    if world.saboteur and world.saboteur.active then
        def = def or { objectives = {} }
        def.objectives[#def.objectives + 1] = { type = "sabotage" }
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

-- Optional per-building POW counts for a rescue stage (missions.json
-- rescue_pow_counts, in powhere load order); nil falls back to a random 1-3.
function Mission.rescue_counts(stage_name)
    local def = defs[stage_name]
    return def and def.rescue_pow_counts or nil
end

-- The saboteur objective spec for a stage (target building, detonation style,
-- killable flag, ...), read by the SaboteurSystem before it resets; nil when the
-- stage has no sabotage objective.
function Mission.sabotage_spec(stage_name)
    local def = defs[stage_name]
    if not def then return nil end
    for _, spec in ipairs(def.objectives or {}) do
        if spec.type == "sabotage" then return spec end
    end
    return nil
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
    self.home_radius  = def.home_radius or 48
    self.age         = 0          -- seconds since start (briefing shows while young)
    self.state       = "active"   -- active -> return_to_base -> won | failed
    self.objectives  = {}
    for _, spec in ipairs(def.objectives or {}) do
        self.objectives[#self.objectives + 1] = self:_make_objective(spec)
    end

    -- Return-to-base point: an explicit pad sprite for stages whose friendly base
    -- is not the auto-detected basecirc.bin / h.bin, otherwise the world's home pad.
    if def.home_base_asset then
        local e = self:_collect({ target = def.home_base_asset })[1]
        if e then self.home_x, self.home_y = e.x, e.y end
    end
    if not self.home_x then self.home_x, self.home_y = world:home_base() end
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
        -- The walking-saboteur objective is driven by the SaboteurSystem, which owns
        -- the target buildings and their landing pads (reset before the mission).
        o.target = self.world.saboteur and #self.world.saboteur.sites or 0
    elseif spec.type == "destroy_targets" then
        -- Co-op: every is_target entity collected by World:load.
        o.list   = self.world.targets
        o.target = #o.list
    elseif spec.type == "rescue_people" then
        -- POWHERE buildings drive the walking-POW RescueSystem; loose civilians fall
        -- back to simple fly-over collection.
        o.use_system = (#self.world.rescue_zones > 0) and self.world.rescue ~= nil
        if o.use_system then
            o.target = self.world.rescue:required_count()
        else
            o.list      = self.world.rescue_people
            o.collected = {}
            o.radius    = spec.radius or 40
            o.target    = #o.list
        end
    end
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

function Mission:update(dt)
    if self.state == "won" or self.state == "failed" then return end
    self.age = self.age + dt
    if self:_all_dead() then self.state = "failed"; return end
    -- Losing a saboteur on a "killable" stage fails the mission outright.
    if self.world.saboteur and self.world.saboteur:mission_failed() then
        self.state = "failed"; return
    end

    -- Optional objectives (e.g. a secondary POW rescue) are tracked but never block
    -- the return-to-base / win once every required objective is done.
    local all_done = true
    for _, o in ipairs(self.objectives) do
        if not o.done then
            self:_update_objective(o)
            if not o.done and not o.spec.optional then all_done = false end
        end
    end

    if all_done then
        if self.state == "active" then self.state = "return_to_base" end
        if self:_at_home_base() then self.state = "won" end
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

function Mission:_update_rescue_people(o)
    if o.use_system then
        local r = self.world.rescue
        o.progress = r:rescued_count()
        o.target   = r:required_count()
        if r:all_cleared() then o.done = true end
        return
    end
    for _, p in ipairs(self.players) do
        if p:is_stationary() then
            for _, z in ipairs(o.list) do
                if z:is_alive() and not o.collected[z.id] then
                    local dx, dy = self.world:delta(p.x, p.y, z.x, z.y)
                    if dx * dx + dy * dy <= o.radius * o.radius then
                        o.collected[z.id] = true
                        o.progress = o.progress + 1
                        p.pows  = (p.pows or 0) + 1
                        p.score = (p.score or 0) + 150
                    end
                end
            end
        end
    end
    if o.progress >= o.target then o.done = true end
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
    if self.player:is_stationary() then
        for _, z in ipairs(o.zones) do
            if not o.collected[z.id] then
                local dx, dy = self.world:delta(self.player.x, self.player.y, z.x, z.y)
                if dx * dx + dy * dy <= o.radius * o.radius then
                    o.collected[z.id] = true
                    o.progress = o.progress + 1
                    self.player.pows = (self.player.pows or 0) + 1
                end
            end
        end
    end
    if o.progress >= o.target then o.done = true end
end

-- Progress mirrors the SaboteurSystem: a site clears once its building is blown
-- and its saboteur recovered; the objective is done when every site is cleared.
function Mission:_update_sabotage(o)
    local s = self.world.saboteur
    if not s then o.done = true; return end
    o.progress = s:cleared_count()
    o.target   = #s.sites
    if s:all_cleared() then o.done = true end
end

function Mission:_at_home_base()
    if not self.home_x then return true end   -- no pad on this stage: win on objectives
    for _, p in ipairs(self.players) do
        if p:is_stationary() then
            local dx, dy = self.world:delta(p.x, p.y, self.home_x, self.home_y)
            if dx * dx + dy * dy <= self.home_radius * self.home_radius then return true end
        end
    end
    return false
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
        return string.format("%s  %d/%d", s.label or "SABOTAGE BUILDINGS", o.progress, o.target)
    elseif o.type == "destroy_targets" then
        return string.format("%s  %d/%d", s.label or "DESTROY TARGETS", o.progress, o.target)
    elseif o.type == "rescue_people" then
        return string.format("RESCUE  %d/%d", o.progress, o.target)
    end
    return s.label or o.type
end

-- Short shared-state line for the co-op banner: the first unfinished objective,
-- or the return-to-base prompt once they are all done.
function Mission:status_line()
    if self.state == "won"    then return "MISSION COMPLETE" end
    if self.state == "failed" then return "MISSION FAILED" end
    if self.briefing and self.age < 5 then return self.briefing end
    -- Required objectives drive the banner; optional ones never hold up the prompt.
    for _, o in ipairs(self.objectives) do
        if not o.done and not o.spec.optional then return self:objective_label(o) end
    end
    return "RETURN TO BASE"
end

return Mission
