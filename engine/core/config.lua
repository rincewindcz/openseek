-- Optional compatibility / gameplay tuning shared across systems. The advanced
-- settings page edits a subset of these (see PERSISTED); the F2 debug overlay
-- toggles others live for testing.
local json = require "lib.json"

local Config = {
    -- Render pickups screen-aligned, the way the original engine did (it could not
    -- rotate sprites), instead of rotating them with the world.
    axis_aligned_pickups = false,

    -- Let the player's own fire kill walking POWs during a rescue. Off by default
    -- (only enemy fire harms them); on makes friendly fire a real hazard.
    friendly_fire_pows = false,

    -- Global multiplier on the on-screen HUD (gauges, weapon icon, accel box,
    -- radar): scales each element and its inset from the screen edge, so 1.0 is the
    -- current size and larger values bring it closer to the chunkier DOS original.
    hud_scale = 1.0,

    -- Global multiplier on gameplay motion: movement, turning, projectile and
    -- weapon speeds. Animation playback is deliberately left unscaled so the game
    -- looks identical while playing at a different pace. 1.0 = current/modern
    -- speed; lower values slow the game toward the DOS original.
    speed_scale = 1.0,

    -- End-of-phase DESTRUCTION STATS tally direction. The original counts each
    -- line's percentage / tally down to zero while the bonus drains into TOTAL
    -- SCORE. true builds the values up from zero instead (icons and percentages
    -- rise as the score climbs), which reads more naturally.
    endstats_count_up = true,

    -- Visual effect layer (engine/game/lightfx.lua). effects_flashes toggles the
    -- modern oversaturation layer (muzzle flashes, explosion bursts, full-screen
    -- washes); turn it off for the classic look. flash_intensity scales that
    -- layer's brightness. night_lighting toggles the night light map (headlight
    -- beam + scene darkening); night_brightness lifts the dimmed ambient toward
    -- full daylight (1.0 = as authored per mission, higher = brighter).
    effects_flashes  = true,
    flash_intensity  = 1.0,
    night_lighting   = true,
    night_brightness = 1.0,

    -- Master audio volume (0..1), applied via love.audio.setVolume.
    master_volume = 1.0,

    -- Display: window mode applied via love.window (engine/core/display.lua).
    -- window_size matches a label in Display.SIZES. show_fps draws an FPS counter.
    fullscreen  = false,
    vsync       = true,
    window_size = "1280 x 720",
    show_fps    = false,

    -- EXTRA features: additions absent from the original game, each toggleable so
    -- the classic behavior can be restored. See EXTRA.md. explosive_trees lets the
    -- tank bulldoze through trees (small blast, tiny armor cost) instead of getting
    -- stuck on them; tree_crush_speed is the fraction of top speed the tank must be
    -- moving at for that to happen (slower than this and the tree still blocks).
    explosive_trees  = true,
    tree_crush_speed = 0.7,
}

-- Player-editable keys persisted to the save directory, so the advanced settings
-- survive restarts. Every value is a scalar (boolean / number).
local SAVE_PATH = "data/settings.json"
local PERSISTED = {
    "effects_flashes", "flash_intensity", "night_lighting", "night_brightness",
    "speed_scale", "hud_scale", "axis_aligned_pickups", "friendly_fire_pows",
    "endstats_count_up", "explosive_trees", "tree_crush_speed", "master_volume",
    "fullscreen", "vsync", "window_size", "show_fps",
}

-- Overlay any saved values onto the shipped defaults. Called once at startup.
function Config.load()
    local raw = love.filesystem.read(SAVE_PATH)
    if not raw then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return end
    for _, k in ipairs(PERSISTED) do
        if data[k] ~= nil then Config[k] = data[k] end
    end
end

-- Encode a scalar Config value (boolean / number / string) as JSON.
local function encode_value(v)
    if type(v) == "string" then
        return '"' .. v:gsub('[\\"]', "\\%0") .. '"'
    end
    return tostring(v)
end

-- Persist the editable keys. Only scalars, so the JSON is emitted directly (the
-- bundled json module decodes but does not encode).
function Config.save()
    local parts = {}
    for _, k in ipairs(PERSISTED) do
        parts[#parts + 1] = string.format('  "%s": %s', k, encode_value(Config[k]))
    end
    local encoded = "{\n" .. table.concat(parts, ",\n") .. "\n}\n"
    local dir = SAVE_PATH:match("^(.*)/[^/]+$")
    if dir then love.filesystem.createDirectory(dir) end
    pcall(love.filesystem.write, SAVE_PATH, encoded)
end

return Config
