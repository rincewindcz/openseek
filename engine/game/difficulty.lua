-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json   = require "lib.json"
local Config = require "engine.core.config"

-- Difficulty presets over the simulation's difficulty Config keys, after the
-- original's EASY / MEDIUM / HARD option: the level of the enemy damage and
-- fire tables and of the pickup lifetime, and whether medals (MEDIUM up) and fuel / armor (HARD) are only
-- collected by landing on them. The damage, fire rate and aggression
-- multipliers are extra scales, 1.0 in every preset. The presets live in
-- data/difficulty.json; each key stays
-- editable on its own, and Config.difficulty then reads CUSTOM. The keys are
-- replay parameters (Replay.PARAMS), frozen at phase start.
local Difficulty = {}

local DATA_PATH = "data/difficulty.json"

Difficulty.KEYS = {
    "enemy_damage_level", "enemy_damage", "enemy_fire_level", "enemy_fire_rate", "enemy_aggression",
    "pickup_level", "land_for_medals", "land_for_supplies",
}

local LEVELS = { easy = 1, medium = 2, hard = 3 }

-- Index (1..3) into a weapon's enemy_damage table: the original's per-weapon
-- damage on EASY / MEDIUM / HARD.
function Difficulty.damage_level()
    return LEVELS[Config.enemy_damage_level] or 2
end

-- Index (1..3) into the per-difficulty tables of data/enemy_weapons.json: the
-- original's enemy reloads, burst pauses and missile tracking.
function Difficulty.fire_level()
    return LEVELS[Config.enemy_fire_level] or 2
end

-- Index (1..3) into the pickup lifetimes of data/powerups.json: the original
-- leaves a power-up lying longer on the easier levels.
function Difficulty.pickup_level()
    return LEVELS[Config.pickup_level] or 2
end

local presets

local function load_presets()
    if presets then return presets end
    local raw = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    presets = (ok and type(decoded) == "table" and decoded.presets) or {}
    return presets
end

-- Preset rows for the settings page. "custom" is shown when the values match no
-- preset, but is skipped when cycling.
function Difficulty.preset_choices()
    local out = {}
    for _, p in ipairs(load_presets()) do
        out[#out + 1] = { label = p.label, value = p.name }
    end
    out[#out + 1] = { label = "CUSTOM", value = "custom", hidden = true }
    return out
end

function Difficulty.apply_preset(name)
    for _, p in ipairs(load_presets()) do
        if p.name == name then
            for _, key in ipairs(Difficulty.KEYS) do
                if p.values[key] ~= nil then Config[key] = p.values[key] end
            end
            return
        end
    end
end

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-3 end
    return a == b
end

-- The preset the current values match, or "custom".
function Difficulty.match_preset()
    for _, p in ipairs(load_presets()) do
        local match = true
        for _, key in ipairs(Difficulty.KEYS) do
            if not same(p.values[key], Config[key]) then
                match = false
                break
            end
        end
        if match then return p.name end
    end
    return "custom"
end

return Difficulty
