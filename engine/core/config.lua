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

    -- Roll the HUD score readout up to a new total instead of snapping to it:
    -- a quick count that eases into the final digits. Presentation only.
    score_count_up = true,

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

    -- Gameplay post-processing (engine/game/postfx.lua): a filmic grade over the
    -- world view, never the HUD. postfx_enabled is the master switch; each
    -- strength (0..1) scales one part of the look defined in data/postfx.json.
    -- postfx_preset names the preset the strengths match ("custom" when none).
    postfx_enabled      = true,
    postfx_preset       = "none",
    postfx_grade        = 0.0,
    postfx_contrast     = 0.0,
    postfx_sharpen      = 0.0,
    postfx_bloom        = 0.0,
    postfx_vignette     = 0.0,
    postfx_grain        = 0.0,
    postfx_soft_shadows = 0.0,

    -- Audio. master_volume is applied via love.audio.setVolume; the five bus
    -- volumes scale their own event category on top of it (engine/core/audio.lua,
    -- buses named in data/audio.json). audio_positional pans world sounds in the
    -- listener's frame and muffles distant ones; off centres everything flat.
    -- coop_split_pan is how far a split-screen half pulls its own sounds toward
    -- its side of the stereo image (0 = purely directional, 1 = hard to its own
    -- side). voice_callouts enables the radio lines.
    master_volume = 1.0,
    sfx_volume    = 1.0,
    voice_volume  = 1.0,
    engine_volume = 0.8,
    ui_volume     = 0.7,
    music_volume  = 0.6,

    audio_positional = true,
    coop_split_pan   = 0.35,
    voice_callouts   = true,

    -- Display: window mode applied via love.window (engine/core/display.lua).
    -- window_size matches a label in Display.SIZES. show_fps draws an FPS counter.
    fullscreen  = false,
    vsync       = true,
    window_size = "1280 x 720",
    show_fps    = false,

    -- EXTRA features: additions absent from the original game, each toggleable so
    -- the classic behavior can be restored. See OVERVIEW.md. explosive_trees lets the
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
    "postfx_enabled", "postfx_preset", "postfx_grade", "postfx_contrast", "postfx_sharpen",
    "postfx_bloom", "postfx_vignette", "postfx_grain", "postfx_soft_shadows",
    "speed_scale", "hud_scale", "axis_aligned_pickups", "friendly_fire_pows",
    "endstats_count_up", "score_count_up", "explosive_trees", "tree_crush_speed",
    "master_volume", "sfx_volume", "voice_volume", "engine_volume", "ui_volume",
    "music_volume", "audio_positional", "coop_split_pan", "voice_callouts",
    "fullscreen", "vsync", "window_size", "show_fps",
}

-- Overlay any saved values onto the shipped defaults. Called once at startup.
function Config.load()
    if not love.filesystem.getInfo(SAVE_PATH) then return end
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
