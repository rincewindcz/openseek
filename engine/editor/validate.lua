-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Entity      = require "engine.game.entity"
local MapFile     = require "engine.game.map_file"
local MapCompiler = require "engine.game.map_compiler"
local Catalog     = require "engine.editor.catalog"
local Goals       = require "engine.editor.goals"

-- What stands between a map and a playable phase. An error keeps the map from
-- being played; a warning does not. Each issue may name the objects it is
-- about, which the editor frames when the issue is clicked.
local Validate = {}

local SPAWN_CLEAR     = 40     -- world px around the home pad that must be free of solid objects
local HANGAR_REACH    = 24     -- see World:_link_hangar_tanks
local MANY_OBJECTS    = 10000
local COMMANDER_CLASS = 2      -- structure class behaviour of the commander building

local KIND_FLAG, KIND_PAD, KIND_PERSON =
    MapCompiler.KIND_POW_MARKER, MapCompiler.KIND_PAD, MapCompiler.KIND_PERSON

-- { { level = "error" | "warn", text, objects } ... }, errors first.
function Validate.run(doc)
    local map    = doc.map
    local issues = {}
    local function issue(level, text, objects)
        issues[#issues + 1] = { level = level, text = text, objects = objects }
    end

    if not MapCompiler.pack_stage(map.base) then
        issue("error", "THIS GAME DATA LACKS " .. tostring(map.base):upper() .. ", WHICH THE MAP IS BUILT ON")
        return issues
    end

    local home = doc:home()
    local missing, targets, commanders, people, drop_pads = {}, {}, {}, 0, 0
    local starts, spare = {}, {}
    local loose, enemies, huts, riders, stranded = {}, 0, {}, {}, {}
    -- The vehicle the map fixes, and the ammunition laid out that it cannot load.
    local vehicle = map.loadout and map.loadout.vehicle or map.vehicle
    local useless = {}
    for _, o in ipairs(map.objects) do
        local info = doc:info(o)
        local cls  = info.cls
        if not info.ok then
            missing[#missing + 1] = o
        elseif info.kind_name == "pickup" then
            local weapon = map.types[o.t].weapon
            local fits   = not (weapon and vehicle)
            for _, user in ipairs(weapon and Catalog.weapon_users(weapon) or {}) do
                if user == vehicle then fits = true end
            end
            if not fits then useless[#useless + 1] = o end
        elseif info.kind_name == "start" then
            if starts[info.start] then spare[#spare + 1] = o else starts[info.start] = o end
        else
            local owner = o.owner and doc.by_id[o.owner]
            if cls.is_target then
                targets[#targets + 1] = o
                if cls.kind_name == "structure" and cls.behaviour == COMMANDER_CLASS then
                    commanders[#commanders + 1] = o
                end
            end
            if cls.kind == KIND_PAD or cls.kind == KIND_PERSON or cls.kind == KIND_FLAG then
                if not owner then
                    loose[#loose + 1] = o
                elseif cls.kind == KIND_PAD and cls.behaviour ~= 1 then
                    drop_pads = drop_pads + 1
                elseif cls.kind == KIND_PERSON then
                    people = people + 1
                elseif cls.kind == KIND_PAD then
                    people = people + (doc:info(owner).cls.pows or 0)
                end
            end
            local td = Entity.type_for(cls.kind_name)
            if td.armed or cls.kind_name == "enemy_helicopter" then enemies = enemies + 1 end
            if cls.kind_name == "structure" and (info.stem == "shut" or info.stem == "jhanger") then
                huts[#huts + 1] = o
            end
            if cls.kind_name == "tank" and Catalog.is_ride(cls) then riders[#riders + 1] = o end
            if o.route then
                local route = doc:route(o.route)
                if not route or #route.points < 2 then stranded[#stranded + 1] = o end
            end
        end
    end

    -- The objectives of the map's own, and whether anything has to be done at all.
    local content  = { targets = #targets, rescue = people, sabotage = drop_pads }
    local required = 0
    for kind, count in pairs(content) do
        local listed = MapFile.objective(map, kind)
        if count > 0 and not (listed and listed.optional) then required = required + 1 end
    end
    local feasible = 0
    for i, goal in ipairs(map.objectives) do
        local name  = "OBJECTIVE " .. i
        local works = content[goal.type] == nil
        if goal.type == "destroy" and goal.kinds then
            if Goals.count_kinds(doc, goal.kinds) == 0 then
                works = false
                issue("warn", name .. " HAS NOTHING OF ITS KIND ON THE MAP AND IS LEFT OUT")
            end
        elseif goal.type == "destroy" or goal.type == "protect" then
            if #Goals.objects(doc, goal) == 0 then
                works = false
                issue("warn", name .. " HAS NO OBJECT LEFT THAT CAN BE DESTROYED AND IS LEFT OUT")
            end
        elseif goal.type == "air" then
            local air = Goals.air(doc)
            if air.posts == 0 then
                works = false
                issue("warn", name .. " ASKS FOR HELICOPTERS, BUT THE MAP HAS NO HELICOPTER POST: IT IS LEFT OUT")
            elseif not air.returning and (goal.count or 0) > air.posts then
                issue("warn", string.format("%s ASKS FOR %d HELICOPTERS; THE MAP HAS %d AND NONE COMES BACK, SO %d END IT",
                    name, goal.count, air.posts, air.posts))
            end
        end
        -- What an objective has to destroy cannot wait for that objective to be done.
        local waiting = {}
        for _, o in ipairs(goal.type == "destroy" and Goals.held(doc, goal, "on_done") or {}) do waiting[o.id] = true end
        for _, o in ipairs(goal.objects and Goals.objects(doc, goal) or {}) do
            if waiting[o.id] then
                issue("warn", name .. " HAS TO DESTROY AN OBJECT THAT ONLY APPEARS ONCE IT IS DONE", { o })
                break
            end
        end
        if works and goal.type ~= "protect" then
            feasible = feasible + 1
            if not goal.optional then required = required + 1 end
        end
    end

    if #missing > 0 then
        issue("error", string.format("%d OBJECTS USE SPRITES THIS GAME DATA DOES NOT HAVE", #missing), missing)
    end
    if not home then
        issue("error", "NO HOME PAD: PLACE ONE FROM THE BASE OBJECTS")
    end
    if #targets == 0 and people == 0 and drop_pads == 0 and feasible == 0 then
        issue("error", "NO OBJECTIVE: MARK A MISSION TARGET, PUT PEOPLE IN A BUILDING, SET AN AGENT TARGET "
            .. "OR ADD AN OBJECTIVE IN THE MAP SETTINGS")
    elseif required == 0 then
        issue("warn", "EVERY OBJECTIVE IS OPTIONAL: THE PHASE IS WON AS IT STARTS")
    end
    if map.commander then
        if #commanders == 0 then
            issue("error", "COMMANDER RULE IS ON, BUT NO BUILDING IS THE COMMANDERS")
        elseif #commanders == #targets then
            issue("error", "THE COMMANDERS BUILDING NEEDS OTHER TARGETS TO FALL FIRST", commanders)
        end
    elseif #commanders > 0 then
        issue("warn", "A COMMANDERS BUILDING IS SET, BUT THE COMMANDER RULE IS OFF", commanders)
    end

    -- The events: what they cannot do, and what they undo.
    local to_destroy = {}
    for _, goal in ipairs(map.objectives) do
        if goal.type == "destroy" and not goal.optional then
            for _, o in ipairs(Goals.objects(doc, goal)) do to_destroy[o.id] = true end
        end
    end
    local function check_event(name, event)
        if event.add_time and not map.time_limit then
            issue("warn", name .. " MOVES THE TIME LIMIT, BUT THE MAP HAS NONE")
        end
        for _, o in ipairs(Goals.acted_on(doc, event, "hide")) do
            if to_destroy[o.id] then
                issue("warn", name .. " TAKES AWAY AN OBJECT AN OBJECTIVE HAS TO DESTROY", { o })
                break
            end
        end
    end
    for _, timer in ipairs(map.timers or {}) do
        local name = "THE TIMED EVENT AT " .. Goals.clock(timer.at)
        if map.time_limit and timer.at >= map.time_limit then
            issue("warn", name .. " COMES AFTER THE TIME LIMIT AND NEVER HAPPENS")
        elseif not Goals.does_something(timer) then
            issue("warn", name .. " SAYS AND DOES NOTHING")
        end
        check_event(name, timer)
    end
    for i, goal in ipairs(map.objectives) do
        for _, key in ipairs(Goals.EVENTS) do
            if goal[key] then check_event("AN EVENT OF OBJECTIVE " .. i, goal[key]) end
        end
    end

    if #spare > 0 then
        issue("warn", "A PLAYER HAS MORE THAN ONE START: THE FIRST ONE PLACED COUNTS", spare)
    end
    if map.players == 1 and starts[2] then
        issue("warn", "THE MAP IS FOR ONE PLAYER: THE START OF PLAYER 2 IS NOT USED", { starts[2] })
    end
    if #loose > 0 then
        issue("warn", string.format("%d OBJECTIVE MARKS BELONG TO NO BUILDING AND ARE ONLY SCENERY", #loose), loose)
    end
    if #useless > 0 then
        issue("warn", string.format("%d PICKUPS HOLD AMMUNITION THE %s CANNOT USE AND ARE LEFT OUT", #useless,
            vehicle:upper()), useless)
    end
    if #stranded > 0 then
        issue("warn", string.format("%d UNITS ARE ON A ROUTE WITH FEWER THAN TWO POINTS", #stranded), stranded)
    end
    for _, tank in ipairs(riders) do
        local housed = false
        for _, hut in ipairs(huts) do
            if math.abs(hut.x - tank.x) < HANGAR_REACH and math.abs(hut.y - tank.y) < HANGAR_REACH then housed = true end
        end
        if not housed then issue("warn", "A HANGAR TANK HAS NO HANGAR OVER IT", { tank }) end
    end
    if home then
        local blocking = {}
        doc:each_in(home.x, home.y, home.x, home.y, SPAWN_CLEAR, function(o)
            local info = doc:info(o)
            local td   = Entity.type_for(info.kind_name)
            if td.solid and o ~= home then blocking[#blocking + 1] = o end
        end)
        if #blocking > 0 then
            issue("warn", "SOLID OBJECTS STAND ON THE HOME PAD: THE VEHICLE CANNOT START THERE", blocking)
        end
    end
    if enemies == 0 then issue("warn", "NOTHING ON THE MAP SHOOTS BACK") end
    if #map.objects > MANY_OBJECTS then
        issue("warn", string.format("%d OBJECTS: THE ORIGINAL STAGES HOLD 4500 TO 8400", #map.objects))
    end

    table.sort(issues, function(a, b)
        if a.level ~= b.level then return a.level == "error" end
        return false
    end)
    return issues
end

-- Counts the editor shows for the map: objects by layer, and the objectives.
function Validate.summary(doc)
    local layers, targets, people, agents = {}, 0, 0, 0
    for _, o in ipairs(doc.map.objects) do
        local info = doc:info(o)
        local cls  = info.cls
        layers[info.layer] = (layers[info.layer] or 0) + 1
        if cls.is_target then targets = targets + 1 end
        local owner = o.owner and doc.by_id[o.owner]
        if owner and cls.kind == KIND_PERSON then people = people + 1 end
        if owner and cls.kind == KIND_PAD then
            if cls.behaviour == 1 then people = people + (doc:info(owner).cls.pows or 0) else agents = agents + 1 end
        end
    end
    return { layers = layers, targets = targets, people = people, agents = agents }
end

function Validate.errors(issues)
    local n = 0
    for _, item in ipairs(issues) do
        if item.level == "error" then n = n + 1 end
    end
    return n
end

return Validate
