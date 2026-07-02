-- Vehicle catalogue shared by the scenes: the per-vehicle weapon cycles and
-- the picker that cycles chopper skin 1 -> 2 -> 3 then tank and back.
local Vehicles = {}

Vehicles.CHOPPER_SKINS = 3

-- Weapon lists per vehicle (order determines cycle order).
Vehicles.WEAPONS = {
    chopper = { "chaingun", "napalm", "rockets", "mega_missile", "air_to_ground", "air_to_air", "bomb" },
    tank    = { "chaingun", "shells" },
}

-- The next (vehicle, skin) pair in the picker cycle.
function Vehicles.cycle(vehicle, skin)
    if vehicle == "tank" then return "chopper", 1 end
    if skin < Vehicles.CHOPPER_SKINS then return "chopper", skin + 1 end
    return "tank", skin
end

-- UI label like "CHOPPER 2" / "TANK".
function Vehicles.label(vehicle, skin)
    if vehicle == "tank" then return "TANK" end
    return skin > 1 and ("CHOPPER " .. skin) or "CHOPPER"
end

return Vehicles
