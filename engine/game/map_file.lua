-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json = require "lib.json"
local Log  = require "engine.core.log"

-- Player-made maps: one JSON file per map in maps/ of the save directory. A map
-- holds sprite names, class references into the pack's stages and coordinates,
-- never pixels. engine/game/map_compiler.lua turns one into the stage table
-- the world loads.
--
--   format       file format version (MapFile.FORMAT)
--   name, author display name, free text
--   based_on     the pack stage a clone was copied from, else absent
--   base         the pack stage whose class table the compiled stage starts
--                from (projectiles, walkers, helicopters keep their indices)
--   environment  { art, night, weather, look, music }: the art set (mission
--                digit) and what may be mixed over it (World:_set_environment)
--   size         wrap period of the torus in world pixels
--   vehicle      "tank" / "chopper" when the map forces one
--   loadout      what the player flies when the map decides instead of the
--                equip screen: { vehicle, weapons = { name = level }, special,
--                loads (ammunition multiplier), fuel, armor (0-100), lives }
--   briefing     paragraphs of the briefing text
--   briefing_cards  the picture beside each paragraph: { kind = "view", x, y,
--                size, label } (a square of the map itself, drawn when shown),
--                { kind = "card", stage, slot } (a card of a pack stage's
--                briefing) or { kind = "none" }
--   difficulty   the difficulty the map is played on whatever the player's own
--                is: values of the keys of engine/game/difficulty.lua
--   objectives   the objectives in the order they are listed (and, with
--                ordered, worked on), each { type, label, optional } and:
--                  "targets"   every object that is a mission target
--                  "rescue"    the people on the map
--                  "sabotage"  the agents and their buildings
--                  "destroy"   objects (ids) or kinds (entity kind names) to
--                              destroy, count of them when not all
--                  "reach"     x, y, radius: a place to get to; land: be down
--                              or stopped there
--                  "survive"   seconds to hold out
--                  "collect"   count of medals to pick up
--                  "protect"   objects (ids) to keep, losses allowed among them
--                The first three follow from what is on the map and need no
--                entry; one gives them their wording and their place.
--   ordered      an objective is worked on once those before it are done
--   time_limit   seconds the required objectives have to be done in
--   hold_agents  agents stay inside until every building has one
--   commander    the commander building rule (stage special end)
--   no_return    the phase ends with the last objective, without the flight home
--   types        property sets: { from, class, sprite, set }: a class of a
--                pack stage and the fields changed on it
--   objects      { id, t, x, y, route, owner, group }, in entity order;
--                stored as rows [id, t, x, y, route, owner, group] with 0 for
--                an unset link
--   routes       { id, points = { { x, y }, ... } }
--   lines        ground polylines { color = { r, g, b }, points }
--   view         the editor's last view { x, y, zoom }
local MapFile = {}

MapFile.DIR    = "maps"
MapFile.FORMAT = 1

MapFile.MIN_SIZE     = 1024
MapFile.MAX_SIZE     = 4096
MapFile.DEFAULT_SIZE = 4096

local NAME_MAX = 40

local OBJECTIVE_TYPES = {
    targets = true, rescue = true, sabotage = true, destroy = true, reach = true, survive = true,
    collect = true, protect = true,
}
-- The first files kept the three objectives of the original under these keys.
local FIRST_OBJECTIVES = { { "destroy", "targets" }, { "rescue", "rescue" }, { "sabotage", "sabotage" } }

function MapFile.path(name)
    return MapFile.DIR .. "/" .. name .. ".json"
end

function MapFile.exists(name)
    return love.filesystem.getInfo(MapFile.path(name)) ~= nil
end

-- A file name for a display name: lowercase letters, digits and underscores,
-- made unique among the maps already there.
function MapFile.file_name(display_name)
    local stem = (display_name or ""):lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if stem == "" then stem = "map" end
    stem = stem:sub(1, NAME_MAX)
    local name, n = stem, 1
    while MapFile.exists(name) do
        n    = n + 1
        name = stem .. "_" .. n
    end
    return name
end

-- A blank map over the class table of `base`, a pack stage of art set `art`.
function MapFile.new(display_name, art, base)
    return {
        format      = MapFile.FORMAT,
        name        = display_name or "NEW MAP",
        author      = "",
        base        = base,
        environment = { art = art },
        size        = MapFile.DEFAULT_SIZE,
        briefing    = {},
        briefing_cards = {},
        objectives  = {},
        hold_agents = false,
        commander   = false,
        next_id     = 1,
        types       = {},
        objects     = {},
        routes      = {},
        lines       = {},
    }
end

-- encoding

local function compact(v)
    local kind = type(v)
    if kind == "table" then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for i = 1, #v do parts[i] = compact(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do parts[i] = json.encode(k) .. ":" .. compact(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json.encode(v)
end

local function rows(list, fn)
    if #list == 0 then return "[]" end
    local parts = {}
    for i, item in ipairs(list) do parts[i] = "    " .. fn(item) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n  ]"
end

local function object_row(o)
    return string.format("[%d,%d,%d,%d,%d,%d,%d]", o.id, o.t, o.x, o.y, o.route or 0, o.owner or 0, o.group or 0)
end

-- Header keys in file order; the lists follow, one entry per line, so a map
-- stays readable and diffable.
local HEADER = { "format", "name", "author", "based_on", "base", "environment", "size", "vehicle", "loadout",
                 "difficulty", "briefing", "briefing_cards", "objectives", "ordered", "time_limit", "hold_agents",
                 "commander", "no_return", "view", "next_id" }

function MapFile.encode(map)
    local out = {}
    for _, key in ipairs(HEADER) do
        if map[key] ~= nil then
            out[#out + 1] = string.format("  %s: %s", json.encode(key), compact(map[key]))
        end
    end
    out[#out + 1] = '  "types": '   .. rows(map.types, compact)
    out[#out + 1] = '  "routes": '  .. rows(map.routes, compact)
    out[#out + 1] = '  "lines": '   .. rows(map.lines, compact)
    out[#out + 1] = '  "objects": ' .. rows(map.objects, object_row)
    return "{\n" .. table.concat(out, ",\n") .. "\n}\n"
end

local function link(v)
    return (type(v) == "number" and v > 0) and v or nil
end

local function objective_list(raw)
    local out = {}
    if type(raw) ~= "table" then return out end
    if raw[1] == nil then
        for _, pair in ipairs(FIRST_OBJECTIVES) do
            local goal = raw[pair[1]]
            if type(goal) == "table" then
                out[#out + 1] = { type = pair[2], label = goal.label, optional = goal.optional }
            end
        end
        return out
    end
    for _, goal in ipairs(raw) do
        if type(goal) == "table" and OBJECTIVE_TYPES[goal.type] then out[#out + 1] = goal end
    end
    return out
end

-- The entry of a map's objectives of one type, or nil.
function MapFile.objective(map, kind)
    for _, goal in ipairs(map.objectives) do
        if goal.type == kind then return goal end
    end
    return nil
end

-- A decoded file as a map table, or nil and what is wrong with it.
function MapFile.decode(text)
    local ok, map = pcall(json.decode, text)
    if not ok or type(map) ~= "table" then return nil, "not a map file" end
    if type(map.format) ~= "number" or type(map.objects) ~= "table" or type(map.types) ~= "table" then
        return nil, "not a map file"
    end
    if map.format > MapFile.FORMAT then return nil, "made by a newer version of the game" end
    if type(map.base) ~= "string" then return nil, "no base stage" end
    map.name        = type(map.name) == "string" and map.name or "UNNAMED"
    map.author      = type(map.author) == "string" and map.author or ""
    map.environment = type(map.environment) == "table" and map.environment or {}
    map.size        = math.max(MapFile.MIN_SIZE, math.min(MapFile.MAX_SIZE, tonumber(map.size) or MapFile.DEFAULT_SIZE))
    map.briefing    = type(map.briefing) == "table" and map.briefing or {}
    map.loadout     = type(map.loadout) == "table" and map.loadout or nil
    map.difficulty  = type(map.difficulty) == "table" and map.difficulty or nil
    map.briefing_cards = type(map.briefing_cards) == "table" and map.briefing_cards or {}
    map.objectives  = objective_list(map.objectives)
    map.ordered     = map.ordered == true or nil
    map.time_limit  = (tonumber(map.time_limit) or 0) > 0 and tonumber(map.time_limit) or nil
    map.routes      = type(map.routes) == "table" and map.routes or {}
    map.lines       = type(map.lines) == "table" and map.lines or {}
    local objects, top = {}, 0
    for i, row in ipairs(map.objects) do
        if type(row) ~= "table" or type(row[1]) ~= "number" or not map.types[row[2]] then
            return nil, "damaged object list"
        end
        objects[i] = { id = row[1], t = row[2], x = row[3] or 0, y = row[4] or 0,
                       route = link(row[5]), owner = link(row[6]), group = link(row[7]) }
        if row[1] > top then top = row[1] end
        if (row[7] or 0) > top then top = row[7] end
    end
    for _, route in ipairs(map.routes) do
        if type(route.id) == "number" and route.id > top then top = route.id end
    end
    map.objects = objects
    map.next_id = math.max(tonumber(map.next_id) or 1, top + 1)
    return map
end

-- files

function MapFile.read(name)
    local path = MapFile.path(name)
    local raw  = love.filesystem.getInfo(path) and love.filesystem.read(path)
    if not raw then return nil, "no such map" end
    local map, err = MapFile.decode(raw)
    if not map then
        Log.warn("map", "ignoring %s: %s", path, err)
        return nil, err
    end
    return map, raw
end

function MapFile.write(map, name)
    love.filesystem.createDirectory(MapFile.DIR)
    local path    = MapFile.path(name)
    local ok, err = pcall(love.filesystem.write, path, MapFile.encode(map))
    if not ok or err == false then
        Log.warn("map", "cannot write %s: %s", path, tostring(err))
        return false
    end
    Log.info("map", "saved %s (%d objects)", path, #map.objects)
    return true
end

function MapFile.delete(name)
    Log.info("map", "deleted %s", MapFile.path(name))
    love.filesystem.remove(MapFile.path(name))
end

-- Import a map file's text under a free file name. Returns the name, or nil
-- and the reason.
function MapFile.import(text, file_name)
    local map, err = MapFile.decode(text)
    if not map then return nil, err end
    local name = MapFile.file_name(file_name or map.name)
    love.filesystem.createDirectory(MapFile.DIR)
    local ok = pcall(love.filesystem.write, MapFile.path(name), text)
    if not ok then return nil, "cannot write the map" end
    Log.info("map", "imported %s", MapFile.path(name))
    return name
end

-- Every readable map: { name, map, modified }, newest first. A name with a
-- leading underscore is the editor's own (a map being tried, unsaved changes
-- kept aside) and is not listed.
function MapFile.list()
    local out = {}
    if not love.filesystem.getInfo(MapFile.DIR) then return out end
    for _, item in ipairs(love.filesystem.getDirectoryItems(MapFile.DIR)) do
        local name = item:match("^([a-z0-9][a-z0-9_]*)%.json$")
        if name then
            local map = MapFile.read(name)
            if map then
                local info = love.filesystem.getInfo(MapFile.path(name))
                out[#out + 1] = { name = name, map = map, modified = info and info.modtime or 0 }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.modified ~= b.modified then return a.modified > b.modified end
        return a.name < b.name
    end)
    return out
end

-- A short fingerprint of a map file's text, kept in a replay's header so a
-- recording can tell when its map has changed since.
function MapFile.hash(text)
    local a, b = 1, 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%04x%04x", b, a)
end

return MapFile
