-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json   = require "lib.json"
local Config = require "engine.core.config"

-- Difficulty presets over the simulation's difficulty Config keys, after the
-- original's EASY / MEDIUM / HARD option: enemy damage, fire rate and
-- aggression, and whether medals (MEDIUM up) and fuel / armor (HARD) are only
-- collected by landing on them. HARD is the engine's own tuning (every
-- multiplier 1.0). The presets live in data/difficulty.json; each key stays
-- editable on its own, and Config.difficulty then reads CUSTOM. The keys are
-- replay parameters (Replay.PARAMS), frozen at phase start.
local Difficulty = {}

local DATA_PATH = "data/difficulty.json"

Difficulty.KEYS = {
    "enemy_damage", "enemy_fire_rate", "enemy_aggression", "land_for_medals", "land_for_supplies",
}

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
