-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local Vehicles    = require "engine.game.vehicles"
local Rng         = require "engine.core.rng"
local InputSource = require "engine.core.input_source"
local Replay      = require "engine.game.replay"
local Difficulty  = require "engine.game.difficulty"
local Score       = require "engine.game.score"
local Sound       = require "engine.game.sound"
local Campaign    = require "engine.game.campaign"
local Records     = require "engine.game.records"
local World       = require "engine.game.world"
local Log         = require "engine.core.log"
local Config      = require "engine.core.config"
local Version     = require "engine.core.version"

-- Shared base for the gameplay scenes (single player, sandbox, co-op split):
-- firing, weapon cycling, landing, the mission-won -> DESTRUCTION STATS
-- sequencing, and the in-game text overlays. Subclasses provide
-- collect_stats() for the stats screen.
local GameplayBase = Class(Scene)

-- The gameplay scenes are the simulation: main.lua steps them at a fixed rate.
GameplayBase.fixed_step = true

-- Whether a phase holds its simulation parameters against options edits
-- (Replay.Hold). Only a scene that exists to show such edits turns it off.
GameplayBase.holds_params = true

-- Activate the stage's weather (World.env: snow on the winter world, rain on
-- the jungle world, whatever a map asks for); call from a scene's enter(),
-- and each frame, since a map's event may change it (a no-op when it did
-- not). leave() should clear it with self.app.weather:set(nil).
function GameplayBase:enter_weather()
    self.app.weather:set(self.app.world.env.weather, self.app.world:is_night())
end

-- Centered title in the game's bitmap body font (same as the score readout)
-- over a dimmed screen. No subtitle / key hints: game mode shows game-font
-- text only.
function GameplayBase:draw_overlay_text(title, dim)
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, dim or 0.55)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    local font = self.app.hud:font()
    local s    = 5
    font:print(title, (screen_w - font:width(title, s)) / 2,
        (screen_h - font.line_height * s) / 2, { scale = s })
    g.setColor(1, 1, 1)
end

local ORDER_TIME  = 4.0   -- seconds a map's objective line stays up after it changes
local ORDER_FADE  = 0.6   -- of which the last ones fade it out
local ORDER_SCALE = 3
local SAY_TIME    = 6.0   -- seconds a line of a map's objective event stays up
local SAY_SCALE   = 2
local SAY_WIDTH   = 0.8   -- of the view, before a line is broken
local CLOCK_LOW   = 10    -- seconds left from which the clock blinks
local CLOCK_BLINK = 2     -- times a second

-- Centered lines in the score font (CHARS), stacked down from y.
local function print_lines(font, lines, s, y)
    local screen_w = love.graphics.getWidth()
    for _, ln in ipairs(lines) do
        font:print(ln, (screen_w - font:width(ln, s)) / 2, y, { scale = s })
        y = y + font.line_height * s + 10
    end
end

-- Slow-blinking "MISSION COMPLETE / RETURN TO BASE" once every objective is
-- met and the player only has to fly home (mission state "return_to_base").
-- Uses the score font (CHARS), not the menu ENDCHARS face.
function GameplayBase:draw_return_prompt()
    if math.floor(love.timer.getTime() * 1.5) % 2 ~= 0 then return end
    print_lines(self.app.hud:font(), { "MISSION COMPLETE", "RETURN TO BASE" }, 4,
        love.graphics.getHeight() / 2 - 70)
end

-- An objective was lost for good (mission state "phase_failed"): the original's
-- message over a dimmed screen, until the phase starts over.
function GameplayBase:draw_phase_failed(lines)
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(1, 1, 1)
    print_lines(self.app.hud:font(), lines, 4, screen_h / 2 - 70)
end

-- A standing order of the mission (mission.notice), kept on screen.
function GameplayBase:draw_notice(text)
    print_lines(self.app.hud:font(), { text }, 3, love.graphics.getHeight() * 0.2)
end

-- A line broken into as many as fit the width at a scale.
local function broken(font, text, width, scale)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if line ~= "" and font:width(try, scale) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- The objective at hand on a player-made map (Mission:order), for a moment
-- whenever it changes: a map words objectives the original never had. Over it
-- the phase's clock while one runs, blinking on its last seconds; under it
-- what the map's objective events say (Mission.messages), one after another.
-- Drawn centred in the strip from x, width wide (the window when nil): a view
-- of the split screen calls it with its own.
function GameplayBase:draw_orders(mission, x, width)
    local g    = love.graphics
    local font = self.app.hud:font()
    local now  = love.timer.getTime()
    local text = mission:order()
    if text ~= self.order_text then
        self.order_text, self.order_since = text, now
    end
    if self.said_mission ~= mission then self.said_mission, self.said, self.said_since = mission, 0, now end
    if self.said < #mission.messages and (self.said == 0 or now - self.said_since >= SAY_TIME) then
        self.said, self.said_since = self.said + 1, now
    end
    local screen_w, screen_h = g.getDimensions()
    x     = x or 0
    width = width or screen_w
    local y    = screen_h * 0.2
    local sy   = y + font.line_height * ORDER_SCALE + 14
    local left = text and ORDER_TIME - (now - self.order_since) or 0
    if left > 0 and not mission.notice then
        local color = { 1, 1, 1, math.min(1, left / ORDER_FADE) }
        for i, line in ipairs(broken(font, text, width * SAY_WIDTH, ORDER_SCALE)) do
            local ly = y + (i - 1) * (font.line_height * ORDER_SCALE + 6)
            font:print(line, x + (width - font:width(line, ORDER_SCALE)) / 2, ly,
                { scale = ORDER_SCALE, color = color })
            sy = ly + font.line_height * ORDER_SCALE + 14
        end
    end
    local said = mission.messages[self.said]
    left = said and SAY_TIME - (now - self.said_since) or 0
    if left > 0 then
        for _, line in ipairs(broken(font, said, width * SAY_WIDTH, SAY_SCALE)) do
            font:print(line, x + (width - font:width(line, SAY_SCALE)) / 2, sy,
                { scale = SAY_SCALE, color = { 1, 0.85, 0.3, math.min(1, left / ORDER_FADE) } })
            sy = sy + font.line_height * SAY_SCALE + 6
        end
    end
    local seconds = mission:clock()
    if seconds and (seconds > CLOCK_LOW or math.floor(now * CLOCK_BLINK * 2) % 2 == 0) then
        local total = math.ceil(seconds)
        local clock = string.format("%d:%02d", math.floor(total / 60), total % 60)
        font:print(clock, x + (width - font:width(clock, ORDER_SCALE)) / 2,
            y - font.line_height * ORDER_SCALE - 10, { scale = ORDER_SCALE })
    end
    g.setColor(1, 1, 1)
end

-- Fire p's current weapon if its reload is up and it has ammo. owner stays the
-- literal "player" so projectiles hit enemies (not the other player) regardless
-- of which of the two fired.
function GameplayBase:fire_for(p)
    local combat = self.app.combat
    local weapon_def = combat.weapons[p.weapon_name]
    if not weapon_def then return end
    -- EXTRA (remote_mine): with a mine out, a fresh press of fire sets it off
    -- instead of dropping another.
    if weapon_def.proj_type == "mine" and Config.remote_mine and combat:player_mine(p) then
        if p.fire_released then
            combat:detonate_mines(p)
            p.fire_released = false
            p.fire_timer    = 1.0 / (weapon_def.levels[1].fire_rate or 1)
        end
        return
    end
    if p.fire_timer > 0 then return end
    if not p:has_ammo(p.weapon_name) then
        self.app.world:dry_fire(p)
        return
    end
    local level = weapon_def.levels and weapon_def.levels[p.weapon_level] or weapon_def
    combat:tick_swing("player", p.weapon_name)
    -- The tank's shells fire from its three barrels in turn (weapons flagged
    -- `barrel`), so both the round and its muzzle flash originate at the live
    -- barrel tip, not the turret center. A `barrel` number names one barrel
    -- (the flame thrower's nozzle). The machine gun stays centered.
    local fx, fy = p.x, p.y
    if p.vehicle == "tank" and weapon_def.barrel then
        fx, fy = p:tank_muzzle(tonumber(weapon_def.barrel))
    end
    if combat:fire(fx, fy, p:fire_angle(), p.weapon_name, "player", p.weapon_level, nil, p) == false then
        return
    end
    -- Ammo drains per projectile the shot spawns (rockets fire 2/3/4 by level), not
    -- per trigger pull. Flame weapons spawn ground patches, not rounds, so bill one.
    local shots = 1
    if weapon_def.proj_type ~= "flame" then
        shots = (level.side_offsets and #level.side_offsets) or level.count or 1
    end
    p:consume_ammo(p.weapon_name, (weapon_def.ammo_cost or 1) * shots)
    p.fire_timer = 1.0 / (level.fire_rate or weapon_def.fire_rate or 10)
    p.fire_released = false
end

-- p's selectable weapons: the equip-screen loadout list when one was applied
-- (unique bay weapons in bay order, then the special), else the free-play
-- full list for the vehicle.
function GameplayBase:weapon_list_for(p)
    return p.weapon_list or Vehicles.WEAPONS[p.vehicle] or {}
end

-- The weapon p opens a phase on: the first of its list, the chain gun of bay 1.
-- EXTRA (start_bay_weapon): the vehicle's main bay weapon (the chopper's
-- rockets, the tank's shells) when aboard, else the first other bay weapon in
-- list order, so a player who never finds the weapon switch is not left on the gun.
function GameplayBase:start_weapon(p)
    local weapon_list = self:weapon_list_for(p)
    if not Config.start_bay_weapon then return weapon_list[1] end
    local main = Vehicles.STARTING_WEAPON[p.vehicle]
    local bay  = {}
    for _, name in ipairs(Vehicles.BAY_WEAPONS[p.vehicle] or {}) do bay[name] = name ~= "chaingun" end
    for _, name in ipairs(weapon_list) do
        if name == main then return name end
    end
    for _, name in ipairs(weapon_list) do
        if bay[name] then return name end
    end
    return weapon_list[1]
end

-- Select the i-th weapon of p's list (the number keys, assigned in bay
-- order). A loadout carries the owned level per weapon; free play starts
-- every weapon at level 1 (E cycles it).
function GameplayBase:select_weapon(p, i)
    local weapon_list = self:weapon_list_for(p)
    local name = weapon_list[i]
    if not name or name == p.weapon_name then return end
    p.weapon_name  = name
    p.weapon_level = p.weapon_levels and p.weapon_levels[name] or 1
    p.fire_timer   = 0
    local def = self.app.combat.weapons[name]
    p.weapon_icon = def and def.icon or 0
    self.app.world:weapon_selected(p)
end

-- A vehicle enters the phase (spawn or respawn): the original's start call,
-- "cleared for takeoff" for the chopper, the tank's own line for the tank.
function GameplayBase:announce_start(p)
    self.app.world:say("voice.phase_start", p.vehicle)
end

-- Count a tick the scene is actually simulating. Called once per update, after
-- the early returns (pause, stats screen) that skip simulation entirely.
function GameplayBase:begin_tick()
    if self.hold then self.hold:enforce() end
    self.app.tick = self.app.tick + 1
end

-- A menu goes up over the phase: it shows and saves the player's own
-- parameters, not the ones the phase holds.
function GameplayBase:suspend()
    if self.hold then self.hold:release() end
end

-- Take this tick's input frame for p from its source and apply the edge actions
-- it carries. Everything the player can do that changes the simulation arrives
-- here, so a recorded frame drives the game exactly like a live key.
function GameplayBase:apply_input(p, source)
    local frame = source:frame(self.app.tick)
    p.frame = frame
    for _, event in ipairs(frame.events) do
        if     event == "takeoff"     then self:toggle_land(p)
        elseif event == "weapon"      then self:cycle_weapon(p)
        elseif event == "god"         then p.unlimited = not p.unlimited
        elseif event == "level"       then self:cycle_weapon_level(p)
        elseif event == "destruct"    then
            if not p.death then p.armor, p.damage_cause = 0, "destruct" end
        elseif event == "pickup_mode" then
            self.app.powerups.easy_mode = not self.app.powerups.easy_mode
        else
            local slot = event:match("^slot:(%d)$")
            if slot then self:select_weapon(p, tonumber(slot)) end
        end
    end
    return frame
end

-- Cycle p's weapon to the next one in its list.
function GameplayBase:cycle_weapon(p)
    local weapon_list = self:weapon_list_for(p)
    if #weapon_list == 0 then return end
    local idx = 1
    for i, w in ipairs(weapon_list) do
        if w == p.weapon_name then idx = i; break end
    end
    self:select_weapon(p, idx % #weapon_list + 1)
end

-- Free-play weapon level cycling. With an equip loadout every weapon is fixed at
-- its owned level, so this does nothing.
function GameplayBase:cycle_weapon_level(p)
    if p.weapon_levels then return end
    local weapon_def = self.app.combat.weapons[p.weapon_name]
    if weapon_def and weapon_def.levels then
        p.weapon_level = p.weapon_level % #weapon_def.levels + 1
    end
end

-- Toggle a flyer between airborne and grounded; no-op for a tank.
function GameplayBase:toggle_land(p)
    if p.land_state == "airborne" then
        p:land()
    elseif p.land_state == "grounded" then
        p:take_off()
    end
end

-- audio: listeners and the engine bed

-- Start a phase's audio. Verification and the self-test fast-forward the
-- simulation, which would fire thousands of events a second, so both run silent.
function GameplayBase:begin_audio()
    local app = self.app
    if not app.sound then return end
    app.sound:set_muted(app.replay_verify or app.audio_mute or false)
end

-- Crossfade to the stage's music: a track named after the stage, then one named
-- after its mission, then a generic one. All optional (see Sound.play_music).
function GameplayBase:enter_music()
    local world = self.app.world
    Sound.play_music(world.stage_name or "", "mission" .. world.env.music, "game")
end

-- Point the sound system at this scene's cameras and run the engine bed.
-- `biases` gives each listener its side of a split screen (-1 left, 1 right);
-- single player passes none.
function GameplayBase:update_audio(players, cameras, biases, dt)
    local sound = self.app.sound
    if not sound then return end
    local listeners = {}
    for i, cam in ipairs(cameras) do
        listeners[i] = { x = cam.x, y = cam.y, angle = cam.angle, bias = biases and biases[i] or 0 }
    end
    sound:set_listeners(listeners)
    sound:update_vehicles(players)
    sound:update_callouts(players, dt or 0, self.mission)
end

-- Nothing in the world is audible any more: drop the listeners so a stray event
-- from a torn-down system cannot play, and stop the engine bed.
function GameplayBase:end_audio()
    local app = self.app
    if not app.sound then return end
    app.sound:clear_listeners()
    app.sound:set_muted(app.audio_mute or false)
end

-- replay: recording, playback and divergence checking

local CHECK_INTERVAL  = 60   -- ticks between state checksums (one per simulated second)
local VERIFY_SCALE    = 20   -- simulated ticks per real tick while verifying a replay
local PHASE_FAIL_HOLD = 3.0  -- seconds the phase-failed message stays before the phase restarts

-- A phase always starts from a pristine stage. Re-entering the game should not
-- inherit the previous run's damage, and a recording is only reproducible if the
-- world it starts from is identical to the one its replay will load.
function GameplayBase:reload_stage()
    local app     = self.app
    local playing = app.replay_play
    local stage   = (playing and playing.header.stage) or app.world.stage_name
    app.world:load(stage)
    app.after_stage_load()
end

-- Leaving a phase: flush the recording, and drop any playback so the next run is
-- live again.
function GameplayBase:end_session()
    self:save_recording()
    if self.hold then self.hold:release() end
    self.hold = nil
    if self.playback then
        self.app.replay_play   = nil
        self.app.replay_verify = false
        self.playback = nil
    end
    self.tick_scale = 1
end

-- Start a phase's randomness and simulation clock. Called before anything rolls
-- (POW counts, heli spawns), so a replayed phase rolls the recorded numbers.
function GameplayBase:seed_phase()
    local app = self.app
    self.playback     = app.replay_play
    self.desync       = nil
    self.desync_parts = nil
    self.drift        = nil
    self.recording    = nil
    -- The phase before (a restart) lets go first, so an options edit made
    -- during it is what this one starts with.
    if self.hold then self.hold:release() end
    self.hold = nil
    if self.playback then
        self.hold = Replay.Hold:new(Replay.decode_map(self.playback.header.params))
        self.seed = self.playback:number("seed", 0)
        self.tick_scale = app.replay_verify and VERIFY_SCALE or 1
    else
        -- A map that sets its own difficulty is played on it, over the player's.
        local own = app.world.stage.mission
        local params = own and own.difficulty and Difficulty.over(Replay.params_now(), own.difficulty) or nil
        if self.holds_params then self.hold = Replay.Hold:new(params) end
        self.seed = Rng.new_seed()
        self.tick_scale = 1
    end
    app.tick = 0
    app.world:reset_rng(self.seed)
end

-- Describe the starting conditions precisely enough to reproduce the run.
function GameplayBase:replay_header(mode, players)
    local app    = self.app
    local header = {
        build   = Replay.build_id(),
        version = Version.string(),
        stage   = app.world.stage_name,
        map     = app.world.stage.map_hash,   -- a player-made map: the file's fingerprint
        mode    = mode,
        seed    = self.seed,
        players = #players,
        params  = Replay.encode_map(Replay.params_now()),
        death   = tostring(app.settings.death_enabled and true or false),
        easy_pickups = tostring(app.powerups.easy_mode and true or false),
        friendly_fire = tostring(app.combat.friendly_fire and true or false),
        coop_lives = self.lives_mode,
    }
    for slot, p in ipairs(players) do
        local key = "player." .. slot .. "."
        header[key .. "vehicle"] = p.vehicle
        header[key .. "skin"]    = p.chopper_skin or 1
        header[key .. "tank"]    = p.tank_skin or 1
        header[key .. "number"]  = p.number or slot
        -- The equip-screen fuel / armor split sets capacities and speed; slider
        -- values are arbitrary floats, so they are written round-trip exact.
        header[key .. "fuel"]    = ("%.17g"):format(p.load_fuel)
        header[key .. "armor"]   = ("%.17g"):format(p.load_armor)
        header[key .. "lives"]   = p.lives or Score.START_LIVES
        -- Score and the bonus-vehicle threshold decide when a spare is handed
        -- out mid-phase, so they are starting conditions, not presentation.
        header[key .. "score"]   = p.score or 0
        header[key .. "bonus"]   = p.next_bonus_life or Score.BONUS_LIFE_STEP
        header[key .. "god"]     = tostring(p.unlimited and true or false)
        header[key .. "weapons"] = Replay.encode_list(p.weapon_list or Vehicles.WEAPONS[p.vehicle])
        if p.weapon_levels then header[key .. "levels"] = Replay.encode_map(p.weapon_levels) end
        header[key .. "ammo"]    = Replay.encode_map(p.ammo)
    end
    return header
end

-- Playback: restore the recorded mode flags before the players are built.
function GameplayBase:apply_replay_settings()
    if not self.playback then return end
    local app, header = self.app, self.playback.header
    app.settings.death_enabled = header.death == "true"
    app.powerups.easy_mode     = header.easy_pickups == "true"
    app.combat.friendly_fire   = header.friendly_fire == "true"
end

-- Playback: restore a recorded player's starting state. Called after the player
-- is built and its ammo seeded, so it wins over the live settings.
function GameplayBase:apply_replay_player(p, slot)
    if not self.playback then return end
    local header = self.playback.header
    local key    = "player." .. slot .. "."
    p.lives           = tonumber(header[key .. "lives"]) or p.lives
    p.score           = tonumber(header[key .. "score"]) or p.score
    p.next_bonus_life = tonumber(header[key .. "bonus"]) or p.next_bonus_life
    p.unlimited       = header[key .. "god"] == "true"
    local fuel, armor = tonumber(header[key .. "fuel"]), tonumber(header[key .. "armor"])
    if fuel and armor then
        p.load_fuel, p.load_armor = fuel, armor
        p:_apply_config()
    end
    local weapons = Replay.decode_list(header[key .. "weapons"])
    if #weapons > 0 then p.weapon_list = weapons end
    local levels = header[key .. "levels"]
    if levels then p.weapon_levels = Replay.decode_map(levels) end
    p.weapon_name  = self:start_weapon(p) or p.weapon_name
    p.weapon_level = p.weapon_levels and p.weapon_levels[p.weapon_name] or 1
    local ammo = Replay.decode_map(header[key .. "ammo"])
    if next(ammo) then p.ammo = ammo end
end

-- The vehicle, chopper skin and tank skin a replay recorded for a slot, or nil
-- when not replaying.
function GameplayBase:replay_vehicle(slot)
    if not self.playback then return nil end
    local key = "player." .. slot .. "."
    return self.playback.header[key .. "vehicle"],
        tonumber(self.playback.header[key .. "skin"]) or 1,
        tonumber(self.playback.header[key .. "tank"]) or 1
end

-- Build one input source per player slot: recorded frames on playback, the live
-- keyboard otherwise. bindings is one key-binding table per slot; devices, when
-- given, lists per slot what else drives that player (touch controls, gamepad,
-- mouse stick).
function GameplayBase:begin_input(mode, players, bindings, devices)
    local app = self.app
    self.sources = {}
    for slot, p in ipairs(players) do p.index = slot end
    if self.playback then
        self.playback:rewind()
        for slot = 1, #players do
            self.sources[slot] = InputSource.Replay:new(self.playback, slot)
        end
    else
        for slot, binding in ipairs(bindings) do
            self.sources[slot] = InputSource.Local:new(binding, devices and devices[slot])
        end
        -- The sandbox edits vehicle parameters live, outside the input frame, so
        -- its runs cannot be replayed and are not recorded.
        if app.record_runs and not self.no_record and not (app.play_return and app.play_return.test) then
            self.recording = Replay:new(self:replay_header(mode, players))
        end
    end
    self.source = self.sources[1]

    local desc = {}
    for slot, p in ipairs(players) do
        desc[slot] = ("P%d %s lives %d score %d"):format(slot, p.vehicle, p.lives or 0, p.score or 0)
    end
    local run = "not recorded"
    if self.playback then
        run = (app.replay_verify and "verifying " or "replaying ") .. tostring(self.playback.path)
    elseif self.recording then
        run = "recording"
    end
    Log.info("game", "%s phase %s, seed %d, %s: %s", mode, app.world.stage_name, self.seed, run,
        table.concat(desc, ", "))
end

-- End of a simulated tick: store this tick's input and a periodic checksum, or on
-- playback compare that checksum and remember the first tick that disagrees.
-- A drift (Replay.is_drift) is counted and played through.
function GameplayBase:tick_replay(players)
    local app  = self.app
    local tick = app.tick
    if self.recording then
        for slot, p in ipairs(players) do
            self.recording:record_input(tick, slot, p.frame)
        end
        if tick % CHECK_INTERVAL == 0 then
            self.recording:record_check(tick,
                Replay.checksum_parts(app.world, players, app.combat))
        end
    elseif self.playback then
        local expected = self.playback:check_for(tick)
        if expected and not self.desync then
            local parts = Replay.checksum_parts(app.world, players, app.combat)
            if parts.all ~= expected.hash then
                local moved = Replay.check_diff(expected, parts)
                if Replay.is_drift(moved) then
                    self.drift = self.drift or { first = tick, count = 0 }
                    self.drift.count = self.drift.count + 1
                else
                    self.desync       = tick
                    self.desync_parts = moved
                end
            end
        end
        if self.desync or tick >= self.playback.length then
            self:finish_playback()
        end
    end
end

-- Write the recording out. Called when the phase ends, however it ends.
function GameplayBase:save_recording()
    if not (self.recording and self.recording.length > 0) then return end
    local path = self.recording:save()
    if path then
        Log.info("replay", "saved %s, %d ticks", path, self.recording.length)
    else
        Log.warn("replay", "failed to save recording")
    end
    if self.app.upload_runs then self.recording:upload() end
    self.recording = nil
end

-- Playback reached its last recorded tick, diverged, or was cut short (the phase
-- ended or the viewer bailed out): report and go back to the replay list the
-- playback was started from (app.replay_return, the dev F4 browser by default).
function GameplayBase:finish_playback(reason)
    local app = self.app
    app.replay_result = {
        ok      = self.desync == nil and reason == nil,
        reason  = reason,
        tick    = app.tick,
        length  = self.playback.length,
        desync  = self.desync,
        parts   = self.desync_parts,
        drift   = self.drift,
        checks  = #self.playback.checks,
        name    = self.playback.path,
    }
    local r = app.replay_result
    if r.desync then
        Log.warn("replay", "%s diverged at tick %d: %s", tostring(r.name), r.desync, table.concat(r.parts or {}, ", "))
    elseif r.ok then
        Log.info("replay", "%s verified, %d ticks", tostring(r.name), r.length)
    else
        Log.info("replay", "%s %s at tick %d of %d", tostring(r.name), r.reason or "ended", r.tick, r.length)
    end
    if r.drift then
        Log.warn("replay", "%s player drifted at %d of %d checkpoints, first at tick %d", tostring(r.name),
            r.drift.count, r.checks, r.drift.first)
    end
    self.playback     = nil
    app.replay_play   = nil
    app.replay_verify = false
    self.tick_scale   = 1
    local back = app.replay_return or "replays"
    app.replay_return = nil
    app.scenes:switch(back)
end

-- A "REPLAY" tag over the game while a recording is being played back, with the
-- tick counter so a divergence report can be lined up with what was on screen.
-- Hidden for a clean picture until T shows it (toggle_replay_tag); always shown
-- while verifying.
function GameplayBase:toggle_replay_tag()
    self.app.replay_tag = not self.app.replay_tag
end

function GameplayBase:draw_replay_tag()
    if not self.playback then return end
    if not (self.app.replay_tag or self.app.replay_verify) then return end
    local g = love.graphics
    local text = string.format("REPLAY  %d / %d%s%s", self.app.tick, self.playback.length,
        self.app.replay_verify and "  (verifying)" or "",
        self.drift and ("  drift from " .. self.drift.first) or "")
    local w = g.getFont():getWidth(text) + 16
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", g.getWidth() / 2 - w / 2, 4, w, 20, 3)
    g.setColor(1, 0.85, 0.35, 1)
    g.print(text, g.getWidth() / 2 - w / 2 + 8, 7)
    g.setColor(1, 1, 1, 1)
end

-- Mission won: hold MISSION COMPLETE briefly, then start the DESTRUCTION
-- STATS screen from the subclass's collect_stats(). The stats and the phase's
-- simulated time are kept for the campaign's run record (record_phase).
function GameplayBase:update_won(dt)
    local mission = self.mission
    if not (mission and mission.state == "won") then return end
    if self.won_timer == nil then
        self.won_timer = 1.5
        Log.info("game", "mission complete: %s", self.app.world.stage_name)
    end
    if self.won_timer > 0 then
        self.won_timer = self.won_timer - dt
    elseif not self.end_stats_started then
        self.phase_stats = self:collect_stats()
        self.phase_time  = self.app.world.time
        self.app.end_stats:start(self.phase_stats)
        self.end_stats_started = true
    end
end

-- Phase failed: hold the message, then hand over to the subclass's
-- on_phase_failed() (a vehicle spent and the phase over again, or game over).
-- Returns true on the tick it hands over: the scene may have started the phase
-- again, so the caller drops the rest of its update.
function GameplayBase:update_phase_failed(dt)
    local mission = self.mission
    if not (mission and mission.state == "phase_failed") or self.phase_fail_handled then return false end
    self.fail_timer = (self.fail_timer or PHASE_FAIL_HOLD) - dt
    if self.fail_timer > 0 then return false end
    self.phase_fail_handled = true
    if self.playback then
        self:finish_playback("phase failed")
    else
        self:on_phase_failed()
    end
    return true
end

function GameplayBase:reset_end_stats()
    self.order_text           = nil
    self.said_mission         = nil
    self.fail_timer           = nil
    self.phase_fail_handled   = false
    self.won_timer            = nil
    self.end_stats_started    = false
    self.phase_stats          = nil
    self.phase_time           = nil
    self.vehicles_lost        = 0
    self.app.end_stats.active = false
end

-- Fold the cleared phase into the campaign run's record.
function GameplayBase:record_phase()
    Campaign.record_phase(self.app, self.phase_stats, self.phase_time, self.vehicles_lost,
        self.app.world.tally)
end

-- The run's trivia for the crash picture (EXTRA crash_stats): this phase's
-- tally and clock on top of what the campaign record holds of earlier phases.
function GameplayBase:crash_stats()
    local world  = self.app.world
    local record = self.app.campaign and self.app.run_record or {}
    local out    = { time = (record.time or 0) + world.time }
    for key, v in pairs(world.tally) do out[key] = (record[key] or 0) + v end
    return out
end

-- A map played from the map list was won: its time and the team's score go
-- to the map's records (engine/game/records.lua) for the difficulty it was
-- played on, with the recording when it is the fastest win. A try from the
-- editor, a playback, a run in god mode and a run not recorded set none.
-- mode is "single" or "coop".
function GameplayBase:record_map_run(mode, players)
    local app  = self.app
    local name = World.map_name(app.world.stage_name)
    local back = app.play_return
    if not name or not back or back.test or self.playback or not self.recording then return end
    local score = 0
    for _, p in ipairs(players) do
        if p.unlimited then return end
        score = score + (p.score or 0)
    end
    local own     = app.world.stage.mission
    local level   = Records.level(own and own.difficulty, self.hold and self.hold.held)
    local seconds = self.phase_time or app.world.time
    local beat    = Records.submit(name, app.world.stage.map_hash, mode, level, seconds, score,
        self.recording:serialize())
    if not beat then return end
    if beat.time and beat.score then
        back.note = "NEW BEST TIME " .. Records.clock(seconds) .. " AND SCORE"
    elseif beat.time then
        back.note = "NEW BEST TIME " .. Records.clock(seconds)
    else
        back.note = "NEW BEST SCORE " .. score
    end
end

-- Leave a phase played on its own for where it was started from: the map
-- list or the editor (app.play_return), else the menu.
function GameplayBase:leave_run()
    local app  = self.app
    local back = app.play_return
    app.play_return = nil
    app.scenes:switch(back and back.scene or "main_menu", back and back.note and { note = back.note } or nil)
end

-- Where to go once the stats screen is dismissed. Base returns to where the
-- phase came from; single-player overrides this to continue a campaign run to
-- the next phase.
function GameplayBase:on_stats_done()
    self:leave_run()
end

-- End-stats key handling: any key (Esc included) steps the screen, snapping the
-- reveal, then the scoring pass, then dismissing it. The handoff via
-- on_stats_done() fires from update() once the screen goes inactive, so the
-- animation always plays out before the scene changes.
function GameplayBase:end_stats_keypressed(_key)
    self.app.end_stats:keypressed()
end

-- Pointer release mirrors the keyboard: step the stats screen.
function GameplayBase:mousereleased(_x, _y)
    if self.app.end_stats:is_active() then
        self.app.end_stats:keypressed()
    end
end

function GameplayBase:wheelmoved(_dx, dy)
    self.app.camera:on_wheel(dy)
end

return GameplayBase
