-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local MapFile     = require "engine.game.map_file"
local MapCompiler = require "engine.game.map_compiler"
local Catalog     = require "engine.editor.catalog"

-- Ground cover for a map: the stones, tufts and trees a pack stage scatters by
-- the thousand, laid over the map at that stage's own densities. Editor side
-- only: positions come from math.random, and the result is ordinary objects.
local Generate = {}

local CLUTTER_KINDS = { scenery = true, tree = true }

-- The classes a stage scatters, most used first: { class, kind_name, sprite, uses }.
function Generate.clutter(stage_name)
    local pack = MapCompiler.pack_stage(stage_name)
    local out  = {}
    if not pack then return out end
    local min_uses = Catalog.data().ground.min_uses
    for index, uses in pairs(pack.uses) do
        local cls = pack.classes[index + 1]
        if CLUTTER_KINDS[cls.kind_name] and cls.render and uses >= min_uses then
            out[#out + 1] = { class = index, kind_name = cls.kind_name, uses = uses,
                              sprite = MapCompiler.asset_stem(pack, cls) }
        end
    end
    table.sort(out, function(a, b) return a.uses > b.uses end)
    return out
end

-- The stage whose clutter covers each ground, by art digit: stage_name for
-- the map's own art set and, with by_ground, the first stage of every other
-- art set its terrain lays (false when the pack has none).
local function stages_by_ground(doc, stage_name, by_ground)
    local stages = { [doc:art()] = stage_name }
    if by_ground and doc.map.terrain then
        for _, art in pairs(doc.map.terrain.cells) do
            if stages[art] == nil then stages[art] = Catalog.stages(art)[1] or false end
        end
    end
    return stages
end

-- Whether a ground cover object at (x, y) keeps clear of everything that is
-- not ground cover.
local function free_at(doc, x, y, clear)
    local free = true
    doc:each_in(x, y, x, y, clear, function(o)
        if doc:info(o).layer ~= "scenery" then free = false end
    end)
    return free
end

-- Scatter the clutter of stage_name over the map. opts: density (1 = as the
-- stage), trees, scenery (which kinds to lay), by_ground (the ground of
-- another art set gets the clutter of a stage of that art set instead).
-- Spots within the clear radius of anything that is not ground cover stay
-- free. Returns the count added.
function Generate.ground(doc, stage_name, opts)
    local size    = doc:size()
    local clear   = Catalog.data().ground.clear
    local terrain = opts.by_ground and doc.map.terrain
    local objects = {}
    for art, stage in pairs(stages_by_ground(doc, stage_name, opts.by_ground)) do
        local pack = stage and MapCompiler.pack_stage(stage)
        local area = pack and (size * size) / (pack.world_size * pack.world_size) or 0
        for _, item in ipairs(pack and Generate.clutter(stage) or {}) do
            local wanted = (item.kind_name == "tree" and opts.trees) or (item.kind_name == "scenery" and opts.scenery)
            if wanted then
                local t     = doc:intern({ from = stage, class = item.class, sprite = item.sprite })
                local count = math.floor(item.uses * area * (opts.density or 1) + 0.5)
                for _ = 1, count do
                    local x, y = math.random(0, size - 1), math.random(0, size - 1)
                    local free = not terrain or (MapFile.terrain_at(terrain, size, x, y) or doc:art()) == art
                    if free and free_at(doc, x, y, clear) then objects[#objects + 1] = { t = t, x = x, y = y } end
                end
            end
        end
    end
    if #objects == 0 then return 0 end
    doc:begin("GENERATE GROUND")
    doc:add(objects)
    doc:commit()
    return #objects
end

-- The stage whose clutter a ground brush lays on the ground of art: the
-- map's base stage on its own art set, else the first stage of that art set.
function Generate.stage_for(doc, art)
    local base = doc.map.base
    if art == doc:art() and type(base) == "string" and base:match("^stage" .. art .. "%d$") then return base end
    return Catalog.stages(art)[1]
end

-- The clutter of stage as thick as that stage has it over the terrain cells
-- at indices (cell px a side), as new objects for the caller to add.
function Generate.cells(doc, stage, indices, cell)
    local pack = stage and MapCompiler.pack_stage(stage)
    if not pack then return {} end
    local size    = doc:size()
    local n       = MapFile.terrain_side(cell, size)
    local clear   = Catalog.data().ground.clear
    local per_px  = 1 / (pack.world_size * pack.world_size)
    local objects = {}
    for _, item in ipairs(Generate.clutter(stage)) do
        local t = doc:intern({ from = stage, class = item.class, sprite = item.sprite })
        for _, k in ipairs(indices) do
            local x0, y0 = (k - 1) % n * cell, math.floor((k - 1) / n) * cell
            local w, h   = math.min(cell, size - x0), math.min(cell, size - y0)
            local want   = item.uses * w * h * per_px
            local count  = math.floor(want)
            if math.random() < want - count then count = count + 1 end
            for _ = 1, count do
                local x, y = x0 + math.random(0, w - 1), y0 + math.random(0, h - 1)
                if free_at(doc, x, y, clear) then objects[#objects + 1] = { t = t, x = x, y = y } end
            end
        end
    end
    return objects
end

-- Remove every object of the scenery layer.
function Generate.clear(doc)
    local gone = {}
    for _, o in ipairs(doc.map.objects) do
        if doc:info(o).layer == "scenery" then gone[#gone + 1] = o end
    end
    if #gone == 0 then return 0 end
    doc:begin("CLEAR GROUND")
    doc:remove(gone)
    doc:commit()
    return #gone
end

return Generate
