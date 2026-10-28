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
--   players      1 / 2 when the map is for one player only, or for two on the
--                split screen only; absent when it can be played either way
--   loadout      what the player flies when the map decides instead of the
--                equip screen: { vehicle, weapons = { name = level }, special,
--                loads (ammunition multiplier), fuel, armor (0-100), lives }
--   equip        what the map changes when the player buys and equips
--                (Loadout:restrict): {
--                  medals      the purse for the shop (Loadout.START_MEDALS
--                              when absent)
--                  no_shop     the briefing's SHOP is closed
--                  weapons     { name = level }: 0 keeps the weapon out of the
--                              shop and off the vehicle, 1 and up hands it
--                              over at that level
--                  no_bays, no_special, no_chars  areas of the equip screen
--                              that are closed, holding what the map put there:
--                  bays        { vehicle = { the weapon of bay 2, 3, ... } }
--                  special     { vehicle = name, "" for none }
--                  fuel, armor 0-100
--                }, what the equip screen starts with where the map names nothing
--   briefing     paragraphs of the briefing text
--   briefing_cards  the picture beside each paragraph: { kind = "view", x, y,
--                size, label } (a square of the map itself, drawn when shown),
--                { kind = "card", stage, slot } (a card of a pack stage's
--                briefing) or { kind = "none" }
--   difficulty   the difficulty the map is played on whatever the player's own
--                is: values of the keys of engine/game/difficulty.lua
--   objectives   the objectives in the order they are listed (and, with
--                ordered, worked on), each { type, label, optional, on_open,
--                on_done } (an event as the objective comes up or is done)
--                and:
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
--                  "air"       count of enemy helicopters to shoot down
--                The first three follow from what is on the map and need no
--                entry; one gives them their wording and their place.
--   events       events of the map, each an event with its id (unique among
--                the events, given at decode when missing), off (it waits to
--                be switched on by another event) and what sets it off
--                (when): "time" at = seconds since it was switched on, the
--                start of the phase unless off (again every so many seconds,
--                times in all, with every), "area" place = { x, y, radius,
--                land }: a player gets there (down or stopped with land), or
--                with units = objects (ids) one of them does, "destroyed"
--                targets = objects (ids): they are destroyed, "damaged"
--                targets, below = percent: they are down to below percent of
--                their toughness or destroyed; count of the targets when not
--                all. Files before triggers held them as timers, every one at
--                a time.
--                An event is { say = a line shown then, show = objects (ids)
--                not on the map until then, hide = objects taken away then,
--                destroy = objects blown up, damage = objects damaged down to
--                strength percent (0 blows them up), reroute = units sent
--                along route (a route id) from its first point, drive = units
--                standing until then and setting off on their routes,
--                open_fire = guns silent until then, hold_fire = guns silent
--                from then on, unshield = objects that cannot be destroyed
--                until then, shield = objects that cannot be from then on,
--                shell = { x, y, radius }: enemy shelling on a place, add_time
--                = seconds added to the time limit (fewer when negative),
--                weather = the weather from then on ("none": clear skies),
--                switch_on / switch_off = events of the map (ids) switched on
--                or off, ends = "win" or "fail": the phase ends so }
--   ordered      an objective is worked on once those before it are done
--   time_limit   seconds the required objectives have to be done in
--   hold_agents  agents stay inside until every building has one
--   commander    the commander building rule (stage special end)
--   no_return    the phase ends with the last objective, without the flight home
--   types        property sets: { from, class, sprite, set }: a class of a
--                pack stage and the fields changed on it (and across, of
--                maps only: the sprite mirrored over its diagonal); or { pickup, weapon,
--                ammo_only }: a pickup lying there from the start ("fuel",
--                "armor", "medal", or "ammo" for a weapon, which gives the
--                weapon to a vehicle without it unless ammo_only), whose
--                objects are no entities; or
--                { start = player }: where that player's vehicle is put at the
--                start of the phase and after a crash (the first one placed
--                counts; without one the player starts on the home pad)
--   objects      { id, t, x, y, route, owner, group }, in entity order;
--                stored as rows [id, t, x, y, route, owner, group] with 0 for
--                an unset link
--   routes       { id, points = { { x, y }, ... } }
--   lines        ground polylines { color = { r, g, b }, points }
--   roads        { id, points, width, pitch, edge = { color, color }, across,
--                down }: a road by its centre line; engine/game/roads.lua
--                turns them into border lines (edge: the colour above and to
--                the left, then below and to the right) and centre marks
--                every pitch pixels (across / down: the mark's type for a
--                level and an upright leg, { from, class, sprite })
--   terrain      ground of other art sets: { cell = side of a square cell in
--                world px, cells = { [k] = art digit } } with k = row * n +
--                column + 1 and n = size / cell rounded up (the last row and
--                column reach past the edge); a cell left out has the
--                map's own art set. Stored as rows, one string a row of runs
--                ("12a40.": twelve cells of art 0, forty of the map's own;
--                "a" to "e" are art 0 to 4, "." the map's own)
--   view         the editor's last view { x, y, zoom }
local MapFile = {}

MapFile.DIR    = "maps"
MapFile.FORMAT = 1

MapFile.MIN_SIZE     = 1024
MapFile.MAX_SIZE     = 4096
MapFile.DEFAULT_SIZE = 4096

local NAME_MAX = 40

-- The sides a terrain cell may have.
MapFile.TERRAIN_CELLS = { 16, 32, 64, 128 }
local OWN_ART  = "."
local ART_BASE = string.byte("a")

local OBJECTIVE_TYPES = {
    targets = true, rescue = true, sabotage = true, destroy = true, reach = true, survive = true,
    collect = true, protect = true, air = true,
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
        roads       = {},
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

-- The terrain as rows of runs, one string a row.
local function terrain_rows(terrain, size)
    local n, cells, out = MapFile.terrain_side(terrain.cell, size), terrain.cells, {}
    for row = 0, n - 1 do
        local parts, run, code = {}, 0, nil
        for column = 0, n - 1 do
            local art  = cells[row * n + column + 1]
            local this = art and string.char(ART_BASE + tonumber(art)) or OWN_ART
            if this ~= code and run > 0 then
                parts[#parts + 1] = run .. code
                run = 0
            end
            code, run = this, run + 1
        end
        parts[#parts + 1] = run .. code
        out[#out + 1] = json.encode(table.concat(parts))
    end
    return out
end

-- The terrain of a decoded file, or nil when it has none or none that fits the size.
local function terrain_of(raw, size)
    if type(raw) ~= "table" or type(raw.rows) ~= "table" then return nil end
    local cell = tonumber(raw.cell)
    local fits = false
    for _, side in ipairs(MapFile.TERRAIN_CELLS) do
        if side == cell then fits = true end
    end
    if not fits then return nil end
    local n, cells = MapFile.terrain_side(cell, size), {}
    for row = 0, n - 1 do
        local text   = type(raw.rows[row + 1]) == "string" and raw.rows[row + 1] or ""
        local column = 0
        for run, code in text:gmatch("(%d+)([%.a-e])") do
            local art = code ~= OWN_ART and tostring(code:byte() - ART_BASE) or nil
            for _ = 1, tonumber(run) do
                if column < n then cells[row * n + column + 1] = art end
                column = column + 1
            end
        end
    end
    return { cell = cell, cells = cells }
end

local function object_row(o)
    return string.format("[%d,%d,%d,%d,%d,%d,%d]", o.id, o.t, o.x, o.y, o.route or 0, o.owner or 0, o.group or 0)
end

-- Header keys in file order; the lists follow, one entry per line, so a map
-- stays readable and diffable.
local HEADER = { "format", "name", "author", "based_on", "base", "environment", "size", "vehicle", "players", "loadout",
                 "equip", "difficulty", "briefing", "briefing_cards", "objectives", "events", "ordered", "time_limit", "hold_agents",
                 "commander", "no_return", "view", "next_id" }

function MapFile.encode(map)
    local out = {}
    for _, key in ipairs(HEADER) do
        if map[key] ~= nil then
            out[#out + 1] = string.format("  %s: %s", json.encode(key), compact(map[key]))
        end
    end
    if map.terrain then
        out[#out + 1] = string.format('  "terrain": {"cell":%d,"rows":%s}', map.terrain.cell,
            rows(terrain_rows(map.terrain, map.size), function(row) return row end))
    end
    out[#out + 1] = '  "types": '   .. rows(map.types, compact)
    out[#out + 1] = '  "routes": '  .. rows(map.routes, compact)
    out[#out + 1] = '  "lines": '   .. rows(map.lines, compact)
    out[#out + 1] = '  "roads": '   .. rows(map.roads, compact)
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

-- The fields of an event that list objects (ids), in the order they act.
MapFile.EVENT_OBJECTS = { "show", "hide", "destroy", "damage", "reroute", "drive", "open_fire", "hold_fire",
                          "unshield", "shield" }

-- What sets off an event of the map.
MapFile.TRIGGERS = { "time", "area", "destroyed", "damaged" }

-- Whether an event of the map is set off by something it has.
local function triggered(event)
    if event.when == "time" then
        event.at    = tonumber(event.at)
        event.every = (tonumber(event.every) or 0) > 0 and tonumber(event.every) or nil
        event.times = event.every and math.max(1, math.floor(tonumber(event.times) or 1)) or nil
        return event.at ~= nil and event.at >= 0
    elseif event.when == "area" then
        local place = event.place
        if type(event.units) ~= "table" then event.units = nil end
        return type(place) == "table" and tonumber(place.x) ~= nil and tonumber(place.y) ~= nil
    end
    event.count = (tonumber(event.count) or 0) >= 1 and math.floor(tonumber(event.count)) or nil
    if event.when == "damaged" then
        event.below = tonumber(event.below)
        if not event.below then return false end
    end
    return type(event.targets) == "table"
end

-- The events of a map; nil for none.
local function event_list(raw)
    local known, out = {}, {}
    for _, when in ipairs(MapFile.TRIGGERS) do known[when] = true end
    for _, event in ipairs(type(raw) == "table" and raw or {}) do
        if type(event) == "table" then
            event.when = known[event.when] and event.when or "time"
            event.off  = event.off == true or nil
            if triggered(event) then out[#out + 1] = event end
        end
    end
    -- Ids: what the map gave, kept when unique, else the next free one.
    local used, last = {}, 0
    for _, event in ipairs(out) do
        local id = tonumber(event.id)
        if id and id >= 1 and id % 1 == 0 and not used[id] then
            used[id] = true
            last     = math.max(last, id)
        else
            event.id = nil
        end
    end
    for _, event in ipairs(out) do
        if not event.id then
            last       = last + 1
            event.id   = last
            used[last] = true
        end
    end
    return #out > 0 and out or nil
end

-- The id of a new event of the map: one past the highest.
function MapFile.next_event_id(map)
    local last = 0
    for _, event in ipairs(map.events or {}) do last = math.max(last, event.id or 0) end
    return last + 1
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
    map.players     = (map.players == 1 or map.players == 2) and map.players or nil
    map.loadout     = type(map.loadout) == "table" and map.loadout or nil
    map.equip       = type(map.equip) == "table" and map.equip or nil
    map.difficulty  = type(map.difficulty) == "table" and map.difficulty or nil
    map.briefing_cards = type(map.briefing_cards) == "table" and map.briefing_cards or {}
    map.objectives  = objective_list(map.objectives)
    map.events      = event_list(map.events or map.timers)
    map.timers      = nil
    map.ordered     = map.ordered == true or nil
    map.time_limit  = (tonumber(map.time_limit) or 0) > 0 and tonumber(map.time_limit) or nil
    map.terrain     = terrain_of(map.terrain, map.size)
    map.routes      = type(map.routes) == "table" and map.routes or {}
    map.lines       = type(map.lines) == "table" and map.lines or {}
    local roads = {}
    for _, road in ipairs(type(map.roads) == "table" and map.roads or {}) do
        if type(road) == "table" and type(road.points) == "table" and type(road.edge) == "table"
        and type(road.edge[1]) == "table" and type(road.edge[2]) == "table" then
            roads[#roads + 1] = road
        end
    end
    map.roads       = roads
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
    for _, shapes in ipairs({ map.routes, map.roads }) do
        for _, shape in ipairs(shapes) do
            if type(shape.id) == "number" and shape.id > top then top = shape.id end
        end
    end
    map.objects = objects
    map.next_id = math.max(tonumber(map.next_id) or 1, top + 1)
    return map
end

-- terrain

-- An empty terrain of cells cell px a side.
function MapFile.new_terrain(cell)
    return { cell = cell, cells = {} }
end

-- Cells a side of a terrain of cells cell px a side over a map size px a side.
function MapFile.terrain_side(cell, size)
    return math.ceil(size / cell)
end

-- The key into the cells of the cell under (x, y), which wraps around the map.
function MapFile.terrain_index(cell, size, x, y)
    local column = math.floor((x % size) / cell)
    local row    = math.floor((y % size) / cell)
    return row * MapFile.terrain_side(cell, size) + column + 1
end

-- The art digit of the terrain cell under (x, y), or nil for the map's own.
function MapFile.terrain_at(terrain, size, x, y)
    return terrain.cells[MapFile.terrain_index(terrain.cell, size, x, y)]
end

-- The terrain of a map old_size px a side as cells of cell px over a map
-- size px a side: a new cell takes the ground most of the old cells it
-- covers inside the map have (the first of them on a tie), or the one it
-- lies in; what lies past the old edge wraps around, as the objects do.
function MapFile.resample_terrain(terrain, old_size, size, cell)
    local n, out = MapFile.terrain_side(cell, size), {}
    local per    = math.max(1, cell / terrain.cell)
    local step   = cell / per
    for row = 0, n - 1 do
        for column = 0, n - 1 do
            local counts, best, most = {}, nil, 0
            for i = 0, per - 1 do
                for j = 0, per - 1 do
                    local x, y = column * cell + (j + 0.5) * step, row * cell + (i + 0.5) * step
                    if (x < size and y < size) or (i == 0 and j == 0) then
                        local art = MapFile.terrain_at(terrain, old_size, x, y)
                        local key = art or OWN_ART
                        counts[key] = (counts[key] or 0) + 1
                        if counts[key] > most then best, most = art, counts[key] end
                    end
                end
            end
            out[row * n + column + 1] = best
        end
    end
    return { cell = cell, cells = out }
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

-- Every readable map: { name, map, hash, modified }, newest first. A name with a
-- leading underscore is the editor's own (a map being tried, unsaved changes
-- kept aside) and is not listed.
function MapFile.list()
    local out = {}
    if not love.filesystem.getInfo(MapFile.DIR) then return out end
    for _, item in ipairs(love.filesystem.getDirectoryItems(MapFile.DIR)) do
        local name = item:match("^([a-z0-9][a-z0-9_]*)%.json$")
        if name then
            local map, raw = MapFile.read(name)
            if map then
                local info = love.filesystem.getInfo(MapFile.path(name))
                out[#out + 1] = { name = name, map = map, hash = MapFile.hash(raw), modified = info and info.modtime or 0 }
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
