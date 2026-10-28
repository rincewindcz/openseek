-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Entity      = require "engine.game.entity"
local MapFile     = require "engine.game.map_file"
local MapCompiler = require "engine.game.map_compiler"
local Catalog     = require "engine.editor.catalog"

-- The editor's side of a map's objectives (the "objectives" of
-- engine/game/map_file.lua): the rows the map settings list, the changes made
-- to them and what they point at on the map. An entry is never changed in
-- place: every change writes a new list, which is what the undo history keeps.
local Goals = {}

local BASE_FLAG = 0x40   -- class flag of the home base building (World:load)

-- The events of an objective, in the order the settings show them.
Goals.EVENTS = { "on_open", "on_done" }

-- What an event cannot hold back: a start, which is no object of the phase,
-- or what another system owns (the marks of the people objectives).
local NEVER_HELD = { start = true, missing = true }
local MARK_KINDS = {
    [MapCompiler.KIND_POW_MARKER] = true, [MapCompiler.KIND_PERSON] = true, [MapCompiler.KIND_PAD] = true,
}

-- title names the objective in the settings; wording is what the phase shows
-- when the author gives none (Mission:objective_label); count is the map
-- summary's number of what a content objective is about.
Goals.TYPES = {
    targets  = { title = "DESTROY THE MISSION TARGETS", wording = "DESTROY TARGETS", count = "targets" },
    rescue   = { title = "PICK UP THE PEOPLE", wording = "RESCUE", count = "people" },
    sabotage = { title = "AGENTS IN AND OUT", wording = "RECOVER AGENTS", count = "agents" },
    destroy  = { title = "DESTROY", wording = "DESTROY" },
    reach    = { title = "GET TO A PLACE", wording = "GET TO THE MARKED PLACE" },
    survive  = { title = "HOLD OUT", wording = "HOLD OUT" },
    collect  = { title = "COLLECT MEDALS", wording = "COLLECT MEDALS" },
    protect  = { title = "KEEP INTACT", wording = "KEEP INTACT" },
    air      = { title = "SHOOT DOWN HELICOPTERS", wording = "SHOOT DOWN HELICOPTERS" },
}

local CONTENT = { "targets", "rescue", "sabotage" }

function Goals.limits()
    return Catalog.data().goals
end

-- The objectives the settings list: the map's own entries, then what its
-- content asks for and it does not list. summary is Validate.summary(doc).
function Goals.rows(doc, summary)
    local rows, listed = {}, {}
    for _, goal in ipairs(doc.map.objectives) do
        rows[#rows + 1]   = goal
        listed[goal.type] = true
    end
    for _, kind in ipairs(CONTENT) do
        if not listed[kind] and summary[Goals.TYPES[kind].count] > 0 then rows[#rows + 1] = { type = kind } end
    end
    return rows
end

function Goals.write(doc, rows, label)
    local list = {}
    for i, goal in ipairs(rows) do list[i] = goal end
    doc:set_map("objectives", list, label or "OBJECTIVES")
end

-- Row i with one field changed (nil clears it).
function Goals.set(doc, rows, i, key, value)
    local goal = {}
    for k, v in pairs(rows[i]) do goal[k] = v end
    goal[key] = value
    rows[i]   = goal
    Goals.write(doc, rows)
end

function Goals.move(doc, rows, i, dir)
    local j = i + dir
    if j < 1 or j > #rows then return end
    rows[i], rows[j] = rows[j], rows[i]
    Goals.write(doc, rows, "OBJECTIVE ORDER")
end

function Goals.remove(doc, rows, i)
    table.remove(rows, i)
    Goals.write(doc, rows, "REMOVE OBJECTIVE")
end

function Goals.add(doc, rows, goal)
    rows[#rows + 1] = goal
    Goals.write(doc, rows, "ADD OBJECTIVE")
    return #rows
end

function Goals.destructible(doc, o)
    local cls = doc:info(o).cls
    return (cls.toughness or 0) > 0 or Catalog.has_flag(cls.flags, BASE_FLAG)
end

-- The ids an objective takes from a set of objects: what can be destroyed,
-- and of the parts placed together on one spot (a hull and its turret) one.
function Goals.pick(doc, objects)
    local ids, seen = {}, {}
    for _, o in ipairs(objects) do
        if Goals.destructible(doc, o) then
            local spot = (o.group or -o.id) .. ":" .. o.x .. ":" .. o.y
            if not seen[spot] then
                seen[spot]    = true
                ids[#ids + 1] = o.id
            end
        end
    end
    return ids
end

-- The objects of an objective that are still on the map.
function Goals.objects(doc, goal)
    local found = {}
    for _, id in ipairs(goal.objects or {}) do
        local o = doc.by_id[id]
        if o and Goals.destructible(doc, o) then found[#found + 1] = o end
    end
    return found
end

-- events

-- Whether an objective can carry events: one that is kept rather than done
-- never comes up.
function Goals.has_events(goal)
    return goal.type ~= "protect"
end

function Goals.holdable(doc, o)
    local info = doc:info(o)
    return info.ok and not NEVER_HELD[info.kind_name] and not MARK_KINDS[info.cls.kind]
end

-- What an event does, in the order it does it and the event editor lists it.
-- objects names what of a selection the action takes (Goals.takes), events
-- that it takes events of the map; the others have a setting of their own.
-- extra is a field of the event the action keeps beside its list.
Goals.ACTIONS = {
    { key = "show", label = "APPEAR", objects = "held",
      tip = "NOT ON THE MAP UNTIL THEN: NOT SEEN, DOING NOTHING, NOT TO BE HIT" },
    { key = "hide", label = "VANISH", objects = "held", tip = "TAKEN OFF THE MAP THEN, WITHOUT A WRECK" },
    { key = "destroy", label = "BLOW UP", objects = "destructible", tip = "BLOWN UP THEN, AS IF SHOT, FOR NO POINTS" },
    { key = "damage", label = "DAMAGE", objects = "destructible", extra = "strength",
      tip = "DAMAGED DOWN TO A SHARE OF THEIR TOUGHNESS: SMOKING UNDER 60%, BLOWN UP AT 0%" },
    { key = "reroute", label = "NEW ROUTE", objects = "routed", extra = "route",
      tip = "UNITS ON A ROUTE DRIVE ANOTHER ONE FROM ITS FIRST POINT" },
    { key = "drive", label = "SET OFF", objects = "routed",
      tip = "UNITS ON A ROUTE STAND STILL UNTIL THEN, THEN DRIVE IT" },
    { key = "open_fire", label = "OPEN FIRE", objects = "armed", tip = "GUNS AND MINES DO NOTHING UNTIL THEN" },
    { key = "hold_fire", label = "HOLD FIRE", objects = "armed", tip = "GUNS AND MINES DO NOTHING FROM THEN ON" },
    { key = "unshield", label = "DESTRUCTIBLE", objects = "destructible", tip = "CANNOT BE DESTROYED UNTIL THEN" },
    { key = "shield", label = "INDESTRUCTIBLE", objects = "destructible", tip = "CANNOT BE DESTROYED FROM THEN ON" },
    { key = "shell", label = "SHELLING", tip = "ENEMY ARTILLERY LANDS ON A PLACE A FEW SECONDS LATER" },
    { key = "add_time", label = "TIME LIMIT", tip = "SECONDS ADDED TO THE TIME LIMIT, OR TAKEN OFF IT" },
    { key = "weather", label = "WEATHER", tip = "THE WEATHER FROM THEN ON" },
    { key = "switch_on", label = "SWITCH ON", events = true,
      tip = "EVENTS OF THE MAP SWITCHED ON: A TIME OF THEIRS COUNTS FROM THEN" },
    { key = "switch_off", label = "SWITCH OFF", events = true,
      tip = "EVENTS OF THE MAP SWITCHED OFF UNTIL SOMETHING SWITCHES THEM ON AGAIN" },
    { key = "ends", label = "END THE PHASE", tip = "THE PHASE IS WON OR LOST THERE AND THEN" },
}

Goals.ACTION = {}
for _, action in ipairs(Goals.ACTIONS) do Goals.ACTION[action.key] = action end

-- Whether an action of the kind (Goals.ACTIONS objects) can act on o.
function Goals.takes(doc, o, kind)
    local info = doc:info(o)
    if kind == "held" then return Goals.holdable(doc, o) end
    if not info.ok then return false end
    if kind == "destructible" then return Goals.destructible(doc, o) end
    if kind == "routed" then return o.route ~= nil end
    if kind == "armed" then return Entity.type_for(info.kind_name).armed == true or info.kind_name == "mine" end
    return false
end

-- The ids an action takes from a set of objects.
function Goals.take(doc, objects, key)
    local ids, kind = {}, Goals.ACTION[key].objects
    for _, o in ipairs(objects) do
        if Goals.takes(doc, o, kind) then ids[#ids + 1] = o.id end
    end
    return ids
end

-- The objects an action of an event acts on that are still on the map.
function Goals.acted_on(doc, event, key)
    local found, kind = {}, Goals.ACTION[key].objects
    for _, id in ipairs((event or {})[key] or {}) do
        local o = doc.by_id[id]
        if o and Goals.takes(doc, o, kind) then found[#found + 1] = o end
    end
    return found
end

-- The objects an event brings in that are still on the map: event is an
-- objective's event (goal[key]) or a timed event.
function Goals.held_of(doc, event)
    return Goals.acted_on(doc, event, "show")
end

-- The objects an event of an objective brings in that are still on the map.
function Goals.held(doc, goal, key)
    return Goals.held_of(doc, goal[key])
end

-- A copy of an event with one field changed (nil clears it).
function Goals.with(event, key, value)
    local out = {}
    for k, v in pairs(event or {}) do out[k] = v end
    out[key] = value
    return out
end

-- Whether an action keeps a list (of objects or of events).
local function listed(action)
    return action.objects ~= nil or action.events == true
end

-- Whether an event does or says anything.
function Goals.does_something(event)
    if event.say and event.say ~= "" then return true end
    for _, action in ipairs(Goals.ACTIONS) do
        local value = event[action.key]
        if value ~= nil and not (listed(action) and #value == 0) then return true end
    end
    return false
end

-- What an event does, in a few words.
function Goals.summary(event)
    local parts = {}
    for _, action in ipairs(Goals.ACTIONS) do
        local value = event[action.key]
        if value ~= nil then
            parts[#parts + 1] = listed(action) and (action.label .. " " .. #value) or action.label
        end
    end
    if event.say and event.say ~= "" then parts[#parts + 1] = "A LINE SAID" end
    return #parts > 0 and table.concat(parts, ", ") or "NOTHING YET"
end

-- the map's events

-- The map's events, as a list to change and write back.
function Goals.map_events(doc)
    local list = {}
    for i, event in ipairs(doc.map.events or {}) do list[i] = event end
    return list
end

function Goals.write_map_events(doc, list, label)
    doc:set_map("events", #list > 0 and list or nil, label or "EVENTS")
end

-- Event i of the list replaced by event, which keeps the id of the one it replaces.
function Goals.set_map_event(doc, list, i, event)
    if list[i] and event.id ~= list[i].id then event = Goals.with(event, "id", list[i].id) end
    list[i] = event
    Goals.write_map_events(doc, list)
end

-- A new event at a time, after the last one at a time.
function Goals.add_map_event(doc, list)
    local step = Goals.limits().timer.default
    local at   = step
    for _, event in ipairs(list) do
        if event.when == "time" then at = math.max(at, event.at + step) end
    end
    list[#list + 1] = { id = MapFile.next_event_id({ events = list }), when = "time",
                        at = math.min(at, Goals.limits().timer.max) }
    Goals.write_map_events(doc, list, "ADD EVENT")
    return #list
end

-- An event's list of events (switch_on, switch_off) without the id; the
-- event itself when it names none of it.
local function without_event(event, id)
    if not event then return event end
    local out = event
    for _, key in ipairs({ "switch_on", "switch_off" }) do
        local ids = event[key]
        if ids then
            local kept = {}
            for _, other in ipairs(ids) do
                if other ~= id then kept[#kept + 1] = other end
            end
            if #kept < #ids then out = Goals.with(out, key, kept) end
        end
    end
    return out
end

-- Event i taken out, and out of what every event switches, so a later event
-- given its id is switched by nothing.
function Goals.remove_map_event(doc, list, i)
    local id = list[i].id
    doc:begin("REMOVE EVENT")
    table.remove(list, i)
    for j, event in ipairs(list) do list[j] = without_event(event, id) end
    Goals.write_map_events(doc, list, "REMOVE EVENT")
    local goals, changed = {}, false
    for j, goal in ipairs(doc.map.objectives) do
        goals[j] = goal
        for _, key in ipairs(Goals.EVENTS) do
            local event = without_event(goal[key], id)
            if event ~= goal[key] then
                goals[j] = Goals.with(goals[j], key, event)
                changed  = true
            end
        end
    end
    if changed then doc:set_map("objectives", goals, "REMOVE EVENT") end
    doc:commit()
end

-- The place in the map's list of the event with the id, or nil.
function Goals.event_index(doc, id)
    for i, event in ipairs(doc.map.events or {}) do
        if event.id == id then return i end
    end
    return nil
end

-- Whether an event of the map or of an objective switches on the event with the id.
function Goals.switched_on(doc, id)
    local events = {}
    for _, event in ipairs(doc.map.events or {}) do events[#events + 1] = event end
    for _, goal in ipairs(doc.map.objectives) do
        for _, key in ipairs(Goals.EVENTS) do events[#events + 1] = goal[key] end
    end
    for _, event in ipairs(events) do
        for _, other in ipairs(event.switch_on or {}) do
            if other == id then return true end
        end
    end
    return false
end

-- An event of the map set off another way, keeping what it does and whether
-- it is off at the start: by "time" at the time given, by "area" at the place
-- given, by "destroyed" once the targets given are, by "damaged" once they
-- are down to below percent.
function Goals.retrigger(event, when, at, place, targets, below)
    local out = Goals.with(event, "when", when)
    out.at, out.every, out.times, out.place, out.targets = nil, nil, nil, nil, nil
    out.units, out.count, out.below = nil, nil, nil
    if when == "time" then
        out.at = at
    elseif when == "area" then
        out.place = place
    else
        out.targets = targets
        if when == "damaged" then out.below = below end
    end
    return out
end

-- The units whose arrival sets off an event of the map that are still on the map.
function Goals.units(doc, event)
    local found = {}
    for _, id in ipairs(event.units or {}) do
        local o = doc.by_id[id]
        if o and Goals.takes(doc, o, "routed") then found[#found + 1] = o end
    end
    return found
end

-- The objects whose destruction sets off an event of the map that are still on the map.
function Goals.targets(doc, event)
    return Goals.objects(doc, { objects = event.targets })
end

function Goals.clock(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- What sets off an event of the map, in a few words.
function Goals.when(doc, event)
    local text
    if event.when == "area" then
        if event.units then
            text = "WHEN A UNIT GETS TO A PLACE"
        else
            text = event.place.land and "WHEN A PLAYER IS DOWN AT A PLACE" or "WHEN A PLAYER GETS TO A PLACE"
        end
    elseif event.when == "destroyed" or event.when == "damaged" then
        local n     = #Goals.targets(doc, event)
        local state = event.when == "damaged" and ("DOWN TO " .. event.below .. "%") or "DESTROYED"
        if event.count and event.count < n then
            text = string.format("ONCE %d OF %d OBJECTS ARE %s", event.count, n, state)
        elseif n == 1 then
            text = "ONCE AN OBJECT IS " .. state
        else
            text = string.format("ONCE %d OBJECTS ARE %s", n, state)
        end
    else
        local at = event.off and (Goals.clock(event.at) .. " AFTER IT IS SWITCHED ON") or ("AT " .. Goals.clock(event.at))
        if event.every then
            return string.format("%s, THEN EVERY %s, %d TIMES IN ALL", at, Goals.clock(event.every), event.times or 1)
        end
        return at
    end
    return event.off and (text .. ", ONCE SWITCHED ON") or text
end

-- Row i with one of its events (key) replaced; an empty event is dropped.
function Goals.set_event(doc, rows, i, key, event)
    Goals.set(doc, rows, i, key, event and next(event) and event or nil)
end

-- The kinds an objective may ask for, as choices, and the id of the choice a
-- stored list of kind names is.
function Goals.kind_choices()
    local out = {}
    for i, item in ipairs(Goals.limits().kinds) do out[i] = { label = item.label, value = item.id } end
    return out
end

function Goals.kinds(id)
    for _, item in ipairs(Goals.limits().kinds) do
        if item.id == id then return item.kinds end
    end
    return nil
end

function Goals.kind_id(kinds)
    local key = table.concat(kinds or {}, ",")
    for _, item in ipairs(Goals.limits().kinds) do
        if table.concat(item.kinds, ",") == key then return item.id end
    end
    return nil
end

-- How many objects of the kinds are on the map and can be destroyed. Of the
-- parts placed together on one spot the first that can be counts for all, as
-- the world folds a turret onto its hull.
function Goals.count_kinds(doc, kinds)
    local wanted, seen, n = {}, {}, 0
    for _, kind in ipairs(kinds or {}) do wanted[kind] = true end
    for _, o in ipairs(doc.map.objects) do
        local info = doc:info(o)
        if (info.cls.toughness or 0) > 0 then
            local spot = (o.group or -o.id) .. ":" .. o.x .. ":" .. o.y
            if not seen[spot] then
                seen[spot] = true
                if wanted[info.kind_name] then n = n + 1 end
            end
        end
    end
    return n
end

-- The helicopter posts on the map, and whether a helicopter shot down comes
-- back (a post with a negative respawn delay stays empty).
function Goals.air(doc)
    local posts, returning = 0, false
    for _, o in ipairs(doc.map.objects) do
        local info = doc:info(o)
        if info.ok and info.kind_name == "enemy_helicopter" then
            posts = posts + 1
            if (info.cls.field_2c or 0) >= 0 then returning = true end
        end
    end
    return { posts = posts, returning = returning }
end

-- What the objectives and events point at, for the editor to mark:
-- by_id[object id] = { type, index }, held[object id] = the event that holds
-- it back, in words, and places = { { x, y, radius, index, shell, trigger } }:
-- where an objective (index being its place in the list) sends the player,
-- where an event's shelling lands, or where a player sets off an event.
function Goals.marks(doc)
    local marks = { by_id = {}, held = {}, places = {} }
    local function shelling(event)
        local shell = event and event.shell
        if shell then
            marks.places[#marks.places + 1] = { x = shell.x, y = shell.y,
                radius = shell.radius or Goals.limits().shell.default, shell = true }
        end
    end
    for _, event in ipairs(doc.map.events or {}) do
        local name = "THE EVENT " .. Goals.when(doc, event)
        for _, o in ipairs(Goals.held_of(doc, event)) do marks.held[o.id] = name end
        shelling(event)
        if event.when == "area" then
            marks.places[#marks.places + 1] = { x = event.place.x, y = event.place.y,
                radius = event.place.radius or Goals.limits().radius.default, trigger = true }
        end
    end
    for i, goal in ipairs(doc.map.objectives) do
        for _, key in ipairs(Goals.EVENTS) do
            for _, o in ipairs(Goals.held(doc, goal, key)) do marks.held[o.id] = "AN EVENT OF OBJECTIVE " .. i end
            shelling(goal[key])
        end
        if goal.type == "reach" then
            marks.places[#marks.places + 1] = { x = goal.x or 0, y = goal.y or 0,
                radius = goal.radius or Goals.limits().radius.default, index = i }
        elseif goal.objects then
            for _, id in ipairs(goal.objects) do marks.by_id[id] = { type = goal.type, index = i } end
        end
    end
    return marks
end

return Goals
