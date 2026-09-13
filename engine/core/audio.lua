local json = require "lib.json"

-- Sound mixer. Two things live here:
--
--   The clip catalog exported by tools/export_sounds.py (assets/sounds.json:
--   ordered categories of {name, file, label, rate}), which the F10 gallery
--   browses, auditions and re-files.
--
--   The playback mixer: named events from data/audio.json, each mapping to a
--   clip plus its gain, bus, priority and retrigger cooldown. Events play
--   through a per-clip voice pool, so overlapping shots layer instead of cutting
--   each other off, and are mixed through named buses the OPTIONS page scales.
--   Spatialization (which listener, how loud, which side) is decided one layer
--   up in engine/game/sound.lua and arrives here as gain / pan / lowpass.
--
-- A missing catalog or event table is a no-op so the app still runs before the
-- sounds have been exported.
local Audio = {
    _cats    = {},   -- ordered categories for the gallery
    _files   = {},   -- name -> asset path
    _sources = {},   -- name -> love.audio.Source, the gallery's single-shot player
    _last    = nil,  -- name of the most recently played clip

    _events   = {},  -- event name -> def (clip, bus, gain, priority, ...)
    _defaults = {},  -- fields an event def omits
    _data     = {},  -- clip name -> love.sound.SoundData (lazy)
    _pool     = {},  -- clip name -> { love.audio.Source, ... } voice pool (lazy)
    _next     = {},  -- event name -> earliest time it may retrigger
    _duck     = {},  -- bus name -> { amount, until_t, release }

    _bus = { sfx = 1.0, voice = 1.0, engine = 1.0, ui = 1.0, music = 1.0 },

    _music      = nil,   -- { source, track, gain, fade } currently playing
    _music_next = nil,   -- track queued behind a fade-out

    muted = false,   -- hard mute (replay verification, self-test)
}

-- Voices allowed to sound at once, in total and per clip. The caps exist so a
-- cluster explosion or a held trigger cannot exhaust the OpenAL source pool.
local MAX_VOICES      = 28
local MAX_CLIP_VOICES = 4

local MUSIC_FADE = 1.2   -- seconds of crossfade between tracks

function Audio.load(path)
    Audio._cats, Audio._files, Audio._sources, Audio._last = {}, {}, {}, nil
    Audio._data, Audio._pool, Audio._next = {}, {}, {}
    local raw = love.filesystem.read(path)
    if not raw then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return end
    Audio._cats = data
    for _, cat in ipairs(data) do
        for _, item in ipairs(cat.items or {}) do
            Audio._files[item.name] = item.file
        end
    end
end

-- Load the event table: { defaults = {...}, events = { name = {...} } }. Every
-- field an event omits falls back to defaults, then to the code defaults below.
function Audio.load_events(path)
    Audio._events, Audio._defaults = {}, {}
    local raw = love.filesystem.read(path)
    if not raw then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return end
    Audio._defaults = data.defaults or {}
    Audio._events   = data.events   or {}
end

-- Ordered list of { name, title, items = {{name, label, file}, ...} }.
function Audio.categories()
    return Audio._cats
end

-- 1-based index of the category currently holding the named clip, or nil.
function Audio.category_of(name)
    for ci, cat in ipairs(Audio._cats) do
        for _, item in ipairs(cat.items or {}) do
            if item.name == name then return ci end
        end
    end
end

-- Move the named clip into the category at target_index (1-based). Returns true
-- when the clip moved; false if it is missing, already there, or the index is
-- out of range. The gallery re-layouts and can persist with Audio.save.
function Audio.move(name, target_index)
    local target = Audio._cats[target_index]
    if not target then return false end
    for _, cat in ipairs(Audio._cats) do
        for i, item in ipairs(cat.items or {}) do
            if item.name == name then
                if cat == target then return false end
                table.remove(cat.items, i)
                target.items = target.items or {}
                target.items[#target.items + 1] = item
                return true
            end
        end
    end
    return false
end

local function json_string(s)
    return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                      ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

-- Persist the current categorization back to assets/sounds.json, preserving the
-- exported shape (ordered categories of {name, title, items:[{name,file,label,
-- rate}]}). Returns true on success.
function Audio.save(path)
    local out = { "[" }
    local cats = Audio._cats
    for ci, cat in ipairs(cats) do
        out[#out + 1] = "  {"
        out[#out + 1] = '    "name": '  .. json_string(cat.name)  .. ","
        out[#out + 1] = '    "title": ' .. json_string(cat.title) .. ","
        out[#out + 1] = '    "items": ['
        local items = cat.items or {}
        for ii, it in ipairs(items) do
            local parts = {
                '"name": '  .. json_string(it.name),
                '"file": '  .. json_string(it.file),
                '"label": ' .. json_string(it.label),
            }
            if it.rate ~= nil then parts[#parts + 1] = '"rate": ' .. tostring(it.rate) end
            out[#out + 1] = "      { " .. table.concat(parts, ", ") .. " }"
                .. (ii < #items and "," or "")
        end
        out[#out + 1] = "    ]"
        out[#out + 1] = "  }" .. (ci < #cats and "," or "")
    end
    out[#out + 1] = "]"

    local full = love.filesystem.getSource() .. "/" .. path
    local f = io.open(full, "w")
    if not f then return false end
    f:write(table.concat(out, "\n") .. "\n")
    f:close()
    return true
end

-- gallery playback: one source per clip, a repeat restarts it

function Audio.play(name)
    local file = Audio._files[name]
    if not file then return end
    local src = Audio._sources[name]
    if not src then
        local ok, s = pcall(love.audio.newSource, file, "static")
        if not ok then return end
        src = s
        Audio._sources[name] = src
    end
    src:stop()
    src:play()
    Audio._last = name
end

function Audio.last_played()
    return Audio._last
end

-- True while the named clip's source is still sounding.
function Audio.is_playing(name)
    local src = Audio._sources[name]
    return src ~= nil and src:isPlaying()
end

function Audio.stop(name)
    local src = Audio._sources[name]
    if src then src:stop() end
    if Audio._last == name then Audio._last = nil end
end

function Audio.stop_all()
    for _, src in pairs(Audio._sources) do src:stop() end
    for _, pool in pairs(Audio._pool) do
        for _, src in ipairs(pool) do src:stop() end
    end
    Audio._last = nil
end

-- buses and master

-- Master output volume (0..1), the global mixer level for every source.
function Audio.set_master(v)
    love.audio.setVolume(math.max(0, math.min(1, v)))
end

function Audio.set_bus(name, v)
    if Audio._bus[name] == nil then return end
    Audio._bus[name] = math.max(0, math.min(1, v))
end

-- Effective level of a bus: its own volume less any active duck.
function Audio.bus_gain(name)
    local g = Audio._bus[name] or 1
    local d = Audio._duck[name]
    if d then g = g * (1 - d.amount) end
    return g
end

-- Pull a bus down for `hold` seconds, then let it release back over
-- `release` seconds. Used to drop the effects bed under a radio callout.
function Audio.duck(name, amount, hold, release)
    if Audio._bus[name] == nil then return end
    local d = Audio._duck[name]
    local t = love.timer.getTime()
    if d and d.amount > amount and d.until_t > t + hold then return end
    Audio._duck[name] = { amount = amount, until_t = t + hold, release = release or 0.35 }
end

-- voice pool

local function sound_data(clip)
    local data = Audio._data[clip]
    if data ~= nil then return data or nil end
    local file = Audio._files[clip]
    if not file then Audio._data[clip] = false; return nil end
    local ok, d = pcall(love.sound.newSoundData, file)
    Audio._data[clip] = ok and d or false
    return ok and d or nil
end

-- Length of a clip in seconds, or 0 when it is missing.
function Audio.duration(clip)
    local d = sound_data(clip)
    return d and d:getDuration() or 0
end

local function total_playing()
    local n = 0
    for _, pool in pairs(Audio._pool) do
        for _, src in ipairs(pool) do
            if src:isPlaying() then n = n + 1 end
        end
    end
    return n
end

-- A source of `clip` that is free to play: an idle pooled voice, else a fresh
-- clone while under the caps, else the pool's oldest voice (stolen mid-play).
-- Returns nil when the clip cannot be decoded.
local function acquire(clip, max_voices)
    local pool = Audio._pool[clip]
    if not pool then
        local data = sound_data(clip)
        if not data then return nil end
        local ok, src = pcall(love.audio.newSource, data, "static")
        if not ok then Audio._data[clip] = false; return nil end
        pool = { src }
        Audio._pool[clip] = pool
        return src
    end
    for _, src in ipairs(pool) do
        if not src:isPlaying() then return src end
    end
    if #pool < (max_voices or MAX_CLIP_VOICES) and total_playing() < MAX_VOICES then
        local src = pool[1]:clone()
        pool[#pool + 1] = src
        return src
    end
    -- All busy: steal the head of the pool and rotate it to the back, so
    -- consecutive steals cycle through the voices instead of hammering one.
    local src = table.remove(pool, 1)
    pool[#pool + 1] = src
    src:stop()
    return src
end

-- events

local function field(def, key, fallback)
    local v = def[key]
    if v ~= nil then return v end
    v = Audio._defaults[key]
    if v ~= nil then return v end
    return fallback
end

-- Raw definition of an event, or nil when it is not in the table.
function Audio.event(name)
    return Audio._events[name]
end

-- One field of an event, resolved through the table's defaults. Used by the
-- spatial layer for the attenuation range and the callout priority.
function Audio.event_field(name, key, fallback)
    local def = Audio._events[name]
    if not def then return fallback end
    return field(def, key, fallback)
end

-- Play a named event. opts:
--   gain     extra linear gain (spatial attenuation), default 1
--   pan      -1 hard left .. 1 hard right, default 0 (centered)
--   behind   true to place the source behind the listener (a rear cue)
--   lowpass  0..1 high-frequency retention, 1 = unfiltered (distance muffling)
--   pitch    extra pitch multiplier on top of the event's own
--   loop     play as a loop; the caller owns the returned source
-- Returns the playing source, or nil when the event was dropped (muted, unknown,
-- still cooling down, silent, or no voice available).
function Audio.play_event(name, opts)
    if Audio.muted then return nil end
    local def = Audio._events[name]
    if not def then return nil end
    opts = opts or {}

    local now = love.timer.getTime()
    if not opts.loop then
        local cooldown = field(def, "cooldown", 0.03)
        if cooldown > 0 then
            local next_t = Audio._next[name]
            if next_t and now < next_t then return nil end
            Audio._next[name] = now + cooldown
        end
    end

    local gain = (opts.gain or 1) * field(def, "gain", 1)
        * Audio.bus_gain(field(def, "bus", "sfx"))
    if gain <= 0.004 then return nil end

    local src = acquire(def.clip, field(def, "max_voices", MAX_CLIP_VOICES))
    if not src then return nil end

    local var   = field(def, "pitch_var", 0)
    local pitch = (opts.pitch or 1) * field(def, "pitch", 1)
    if var > 0 then pitch = pitch * (1 + (math.random() * 2 - 1) * var) end

    src:stop()
    src:setLooping(opts.loop and true or false)
    src:setVolume(math.min(1, gain))
    src:setPitch(math.max(0.1, pitch))
    Audio.place(src, opts.pan or 0, opts.behind, opts.lowpass)
    src:play()
    return src
end

-- Point a source at a direction relative to the listener. Distance attenuation
-- is done by the caller (so it can stay view independent), so the source sits on
-- the unit sphere with rolloff off and only carries the stereo image: pan across
-- x, front / back on z (OpenAL's listener faces -z).
function Audio.place(src, pan, behind, lowpass)
    pan = math.max(-1, math.min(1, pan or 0))
    local depth = math.sqrt(math.max(0, 1 - pan * pan))
    src:setRelative(true)
    src:setRolloff(0)
    src:setPosition(pan, 0, behind and depth or -depth)
    if lowpass and lowpass < 1 then
        src:setFilter({ type = "lowpass", volume = 1, highgain = math.max(0.05, lowpass) })
    else
        src:setFilter()
    end
end

-- Loops owned by a caller (vehicle engines): the source is created once and
-- kept, so only its gain, pitch and placement change per frame.
function Audio.loop(name)
    local def = Audio._events[name]
    if not def then return nil end
    local data = sound_data(def.clip)
    if not data then return nil end
    local ok, src = pcall(love.audio.newSource, data, "static")
    if not ok then return nil end
    src:setLooping(true)
    return src
end

-- Bus level an owned loop should be scaled by, so callers apply the same
-- mixer rules as one-shot events.
function Audio.event_gain(name)
    local def = Audio._events[name]
    if not def then return 0 end
    return field(def, "gain", 1) * Audio.bus_gain(field(def, "bus", "sfx"))
end

-- music

-- Tracks are optional: any .ogg / .mp3 dropped into assets/music/ becomes
-- available under its bare filename. Nothing ships with the game, so the music
-- bus is silent until the player adds files.
function Audio.music_tracks()
    local out = {}
    local ok, items = pcall(love.filesystem.getDirectoryItems, "assets/music")
    if not ok then return out end
    for _, f in ipairs(items) do
        local name = f:match("^(.+)%.[Oo][Gg][Gg]$") or f:match("^(.+)%.[Mm][Pp]3$")
        if name then out[name] = "assets/music/" .. f end
    end
    return out
end

-- Crossfade to `track` (a bare filename in assets/music/, or nil to fade out).
-- Re-requesting the playing track is a no-op, so a scene can call this on every
-- enter without restarting the music.
function Audio.play_music(track)
    if Audio._music and Audio._music.track == track then
        Audio._music_next = nil
        return
    end
    if not Audio._music then
        if not track then return end
        local path = Audio.music_tracks()[track]
        if not path then return end
        local ok, src = pcall(love.audio.newSource, path, "stream")
        if not ok then return end
        src:setLooping(true)
        src:setVolume(0)
        src:play()
        Audio._music = { source = src, track = track, gain = 0 }
        return
    end
    Audio._music_next = track or false   -- false: fade out and stop
end

function Audio.stop_music()
    if Audio._music then Audio._music.source:stop() end
    Audio._music, Audio._music_next = nil, nil
end

-- Per-frame mixer housekeeping: duck release and the music crossfade. Driven
-- from main.lua with the real frame delta, never the fixed tick.
function Audio.update(dt)
    local now = love.timer.getTime()
    for bus, d in pairs(Audio._duck) do
        if now >= d.until_t then
            d.amount = d.amount - dt / math.max(0.01, d.release)
            if d.amount <= 0 then Audio._duck[bus] = nil end
        end
    end

    local m = Audio._music
    if not m then return end
    local target = Audio._music_next == nil and 1 or 0
    local step   = dt / MUSIC_FADE
    m.gain = math.max(0, math.min(1, m.gain + (target > m.gain and step or -step)))
    m.source:setVolume(m.gain * Audio.bus_gain("music"))
    if Audio._music_next ~= nil and m.gain <= 0 then
        m.source:stop()
        local track = Audio._music_next
        Audio._music, Audio._music_next = nil, nil
        if track then Audio.play_music(track) end
    end
end

return Audio
