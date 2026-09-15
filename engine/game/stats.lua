-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- DESTRUCTION STATS categories and stage-wide destructible tallies, shared by
-- the end-of-phase screen (main.lua) and kill crediting (combat.lua).
--
-- The categories follow the original's death-handler dispatch:
-- ground forces are tanks, turrets and infantry; buildings are flagged
-- structures and trucks. The kind-16 radar is the spinning dish sub-entity and
-- counts for nothing (the 150-point radar.bin is a kind-1 structure).
local Stats = {}

local GROUND_KINDS   = { tank = true, flak_turret = true, soldier = true,
                         soldier_aggressive = true }
local BUILDING_KINDS = { truck = true }

-- Class flag bit that marks a structure as counting toward the destruction
-- tally. Set on most buildings; the classes without it (base1.bin and a few
-- tent / crate variants) are scenery as far as the stats are concerned. Only
-- structures are gated on it: every other counted kind tallies unconditionally.
local TALLY_FLAG = 0x02

-- Bit test without bitwise operators (Lua 5.1 targets have none).
local function has_tally_flag(flags)
    return math.floor((flags or 0) / TALLY_FLAG) % 2 == 1
end

-- Stats category of a stage class: "ground", "building", or nil. Turret tops
-- are ordinary kind-5 classes, so a folded turret classifies as ground here
-- exactly as its standalone entity would.
function Stats.class_category(cls)
    if not cls then return nil end
    if cls.kind_name == "structure" then
        return has_tally_flag(cls.flags) and "building" or nil
    end
    if GROUND_KINDS[cls.kind_name] then return "ground" end
    if BUILDING_KINDS[cls.kind_name] then return "building" end
end

-- Count the stage's destructible ground forces / buildings (total and how many
-- are down), for the DESTRUCTION STATS percentages. A turret folded onto its
-- hull is its own unit here, as it is a separate entity in the original.
function Stats.destructible_totals(world)
    local classes = world.stage.classes
    local ground_total, ground_down, building_total, building_down = 0, 0, 0, 0
    for _, e in ipairs(world.entities) do
        local cls = classes[e.class_idx + 1]
        local cat = Stats.class_category(cls)
        local destructible = (e.type_data and (e.type_data.hit_radius or 0) > 0)
            or (e.max_hp or 0) > 0
        if destructible and cat == "ground" then
            ground_total = ground_total + 1
            if not e:is_alive() then ground_down = ground_down + 1 end
        elseif destructible and cat == "building" then
            building_total = building_total + 1
            if not e:is_alive() then building_down = building_down + 1 end
        end
        if e.has_turret then
            ground_total = ground_total + 1
            if not e.turret_alive then ground_down = ground_down + 1 end
        end
    end
    return ground_total, ground_down, building_total, building_down
end

-- 1-based phase number from a stage name like "stage12" (mission 1, phase 2).
function Stats.stage_phase(stage_name)
    return (tonumber((stage_name or ""):match("^stage%d(%d)")) or 0) + 1
end

return Stats
