-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json   = require "lib.json"
local Config = require "engine.core.config"
local PostFX = require "engine.game.postfx"

-- Game styles: named sets of the extras and looks (data/styles.json), from
-- CLASSIC, as close to the original as the engine gets, to OVERKILL, every
-- extra on. A style gives a value to each Config key it owns; every key stays
-- editable on its own in the options, and Config.style then reads CUSTOM. The
-- POST FX strengths follow the preset a style names. Difficulty, the game
-- speed, the HUD size and the input devices belong to no style.
local Style = {}

local DATA_PATH = "data/styles.json"

local data

local function load_data()
    if data then return data end
    local raw = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    decoded = (ok and type(decoded) == "table") and decoded or {}
    data = {
        styles   = decoded.styles or {},
        default  = decoded.default,
        preview  = decoded.preview or {},
    }
    return data
end

-- The styles in screen order: { name, label, camo, values }.
function Style.list()
    return load_data().styles
end

-- The style the selection screen starts on.
function Style.default()
    local styles = Style.list()
    return load_data().default or (styles[1] and styles[1].name)
end

-- What the selection screen plays behind its cards: { stage, fade, runs }.
function Style.preview()
    return load_data().preview
end

-- Rows for the settings page. "custom" is shown when the values match no
-- style, but is skipped when cycling.
function Style.choices()
    local out = {}
    for _, s in ipairs(Style.list()) do
        out[#out + 1] = { label = s.label, value = s.name }
    end
    out[#out + 1] = { label = "CUSTOM", value = "custom", hidden = true }
    return out
end

function Style.apply(name)
    for _, s in ipairs(Style.list()) do
        if s.name == name then
            for key, value in pairs(s.values or {}) do Config[key] = value end
            PostFX.apply_preset(Config.postfx_preset)
            Config.style = name
            return
        end
    end
end

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-3 end
    return a == b
end

-- The style the current values match, or "custom".
function Style.match()
    if PostFX.match_preset() ~= Config.postfx_preset then return "custom" end
    for _, s in ipairs(Style.list()) do
        local match = true
        for key, value in pairs(s.values or {}) do
            if not same(value, Config[key]) then
                match = false
                break
            end
        end
        if match then return s.name end
    end
    return "custom"
end

return Style
