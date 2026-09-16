-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class    = require "engine.core.class"
local Vehicles = require "engine.game.vehicles"

-- Campaign weapon inventory: per vehicle the owned level of every weapon
-- (0 = not owned) and the bay loadout picked on the equip screen. Bay 1
-- always carries the chain gun. Loading several bays with one weapon gives
-- that weapon slot multiplied ammo (the original's rule); number keys are
-- assigned to unique weapons in bay order. Exactly one built-in special is
-- loaded at a time (the vehicle's first by default); specials are free and have
-- no levels. The shop screen
-- (engine/ui/shop_screen.lua) purchases levels into `owned` with medals.
local Loadout = Class()

-- Medal cost to reach weapon level 1 / 2 / 3 (medals are the pickup currency).
Loadout.PRICES = { 2, 4, 6 }

-- Medals a single-mission (MISSION mode) run starts with; a NEW GAME campaign
-- starts at 0 and earns medals from pickups across its phases.
Loadout.START_MEDALS = 16

-- The loadout for the current run: the persistent campaign inventory (NEW GAME,
-- earned from pickups) or the single-mission inventory (MISSION mode, seeded
-- with START_MEDALS). Created on first use; the shop and equip screens share it.
function Loadout.active(app)
    if app.campaign then
        if not app.loadout then app.loadout = Loadout:new() end
        return app.loadout
    end
    if not app.loadout_free then
        app.loadout_free = Loadout:new()
        app.loadout_free.medals = Loadout.START_MEDALS
    end
    return app.loadout_free
end

function Loadout:init()
    self.medals   = 0
    self.vehicle  = "chopper"   -- vehicle picked on the equip screen
    self.vehicles = {}
    for vehicle, n in pairs(Vehicles.BAY_COUNT) do
        local start = Vehicles.STARTING_WEAPON[vehicle]
        local v = {
            owned   = { chaingun = 1, [start] = 1 },
            bays    = { "chaingun" },
            special = Vehicles.SPECIAL_WEAPONS[vehicle][1],
            -- Vehicle characteristics, each 0..1 (0.5 = evenly balanced, the
            -- original's default). Fuel and armor are set on the equip screen;
            -- speed is derived from them (more fuel+armor => slower).
            chars   = { fuel = 0.5, armor = 0.5 },
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

-- Load a special in place of the current one. There is no way to unload it.
function Loadout:set_special(vehicle, weapon)
    self.vehicles[vehicle].special = weapon
end

-- A vehicle characteristic (0..1); "speed" is derived from fuel + armor.
function Loadout:char(vehicle, which)
    local c = self.vehicles[vehicle].chars
    if which == "speed" then return 1 - (c.fuel + c.armor) / 2 end
    return c[which]
end

function Loadout:set_char(vehicle, which, value)
    if which == "speed" then return end   -- read-only (derived)
    self.vehicles[vehicle].chars[which] = math.max(0, math.min(1, value))
end

-- Grant / upgrade a weapon (the shop's entry point).
function Loadout:grant(vehicle, weapon, level)
    local v = self.vehicles[vehicle]
    v.owned[weapon] = math.max(v.owned[weapon] or 0, level or 1)
end

-- Buy a weapon at `level` (higher than currently owned) for PRICES[level] if
-- the purse can afford it. Any level can be bought directly without owning the
-- lower ones first; owning a level implies the lower ones. Spends the medals
-- and returns true on a purchase, false otherwise.
function Loadout:buy(vehicle, weapon, level)
    local price = self.PRICES[level]
    if not price or level <= self:level(vehicle, weapon) or self.medals < price then
        return false
    end
    self.medals = self.medals - price
    self:grant(vehicle, weapon, level)
    return true
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

-- Plain-table copy of the whole inventory, for the save files
-- (engine/game/savegame.lua). Restore rebuilds a Loadout from one, keeping the
-- constructor's defaults for anything an older save is missing.
function Loadout:snapshot()
    local vehicles = {}
    for name, v in pairs(self.vehicles) do
        local owned = {}
        for weapon, level in pairs(v.owned) do owned[weapon] = level end
        local bays = {}
        for i, weapon in ipairs(v.bays) do bays[i] = weapon end
        vehicles[name] = { owned = owned, bays = bays, special = v.special,
                           chars = { fuel = v.chars.fuel, armor = v.chars.armor } }
    end
    return { medals = self.medals, vehicle = self.vehicle, vehicles = vehicles }
end

function Loadout.restore(data)
    local loadout = Loadout:new()
    if type(data) ~= "table" then return loadout end
    loadout.medals  = tonumber(data.medals) or 0
    loadout.vehicle = loadout.vehicles[data.vehicle] and data.vehicle or loadout.vehicle
    for name, saved in pairs(data.vehicles or {}) do
        local v = loadout.vehicles[name]
        if v and type(saved) == "table" then
            for weapon, level in pairs(saved.owned or {}) do
                v.owned[weapon] = tonumber(level) or 0
            end
            for i = 1, #v.bays do
                local weapon = (saved.bays or {})[i]
                if weapon and (v.owned[weapon] or 0) >= 1 then v.bays[i] = weapon end
            end
            if saved.special then v.special = saved.special end
            local chars = saved.chars or {}
            v.chars.fuel  = tonumber(chars.fuel)  or v.chars.fuel
            v.chars.armor = tonumber(chars.armor) or v.chars.armor
        end
    end
    return loadout
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
