-- Vehicle catalogue shared by the scenes: the per-vehicle weapon cycles and
-- the picker that cycles chopper skin 1 -> 2 -> 3 then tank and back.
local Vehicles = {}

Vehicles.CHOPPER_SKINS = 3

-- Weapon lists per vehicle (order determines cycle order). Free-play modes
-- (overview F1, sandbox, co-op) use these full lists; a campaign run builds
-- its list from the equip-screen loadout instead (engine/game/loadout.lua).
Vehicles.WEAPONS = {
    chopper = { "chaingun", "napalm", "rockets", "mega_missile", "air_to_ground", "air_to_air", "bomb" },
    tank    = { "chaingun", "shells" },
}

-- Equip-screen catalogue, matching the original screens: the numbered bays
-- take the bay weapons (bay 1 is always the chain gun), and one built-in
-- special may be loaded at a time. Weapons without a data/weapons.json entry
-- are not implemented yet and show darkened / unselectable.
Vehicles.BAY_COUNT = { chopper = 6, tank = 4 }
Vehicles.BAY_WEAPONS = {
    chopper = { "chaingun", "rockets", "air_to_ground", "air_to_air", "napalm", "air_strike" },
    tank    = { "chaingun", "shells", "napalm", "air_strike" },
}
Vehicles.SPECIAL_WEAPONS = {
    chopper = { "mega_missile", "super_napalm", "bomb" },
    tank    = { "power_shell", "ground_to_air", "mine" },
}
Vehicles.STARTING_WEAPON = { chopper = "rockets", tank = "shells" }

-- The next (vehicle, skin) pair in the picker cycle.
function Vehicles.cycle(vehicle, skin)
    if vehicle == "tank" then return "chopper", 1 end
    if skin < Vehicles.CHOPPER_SKINS then return "chopper", skin + 1 end
    return "tank", skin
end

-- Options-screen choices for Config.chopper_skin.
function Vehicles.skin_choices()
    local out = {}
    for i = 1, Vehicles.CHOPPER_SKINS do
        out[i] = { label = tostring(i), value = i }
    end
    return out
end

-- UI label like "CHOPPER 2" / "TANK".
function Vehicles.label(vehicle, skin)
    if vehicle == "tank" then return "TANK" end
    return skin > 1 and ("CHOPPER " .. skin) or "CHOPPER"
end

return Vehicles
