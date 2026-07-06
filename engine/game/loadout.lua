local Class    = require "engine.core.class"
local Vehicles = require "engine.game.vehicles"

-- Campaign weapon inventory: per vehicle the owned level of every weapon
-- (0 = not owned) and the bay loadout picked on the equip screen. Bay 1
-- always carries the chain gun. Loading several bays with one weapon gives
-- that weapon slot multiplied ammo (the original's rule); number keys are
-- assigned to unique weapons in bay order. One built-in special may be
-- loaded at a time; specials are free and have no levels. The future shop
-- screen purchases into `owned` with medals.
local Loadout = Class()

function Loadout:init()
    self.medals   = 0
    self.vehicle  = "chopper"   -- vehicle picked on the equip screen
    self.vehicles = {}
    for vehicle, n in pairs(Vehicles.BAY_COUNT) do
        local start = Vehicles.STARTING_WEAPON[vehicle]
        local v = {
            owned   = { chaingun = 1, [start] = 1 },
            bays    = { "chaingun" },
            special = nil,
        }
        for i = 2, n do v.bays[i] = start end
        self.vehicles[vehicle] = v
    end
end

-- Owned level of a weapon (0 = not owned).
function Loadout:level(vehicle, weapon)
    return self.vehicles[vehicle].owned[weapon] or 0
end

-- Load bay i with an owned weapon; bay 1 is fixed to the chain gun.
function Loadout:set_bay(vehicle, i, weapon)
    local v = self.vehicles[vehicle]
    if i < 2 or i > #v.bays then return end
    if (v.owned[weapon] or 0) < 1 then return end
    v.bays[i] = weapon
end

-- Toggle the loaded special (picking the loaded one unloads it).
function Loadout:set_special(vehicle, weapon)
    local v = self.vehicles[vehicle]
    v.special = (v.special ~= weapon) and weapon or nil
end

-- Grant / upgrade a weapon (the shop's entry point).
function Loadout:grant(vehicle, weapon, level)
    local v = self.vehicles[vehicle]
    v.owned[weapon] = math.max(v.owned[weapon] or 0, level or 1)
end

-- Own every implemented catalogue weapon at its top level (weapons is the
-- combat weapon table; a weapon without a def stays locked). Used by the
-- single-mission equip screen, which has no shop progression to earn from.
function Loadout:unlock_all(weapons)
    for vehicle in pairs(self.vehicles) do
        for _, list in ipairs({ Vehicles.BAY_WEAPONS[vehicle],
                                Vehicles.SPECIAL_WEAPONS[vehicle] }) do
            for _, weapon in ipairs(list) do
                local def = weapons and weapons[weapon]
                if def then
                    local n = def.levels and #def.levels or 0
                    self:grant(vehicle, weapon, n > 0 and n or 1)
                end
            end
        end
    end
end

-- The gameplay loadout: unique bay weapons in bay order plus the loaded
-- special, each with its bay count as an ammo multiplier and its owned level.
function Loadout:weapon_list(vehicle)
    local v = self.vehicles[vehicle]
    local list, counts, levels = {}, {}, {}
    for _, w in ipairs(v.bays) do
        if counts[w] then
            counts[w] = counts[w] + 1
        else
            counts[w]        = 1
            list[#list + 1]  = w
        end
        levels[w] = v.owned[w] or 1
    end
    if v.special then
        list[#list + 1]   = v.special
        counts[v.special] = 1
        levels[v.special] = 1
    end
    return list, counts, levels
end

return Loadout
