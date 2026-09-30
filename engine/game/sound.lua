-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

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
    self.voice     = nil  -- { event, group, priority, until_t, source } on the radio
    self:_reset_callouts()
end

function Sound:_reset_callouts()
    self.pilots     = setmetatable({}, { __mode = "k" })   -- player -> callout state
    self.follow_ups = {}   -- { event, left } lines queued behind another
    self.selected_t = nil  -- when a weapon was last selected (announcement guard)
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
    self:_reset_callouts()
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
        variant = opts and opts.variant,
    })
end

-- A non-positional event: UI clicks and anything that belongs to the whole
-- screen rather than a place in the world.
function Sound:emit_flat(event, opts)
    if self.muted then return end
    Audio.play_event(event, opts)
end

-- radio callouts

-- Speak a callout, variant picking its per-vehicle entry. One line holds the
-- radio at a time: a higher-priority line cuts in, and so does a line of the
-- same `group` (a newer weapon announcement replaces the last); anything else
-- is dropped rather than queued, so the channel never runs behind the action.
-- The effects bus ducks for the length of the line. A line with a follow-up in
-- callouts.follow_ups queues it, whether or not it was heard. Returns true when
-- the line was spoken.
function Sound:say(event, variant)
    if self.muted or not Config.voice_callouts then return false end
    local follow = (Audio.callouts().follow_ups or {})[event]
    if follow then self.follow_ups[#self.follow_ups + 1] = { event = follow.event, left = follow.delay } end
    event = Audio.resolve(event, variant)
    if not Audio.event(event) then return false end
    local now      = love.timer.getTime()
    local priority = Audio.event_field(event, "priority", 5)
    local group    = Audio.event_field(event, "group")
    local current  = self.voice
    if current and now < current.until_t and priority <= current.priority
        and not (group and group == current.group) then
        return false
    end
    local src, clip = Audio.play_event(event, { pan = 0 })
    if not src then return false end
    if current and current.source ~= src and now < current.until_t then current.source:stop() end
    local length = Audio.duration(clip)
    self.voice = { event = event, group = group, priority = priority, until_t = now + length, source = src }
    Audio.duck("sfx",    DUCK_AMOUNT, length, DUCK_RELEASE)
    Audio.duck("engine", DUCK_AMOUNT, length, DUCK_RELEASE)
    return true
end

-- callouts
--
-- The original's situational radio lines and warnings (research on SEEK.EXE's
-- sound use), decided here from what the simulation reports through the World
-- forwarders and from the players read after each tick, never fed back.
-- Thresholds and timings are data/audio.json "callouts".

-- A weapon was selected: announce it (the original's weapon1..6 / *.spc), unless
-- another was selected within callouts.select_guard seconds. Also re-arms the
-- empty-trigger call.
function Sound:weapon_selected(p)
    local pilot = self:_pilot(p)
    pilot.dry   = nil
    local now   = love.timer.getTime()
    local guard = Audio.callouts().select_guard or 0.5
    local quiet = self.selected_t == nil or now - self.selected_t >= guard
    self.selected_t = now
    if quiet then self:say("voice.weapon." .. p.weapon_name, p.vehicle) end
end

-- The trigger was pulled on an empty weapon: the reload call, once until the
-- weapon changes.
function Sound:dry_fire(p)
    local pilot = self:_pilot(p)
    if pilot.dry == p.weapon_name then return end
    pilot.dry = p.weapon_name
    self:emit("vehicle.reload", p.x, p.y)
end

-- p is about to collect a fuel or armor pickup: "just in time" when that gauge
-- is critical.
function Sound:pickup_taken(p, kind)
    local c = Audio.callouts()
    if kind == "fuel" and p.max_fuel > 0 and p.fuel / p.max_fuel < (c.fuel_critical or 0) then
        self:say("voice.just_in_time")
    elseif kind == "armor" and p.max_armor > 0 and p.armor / p.max_armor < (c.armor_critical or 0) then
        self:say("voice.just_in_time")
    end
end

-- An enemy helicopter took a player's hit, its health going from before to
-- after (fractions of its maximum): "finish him" when that crosses
-- callouts.finish_him and it still flies.
function Sound:heli_damaged(before, after)
    local mark = Audio.callouts().finish_him or 0
    if after > 0 and before >= mark and after < mark then self:say("voice.finish_him") end
end

function Sound:_pilot(p)
    local pilot = self.pilots[p]
    if not pilot then
        pilot = { warn_t = 0 }
        self.pilots[p] = pilot
    end
    return pilot
end

-- Per-tick callouts from each player's state: the armor half / critical lines
-- (once, re-armed when repaired above the mark), the warning beep every
-- warn_period while fuel or armor is critical, touchdown on the home pad
-- (mission:player_home), and queued follow-up lines.
function Sound:update_callouts(players, dt, mission)
    if self.muted then return end
    local c = Audio.callouts()
    for _, p in ipairs(players) do
        local pilot = self:_pilot(p)
        if p.death then
            pilot.warn_t = 0
        else
            local armor = p.max_armor > 0 and p.armor / p.max_armor or 1
            local fuel  = p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 1
            if armor < (c.armor_half or 0) then
                if not pilot.half then pilot.half = true; self:say("voice.armor_half") end
            else
                pilot.half = nil
            end
            if armor < (c.armor_critical or 0) then
                if not pilot.critical then pilot.critical = true; self:say("voice.armor_critical") end
            else
                pilot.critical = nil
            end
            if armor < (c.armor_critical or 0) or fuel < (c.fuel_critical or 0) then
                pilot.warn_t = pilot.warn_t - dt
                if pilot.warn_t <= 0 then
                    pilot.warn_t = c.warn_period or 0.9
                    self:emit_flat("hud.warning")
                end
            else
                pilot.warn_t = 0
            end
            local grounded = p:is_flyer() and p.land_state == "grounded"
            if grounded and pilot.airborne and mission and mission.home_x and mission:player_home(p) then
                self:say("voice.touchdown")
            end
            pilot.airborne = p:is_flyer() and not grounded
        end
    end
    for i = #self.follow_ups, 1, -1 do
        local f = self.follow_ups[i]
        f.left = f.left - dt
        if f.left <= 0 then
            table.remove(self.follow_ups, i)
            self:say(f.event)
        end
    end
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
