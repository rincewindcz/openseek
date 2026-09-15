local Class  = require "engine.core.class"
local Audio  = require "engine.core.audio"
local Config = require "engine.core.config"

-- Directional game audio. Sits on top of the core mixer and answers the one
-- question the mixer cannot: for a bang at a world position, how loud is it and
-- which way is it from the player.
--
-- Listeners. One per active camera, registered by the gameplay scene each tick
-- (single player has one, split-screen co-op two). A world sound is mixed for
-- the listener that hears it best, so an explosion on player 2's side comes
-- through at player 2's distance and from player 2's bearing, and the second
-- listener's much quieter copy is not spent as a voice. Each listener also
-- carries a `bias`, a nudge toward its own half of the screen, so it stays
-- obvious which half a sound belongs to.
--
-- Panning is taken in the listener's rotated frame, which is what the player
-- sees: game mode turns the world so the vehicle faces up, so "left on screen"
-- is left in the mix. Something behind the vehicle is placed behind the
-- listener rather than merely quiet, which reads correctly on headphones.
--
-- Distance uses fixed world units, never the camera zoom or window size, so
-- split screen, a zoomed view and a resized window all hear the same thing.
--
-- Simulation code reaches this through World:sound (the same forwarder pattern
-- as the light emitters); nothing here is ever read back into the simulation.
local Sound = Class()

-- World distance from the listener that spans half the stereo image. Sits near
-- the half-width of the game-zoom viewport, so a sound at the edge of the screen
-- is roughly hard panned.
local PAN_WIDTH = 220

-- High frequencies kept at the far end of a sound's range, when the distance
-- filter is on. Near sounds stay unfiltered.
local FAR_LOWPASS = 0.22

-- Callout ducking: how far the effects bed drops under a radio line, and how
-- long it takes to come back once the line ends.
local DUCK_AMOUNT  = 0.45
local DUCK_RELEASE = 0.4

-- Push the AUDIO settings into the mixer. Called at startup and whenever the
-- OPTIONS page edits one of them.
function Sound.apply_config()
    Audio.set_master(Config.master_volume)
    Audio.set_bus("sfx",    Config.sfx_volume)
    Audio.set_bus("voice",  Config.voice_volume)
    Audio.set_bus("engine", Config.engine_volume)
    Audio.set_bus("ui",     Config.ui_volume)
    Audio.set_bus("music",  Config.music_volume)
end

-- Music is optional content: nothing ships with the game, so the bus stays
-- silent until tracks are dropped into assets/music/. Crossfades to the first
-- of `names` that exists there, and fades out when none of them do, so a scene
-- can name a specific track with a generic fallback behind it.
function Sound.play_music(...)
    local tracks = Audio.music_tracks()
    local names  = { ... }
    for _, name in ipairs(names) do
        if tracks[name] then
            Audio.play_music(name)
            return name
        end
    end
    Audio.play_music(nil)
    return nil
end

function Sound:init(world)
    self.world     = world
    self.listeners = {}
    self.muted     = false
    self.loops     = {}   -- key -> { source, event, gain }
    self.voice     = nil  -- { event, priority, until_t } currently on the radio
end

function Sound:set_world(world)
    self.world = world
end

-- Silence everything and forget the per-frame state. Called when a phase ends
-- and when the simulation is fast-forwarded (replay verification, self-test),
-- where thousands of events would arrive per second.
function Sound:set_muted(muted)
    self.muted   = muted and true or false
    Audio.muted  = self.muted
    if self.muted then self:stop_loops() end
end

-- Register this frame's listeners: { {x, y, angle, bias}, ... }. `angle` is the
-- camera rotation in radians (nil for an unrotated view); `bias` is -1 for a
-- left-hand split-screen half, 1 for a right-hand one, 0 or absent otherwise.
function Sound:set_listeners(list)
    self.listeners = list or {}
end

function Sound:clear_listeners()
    self.listeners = {}
    self:stop_loops()
end

-- Attenuation over distance: full inside min_dist, silent past max_dist, with a
-- slightly convex falloff between so distant fire drops away quickly.
local function attenuate(d, min_dist, max_dist)
    if d <= min_dist then return 1 end
    if d >= max_dist then return 0 end
    local k = (d - min_dist) / (max_dist - min_dist)
    return (1 - k) * (1 - k) * (1 - k * 0.4)
end

-- Best listener for a world point: the one hearing it loudest, with its gain,
-- distance and the delta from it to the source. Returns nil when nobody hears it.
function Sound:_best_listener(x, y, min_dist, max_dist)
    local best, best_gain, best_dx, best_dy, best_d
    for _, l in ipairs(self.listeners) do
        local dx, dy
        if self.world then
            dx, dy = self.world:delta(x, y, l.x, l.y)
        else
            dx, dy = x - l.x, y - l.y
        end
        local d    = math.sqrt(dx * dx + dy * dy)
        local gain = attenuate(d, min_dist, max_dist)
        if gain > 0 and (best_gain == nil or gain > best_gain) then
            best, best_gain, best_dx, best_dy, best_d = l, gain, dx, dy, d
        end
    end
    if not best then return nil end
    return best, best_gain, best_dx, best_dy, best_d
end

-- Stereo placement of a delta in a listener's frame: pan across the screen plus
-- whether the source sits behind the vehicle.
function Sound:_place(listener, dx, dy)
    if not Config.audio_positional then
        return (listener.bias or 0) * Config.coop_split_pan, false
    end
    local a  = listener.angle or 0
    local rx = dx * math.cos(a) - dy * math.sin(a)
    local ry = dx * math.sin(a) + dy * math.cos(a)
    local pan = rx / PAN_WIDTH + (listener.bias or 0) * Config.coop_split_pan
    return math.max(-1, math.min(1, pan)), ry > 0
end

-- Play a world-positioned event. opts: { gain } scales the event's own gain
-- (a bigger blast, a quieter secondary). Silently ignored when the event is
-- unknown, muted, or out of every listener's range.
function Sound:emit(event, x, y, opts)
    if self.muted or #self.listeners == 0 then return end
    local min_dist = Audio.event_field(event, "min_dist", 70)
    local max_dist = Audio.event_field(event, "max_dist", 800)
    local listener, gain, dx, dy, dist = self:_best_listener(x, y, min_dist, max_dist)
    if not listener then return end
    local pan, behind = self:_place(listener, dx, dy)
    local lowpass = 1
    if Config.audio_positional then
        local k = math.min(1, math.max(0, (dist - min_dist) / math.max(1, max_dist - min_dist)))
        lowpass = 1 - (1 - FAR_LOWPASS) * k
    end
    Audio.play_event(event, {
        gain    = gain * ((opts and opts.gain) or 1),
        pan     = pan,
        behind  = behind,
        lowpass = lowpass,
        pitch   = opts and opts.pitch,
    })
end

-- A non-positional event: UI clicks and anything that belongs to the whole
-- screen rather than a place in the world.
function Sound:emit_flat(event, opts)
    if self.muted then return end
    Audio.play_event(event, opts)
end

-- radio callouts

-- Speak a callout. One line holds the radio at a time: a higher-priority line
-- cuts in, an equal or lower one is dropped rather than queued, so the channel
-- never runs behind the action. The effects bus ducks for the length of the
-- line. Returns true when the line was spoken.
function Sound:say(event)
    if self.muted or not Config.voice_callouts then return false end
    local def = Audio.event(event)
    if not def then return false end
    local now      = love.timer.getTime()
    local priority = Audio.event_field(event, "priority", 5)
    local current  = self.voice
    if current and now < current.until_t and priority <= current.priority then return false end
    local src = Audio.play_event(event, { pan = 0 })
    if not src then return false end
    local length = Audio.duration(def.clip)
    self.voice = { event = event, priority = priority, until_t = now + length }
    Audio.duck("sfx",    DUCK_AMOUNT, length, DUCK_RELEASE)
    Audio.duck("engine", DUCK_AMOUNT, length, DUCK_RELEASE)
    return true
end

-- vehicle loops

-- Rotor / engine pitch band. A stationary vehicle idles at the low end and runs
-- up to the high end at top speed.
local PITCH_IDLE = 0.82
local PITCH_FULL = 1.16

function Sound:stop_loops()
    for key, l in pairs(self.loops) do
        l.source:stop()
        self.loops[key] = nil
    end
end

-- Hold one running engine loop per player. Every player is its own listener's
-- vehicle, so the loop is placed by that listener's half bias rather than by
-- distance, and the level is split across the players so two engines do not
-- drown the rest of the mix.
function Sound:update_vehicles(players)
    if self.muted then
        if next(self.loops) then self:stop_loops() end
        return
    end
    local count = math.max(1, #players)
    for i, p in ipairs(players) do
        local key   = "vehicle" .. i
        local event = (p.vehicle == "tank") and "vehicle.tank" or "vehicle.chopper"
        local l     = self.loops[key]
        if l and l.event ~= event then
            l.source:stop()
            l, self.loops[key] = nil, nil
        end
        local level = Audio.event_gain(event) / count
        if p:is_flyer() and p.land_state == "grounded" then level = level * 0.55 end
        local silent = p.death ~= nil or level <= 0.004
        if silent then
            if l then l.source:stop(); self.loops[key] = nil end
        else
            if not l then
                local src = Audio.loop(event)
                if src then
                    l = { source = src, event = event }
                    self.loops[key] = l
                    src:play()
                end
            end
            if l then
                local top   = math.max(1, p.max_fwd or 260)
                local speed = math.min(1, math.abs(p.speed or 0) / top)
                local lift  = p.altitude or 0
                local drive = math.max(speed, p:is_flyer() and lift or 0)
                l.source:setVolume(math.min(1, level))
                l.source:setPitch(PITCH_IDLE + (PITCH_FULL - PITCH_IDLE) * drive)
                local listener = self.listeners[i]
                Audio.place(l.source, listener and (listener.bias or 0) * Config.coop_split_pan or 0)
                if not l.source:isPlaying() then l.source:play() end
            end
        end
    end
    -- A player that left (co-op teardown) keeps no loop behind.
    for key, l in pairs(self.loops) do
        local idx = tonumber(key:match("^vehicle(%d+)$"))
        if idx and idx > #players then
            l.source:stop()
            self.loops[key] = nil
        end
    end
end

return Sound
