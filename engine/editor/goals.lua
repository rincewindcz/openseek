-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Catalog = require "engine.editor.catalog"

-- The editor's side of a map's objectives (the "objectives" of
-- engine/game/map_file.lua): the rows the map settings list, the changes made
-- to them and what they point at on the map. An entry is never changed in
-- place: every change writes a new list, which is what the undo history keeps.
local Goals = {}

local BASE_FLAG = 0x40   -- class flag of the home base building (World:load)

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

-- What the objectives point at, for the editor to mark: by_id[object id] =
-- { type, index } and places = { { x, y, radius, index } }, index being the
-- objective's place in the list.
function Goals.marks(doc)
    local marks = { by_id = {}, places = {} }
    for i, goal in ipairs(doc.map.objectives) do
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
