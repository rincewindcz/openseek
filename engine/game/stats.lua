-- DESTRUCTION STATS categories and stage-wide destructible tallies, shared by
-- the end-of-phase screen (main.lua) and kill crediting (combat.lua).
local Stats = {}

Stats.GROUND_KINDS   = { tank = true, flak_turret = true, soldier = true,
                         soldier_aggressive = true, truck = true }
Stats.BUILDING_KINDS = { structure = true, radar = true }

-- Stats category of an entity kind: "ground", "building", or nil.
function Stats.kind_category(kind)
    if Stats.GROUND_KINDS[kind] then return "ground" end
    if Stats.BUILDING_KINDS[kind] then return "building" end
end

-- Count the stage's destructible ground forces / buildings (total and how many
-- are down), for the DESTRUCTION STATS percentages.
function Stats.destructible_totals(world)
    local classes = world.stage.classes
    local ground_total, ground_down, building_total, building_down = 0, 0, 0, 0
    for _, e in ipairs(world.entities) do
        local cls  = classes[e.class_idx + 1]
        local kind = cls and cls.kind_name
        local destructible = (e.type_data and (e.type_data.hit_radius or 0) > 0)
            or (e.max_hp or 0) > 0
        if destructible then
            if Stats.GROUND_KINDS[kind] then
                ground_total = ground_total + 1
                if not e:is_alive() then ground_down = ground_down + 1 end
            elseif Stats.BUILDING_KINDS[kind] then
                building_total = building_total + 1
                if not e:is_alive() then building_down = building_down + 1 end
            end
        end
    end
    return ground_total, ground_down, building_total, building_down
end

-- 1-based phase number from a stage name like "stage12" (mission 1, phase 2).
function Stats.stage_phase(stage_name)
    return (tonumber((stage_name or ""):match("^stage%d(%d)")) or 0) + 1
end

return Stats
