-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json   = require "lib.json"
local Log    = require "engine.core.log"
local Assets = require "engine.core.assets"

-- Vehicle catalogue shared by the scenes: the per-vehicle weapon cycles, the
-- equip-screen bays, and the cosmetic variants of each vehicle (chopper skins
-- 1-3, tank camo sets built from the enemy tanks) loaded from
-- data/vehicle_variants.json. A variant whose art is not in the pack (the
-- shareware lacks the missions the later tank sets come from) is left out.
local Vehicles = {}

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

Vehicles.KINDS = { "chopper", "tank" }

-- Variants per vehicle, in picker order; the index is the skin number the
-- config, the co-op settings and the replay header store. A chopper variant
-- selects the CHOP*<skin> sprite sets; a tank variant names its hull and
-- turret clips, their pivots (art px, nil = art center) and the barrel tips
-- ({ lateral, forward } art px from the turret pivot) shells leave from. camo
-- is the VSELECT strip (1-4) the select screen dresses the variant in.
local variants = {
    chopper = {
        { name = "GREEN",  camo = 2 },
        { name = "ARCTIC", camo = 3 },
        { name = "DESERT", camo = 1 },
    },
    tank = {
        { name = "GREEN", camo = 2, hull = "tankbgrn", turret = "tanktop",
          barrels = { { -4.5, 15 }, { -0.5, 15 }, { 3.5, 15 } } },
    },
}

local VARIANTS_PATH   = "data/vehicle_variants.json"
local ANIMATIONS_PATH = "data/animations.json"
local loaded          = false

-- The clips a variant draws: its chopper sprite set or its tank hull and turret.
local function variant_clips(kind, skin, v)
    if kind == "chopper" then return { "choppit" .. skin } end
    return { v.hull, v.turret }
end

-- Runs before Animation.load (the options page builds its choices at require
-- time), so the clip frames are checked in the definitions directly.
local function drop_missing(kind, clips)
    local kept = {}
    for skin, v in ipairs(variants[kind]) do
        local present = true
        for _, name in ipairs(variant_clips(kind, skin, v)) do
            local def = clips[name]
            if not (def and def.frames and def.frames[1] and Assets.exists(def.frames[1])) then
                present = false
            end
        end
        if present or skin == 1 then
            kept[#kept + 1] = v
        else
            Log.info("vehicles", "%s variant %s not in the game data", kind, v.name)
        end
    end
    variants[kind] = kept
end

-- Read the variant file on first use, so tables built at require time (the
-- options page choices) already see it. Without it the built-ins stay.
local function ensure_loaded()
    if loaded then return end
    loaded = true
    local raw = love.filesystem.getInfo(VARIANTS_PATH) and love.filesystem.read(VARIANTS_PATH)
    if not raw then
        Log.warn("vehicles", "missing %s, built-in variants only", VARIANTS_PATH)
        return
    end
    local data = json.decode(raw)
    for _, kind in ipairs(Vehicles.KINDS) do
        if type(data[kind]) == "table" and #data[kind] > 0 then variants[kind] = data[kind] end
    end
    local defs = love.filesystem.getInfo(ANIMATIONS_PATH) and love.filesystem.read(ANIMATIONS_PATH)
    local clips = defs and json.decode(defs) or {}
    for _, kind in ipairs(Vehicles.KINDS) do drop_missing(kind, clips) end
end

function Vehicles.variant_count(vehicle)
    ensure_loaded()
    return #(variants[vehicle] or variants.chopper)
end

-- A vehicle's variant def; an out-of-range skin (an old replay, a stale
-- settings file) falls back to the first.
function Vehicles.variant(vehicle, skin)
    ensure_loaded()
    local list = variants[vehicle] or variants.chopper
    return list[skin or 1] or list[1]
end

-- skin clamped into the vehicle's variant range.
function Vehicles.clamp_skin(vehicle, skin)
    local n = Vehicles.variant_count(vehicle)
    skin = math.floor(tonumber(skin) or 1)
    if skin < 1 or skin > n then return 1 end
    return skin
end

-- The skin dir steps away from, wrapping around the vehicle's variants.
function Vehicles.step_skin(vehicle, skin, dir)
    local n = Vehicles.variant_count(vehicle)
    return ((Vehicles.clamp_skin(vehicle, skin) - 1 + dir) % n) + 1
end

-- The next (vehicle, skin) pair in the overview's picker cycle: every chopper
-- variant, then every tank variant, then back.
function Vehicles.cycle(vehicle, skin)
    if skin < Vehicles.variant_count(vehicle) then return vehicle, skin + 1 end
    return (vehicle == "tank") and "chopper" or "tank", 1
end

-- Options-screen choices for Config.chopper_skin / Config.tank_skin.
function Vehicles.skin_choices(vehicle)
    local out = {}
    for i = 1, Vehicles.variant_count(vehicle) do
        out[i] = { label = Vehicles.variant(vehicle, i).name, value = i }
    end
    return out
end

-- UI label like "CHOPPER GREEN" / "TANK DESERT".
function Vehicles.label(vehicle, skin)
    return ((vehicle == "tank") and "TANK " or "CHOPPER ") .. Vehicles.variant(vehicle, skin).name
end

return Vehicles
