-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Entity      = require "engine.game.entity"
local MapCompiler = require "engine.game.map_compiler"
local Catalog     = require "engine.editor.catalog"

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
    local loose, enemies, huts, riders, stranded = {}, 0, {}, {}, {}
    for _, o in ipairs(map.objects) do
        local info = doc:info(o)
        local cls  = info.cls
        if not info.ok then
            missing[#missing + 1] = o
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

    if #missing > 0 then
        issue("error", string.format("%d OBJECTS USE SPRITES THIS GAME DATA DOES NOT HAVE", #missing), missing)
    end
    if not home then
        issue("error", "NO HOME PAD: PLACE ONE FROM THE BASE OBJECTS")
    end
    if #targets == 0 and people == 0 and drop_pads == 0 then
        issue("error", "NO OBJECTIVE: MARK A MISSION TARGET, PUT PEOPLE IN A BUILDING OR SET AN AGENT TARGET")
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

    if #loose > 0 then
        issue("warn", string.format("%d OBJECTIVE MARKS BELONG TO NO BUILDING AND ARE ONLY SCENERY", #loose), loose)
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
