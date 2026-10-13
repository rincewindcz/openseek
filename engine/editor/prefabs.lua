-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json = require "lib.json"
local Log  = require "engine.core.log"

-- Prefabs: a selection saved under a name (a gun nest, a compound with its
-- roads and patrols) and placed again, on any map. One JSON file each in
-- prefabs/ of the save directory, holding a copy as engine/editor/ops.lua
-- makes it (Ops.copy): items { id, type, dx, dy, route, owner, group }, the
-- routes they drive and the roads, all measured from the prefab's middle.
-- Like a map it holds sprite names and class references, never pixels.
local Prefabs = {}

Prefabs.DIR    = "prefabs"
Prefabs.FORMAT = 1

local NAME_MAX = 40

local listed   -- the list, read once and kept until a prefab is saved or deleted

local function path(name)
    return Prefabs.DIR .. "/" .. name .. ".json"
end

local function file_name(label)
    local stem = (label or ""):lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if stem == "" then stem = "prefab" end
    stem = stem:sub(1, NAME_MAX)
    local name, n = stem, 1
    while love.filesystem.getInfo(path(name)) do
        n    = n + 1
        name = stem .. "_" .. n
    end
    return name
end

local function points_ok(shape)
    if type(shape) ~= "table" or type(shape.points) ~= "table" then return false end
    for _, p in ipairs(shape.points) do
        if type(p) ~= "table" or type(p[1]) ~= "number" or type(p[2]) ~= "number" then return false end
    end
    return true
end

-- A file's text as { label, clip }, or nil for what is no prefab.
function Prefabs.decode(text)
    local ok, data = pcall(json.decode, text)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then return nil end
    if type(data.format) ~= "number" or data.format > Prefabs.FORMAT then return nil end
    local clip = { items = {}, routes = {}, roads = {}, portable = true }
    for _, item in ipairs(data.items) do
        if type(item) ~= "table" or type(item.type) ~= "table" or type(item.id) ~= "number" then return nil end
        clip.items[#clip.items + 1] = { id = item.id, map_type = item.type, dx = tonumber(item.dx) or 0,
            dy = tonumber(item.dy) or 0, route = item.route, owner = item.owner, group = item.group }
    end
    for _, route in ipairs(type(data.routes) == "table" and data.routes or {}) do
        if points_ok(route) and type(route.id) == "number" then clip.routes[#clip.routes + 1] = route end
    end
    for _, road in ipairs(type(data.roads) == "table" and data.roads or {}) do
        if points_ok(road) and type(road.edge) == "table" and type(road.edge[1]) == "table"
        and type(road.edge[2]) == "table" then
            clip.roads[#clip.roads + 1] = road
        end
    end
    if #clip.items == 0 and #clip.roads == 0 then return nil end
    return { label = type(data.name) == "string" and data.name or "PREFAB", clip = clip }
end

function Prefabs.encode(label, clip)
    local items = {}
    for i, item in ipairs(clip.items) do
        items[i] = { id = item.id, type = item.map_type, dx = item.dx, dy = item.dy, route = item.route,
                     owner = item.owner, group = item.group }
    end
    return json.encode({ format = Prefabs.FORMAT, name = label, items = items, routes = clip.routes,
                         roads = clip.roads })
end

-- Every readable prefab: { name (the file's), label, clip }, by label.
function Prefabs.list()
    if listed then return listed end
    listed = {}
    for _, item in ipairs(love.filesystem.getDirectoryItems(Prefabs.DIR)) do
        local name   = item:match("^([a-z0-9][a-z0-9_]*)%.json$")
        local prefab = name and Prefabs.decode(love.filesystem.read(path(name)) or "")
        if prefab then
            prefab.name = name
            listed[#listed + 1] = prefab
        elseif name then
            Log.warn("prefab", "ignoring %s", path(name))
        end
    end
    table.sort(listed, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return a.name < b.name
    end)
    return listed
end

-- Read the folder again the next time the list is asked for.
function Prefabs.refresh()
    listed = nil
end

-- Save a copy (Ops.copy, centred) under a display name. Returns the file's
-- name, or nil when it could not be written.
function Prefabs.save(label, clip)
    love.filesystem.createDirectory(Prefabs.DIR)
    local name    = file_name(label)
    local ok, err = pcall(love.filesystem.write, path(name), Prefabs.encode(label, clip))
    if not ok or err == false then
        Log.warn("prefab", "cannot write %s: %s", path(name), tostring(err))
        return nil
    end
    Log.info("prefab", "saved %s (%d objects, %d roads)", path(name), #clip.items, #clip.roads)
    listed = nil
    return name
end

function Prefabs.delete(name)
    love.filesystem.remove(path(name))
    Log.info("prefab", "deleted %s", path(name))
    listed = nil
end

return Prefabs
