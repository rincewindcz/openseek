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
                    if free then
                        doc:each_in(x, y, x, y, clear, function(o)
                            if doc:info(o).layer ~= "scenery" then free = false end
                        end)
                    end
                    if free then objects[#objects + 1] = { t = t, x = x, y = y } end
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
