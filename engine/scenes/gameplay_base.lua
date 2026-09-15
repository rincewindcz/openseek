local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local Font        = require "engine.core.font"
local Vehicles    = require "engine.game.vehicles"
local Rng         = require "engine.core.rng"
local InputSource = require "engine.core.input_source"
local Replay      = require "engine.game.replay"
local Score       = require "engine.game.score"
local Sound       = require "engine.game.sound"

-- Shared base for the gameplay scenes (single player, sandbox, co-op split):
-- firing, weapon cycling, landing, the mission-won -> DESTRUCTION STATS
-- sequencing, and the in-game text overlays. Subclasses provide
-- collect_stats() for the stats screen.
local GameplayBase = Class(Scene)

-- The gameplay scenes are the simulation: main.lua steps them at a fixed rate.
GameplayBase.fixed_step = true

-- Weather overlay per mission digit (snow on the winter world, rain on the
-- jungle world); other missions run clear.
local WEATHER_FOR_MISSION = { [1] = "snow", [2] = "rain" }

-- Activate the stage's weather; call from a scene's enter(). leave() should
-- clear it with self.app.weather:set(nil).
function GameplayBase:enter_weather()
    local m = tonumber((self.app.world.stage_name or ""):match("^stage(%d)"))
    self.app.weather:set(WEATHER_FOR_MISSION[m])
end

-- Centered title in the game's bitmap body font (same as the score readout)
-- over a dimmed screen. No subtitle / key hints: game mode shows game-font
-- text only.
function GameplayBase:draw_overlay_text(title, dim)
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, dim or 0.55)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    local font = Font.get("chars")
    local s    = 5
    font:print(title, (screen_w - font:width(title, s)) / 2,
        (screen_h - font.line_height * s) / 2, { scale = s })
    g.setColor(1, 1, 1)
end

-- Slow-blinking "MISSION COMPLETE / RETURN TO BASE" once every objective is
-- met and the player only has to fly home (mission state "return_to_base").
-- Uses the score font (CHARS), not the menu ENDCHARS face.
function GameplayBase:draw_return_prompt()
    if math.floor(love.timer.getTime() * 1.5) % 2 ~= 0 then return end
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local font  = Font.get("chars")
    local s     = 4
    local lines = { "MISSION COMPLETE", "RETURN TO BASE" }
    local y     = screen_h / 2 - 70
    for _, ln in ipairs(lines) do
        font:print(ln, (screen_w - font:width(ln, s)) / 2, y, { scale = s })
        y = y + font.line_height * s + 10
    end
end

-- Fire p's current weapon if its reload is up and it has ammo. owner stays the
-- literal "player" so projectiles hit enemies (not the other player) regardless
-- of which of the two fired.
function GameplayBase:fire_for(p)
    local combat = self.app.combat
    local weapon_def = combat.weapons[p.weapon_name]
    if not weapon_def then return end
    if p.fire_timer > 0 then return end
    if not p:has_ammo(p.weapon_name) then return end
    local level = weapon_def.levels and weapon_def.levels[p.weapon_level] or weapon_def
    combat:tick_swing("player", p.weapon_name)
    -- The tank's shells fire from its three barrels in turn, so both the round and
    -- its muzzle flash originate at the live barrel tip, not the turret center. The
    -- machine gun stays centered.
    local fx, fy = p.x, p.y
    if p.vehicle == "tank" and p.weapon_name == "shells" then fx, fy = p:tank_muzzle() end
    combat:fire(fx, fy, p:fire_angle(), p.weapon_name, "player", p.weapon_level, nil, p)
    -- Ammo drains per projectile the shot spawns (rockets fire 2/3/4 by level), not
    -- per trigger pull. Flame weapons spawn ground patches, not rounds, so bill one.
    local shots = 1
    if weapon_def.proj_type ~= "flame" then
        shots = (level.side_offsets and #level.side_offsets) or level.count or 1
    end
    p:consume_ammo(p.weapon_name, (weapon_def.ammo_cost or 1) * shots)
    p.fire_timer = 1.0 / (level.fire_rate or weapon_def.fire_rate or 10)
end

-- p's selectable weapons: the equip-screen loadout list when one was applied
-- (unique bay weapons in bay order, then the special), else the free-play
-- full list for the vehicle.
function GameplayBase:weapon_list_for(p)
    return p.weapon_list or Vehicles.WEAPONS[p.vehicle] or {}
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
end

-- Count a tick the scene is actually simulating. Called once per update, after
-- the early returns (pause, stats screen) that skip simulation entirely.
function GameplayBase:begin_tick()
    self.app.tick = self.app.tick + 1
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
    local stage = self.app.world.stage_name or ""
    Sound.play_music(stage, "mission" .. (stage:match("^stage(%d)") or ""), "game")
end

-- Point the sound system at this scene's cameras and run the engine bed.
-- `biases` gives each listener its side of a split screen (-1 left, 1 right);
-- single player passes none.
function GameplayBase:update_audio(players, cameras, biases)
    local sound = self.app.sound
    if not sound then return end
    local listeners = {}
    for i, cam in ipairs(cameras) do
        listeners[i] = { x = cam.x, y = cam.y, angle = cam.angle, bias = biases and biases[i] or 0 }
    end
    sound:set_listeners(listeners)
    sound:update_vehicles(players)
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

local CHECK_INTERVAL = 60   -- ticks between state checksums (one per simulated second)
local VERIFY_SCALE   = 20   -- simulated ticks per real tick while verifying a replay

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
    self.recording    = nil
    if self.playback then
        self.params = Replay.decode_map(self.playback.header.params)
        Replay.apply_params(self.params)
        self.seed = self.playback:number("seed", 0)
        self.tick_scale = app.replay_verify and VERIFY_SCALE or 1
    else
        self.params = Replay.params_now()
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
        stage   = app.world.stage_name,
        mode    = mode,
        seed    = self.seed,
        players = #players,
        params  = Replay.encode_map(Replay.params_now()),
        death   = tostring(app.settings.death_enabled and true or false),
        easy_pickups = tostring(app.powerups.easy_mode and true or false),
        friendly_fire = tostring(app.combat.friendly_fire and true or false),
    }
    for slot, p in ipairs(players) do
        local key = "player." .. slot .. "."
        header[key .. "vehicle"] = p.vehicle
        header[key .. "skin"]    = p.chopper_skin or 1
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
    local weapons = Replay.decode_list(header[key .. "weapons"])
    if #weapons > 0 then
        p.weapon_list = weapons
        p.weapon_name = weapons[1]
    end
    local levels = header[key .. "levels"]
    if levels then
        p.weapon_levels = Replay.decode_map(levels)
        p.weapon_level  = p.weapon_levels[p.weapon_name] or 1
    end
    local ammo = Replay.decode_map(header[key .. "ammo"])
    if next(ammo) then p.ammo = ammo end
end

-- The vehicle and skin a replay recorded for a slot, or nil when not replaying.
function GameplayBase:replay_vehicle(slot)
    if not self.playback then return nil end
    local key = "player." .. slot .. "."
    return self.playback.header[key .. "vehicle"],
        tonumber(self.playback.header[key .. "skin"]) or 1
end

-- Build one input source per player slot: recorded frames on playback, the live
-- keyboard otherwise. bindings is one key-binding table per slot; touch, when
-- given, also drives slot 1.
function GameplayBase:begin_input(mode, players, bindings, touch)
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
            self.sources[slot] = InputSource.Local:new(binding, slot == 1 and touch or nil)
        end
        -- The sandbox edits vehicle parameters live, outside the input frame, so
        -- its runs cannot be replayed and are not recorded.
        if app.record_runs and not self.no_record then
            self.recording = Replay:new(self:replay_header(mode, players))
        end
    end
    self.source = self.sources[1]
end

-- End of a simulated tick: store this tick's input and a periodic checksum, or on
-- playback compare that checksum and remember the first tick that disagrees.
-- Recorded parameters are re-applied so a live options edit cannot change the run.
function GameplayBase:tick_replay(players)
    local app  = self.app
    local tick = app.tick
    Replay.apply_params(self.params)   -- a live options edit cannot change a run in progress
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
                self.desync = tick
                self.desync_parts = Replay.check_diff(expected, parts)
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
    self.recording:save()
    self.recording = nil
end

-- Playback reached its last recorded tick, diverged, or was cut short (the phase
-- ended or the viewer bailed out): report and go back to the replay list.
function GameplayBase:finish_playback(reason)
    local app = self.app
    app.replay_result = {
        ok      = self.desync == nil and reason == nil,
        reason  = reason,
        tick    = app.tick,
        length  = self.playback.length,
        desync  = self.desync,
        parts   = self.desync_parts,
        name    = self.playback.path,
    }
    self.playback     = nil
    app.replay_play   = nil
    app.replay_verify = false
    self.tick_scale   = 1
    app.scenes:switch("replays")
end

-- A "REPLAY" tag over the game while a recording is being played back, with the
-- tick counter so a divergence report can be lined up with what was on screen.
function GameplayBase:draw_replay_tag()
    if not self.playback then return end
    local g = love.graphics
    local text = string.format("REPLAY  %d / %d%s", self.app.tick, self.playback.length,
        self.app.replay_verify and "  (verifying)" or "")
    local w = g.getFont():getWidth(text) + 16
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", g.getWidth() / 2 - w / 2, 4, w, 20, 3)
    g.setColor(1, 0.85, 0.35, 1)
    g.print(text, g.getWidth() / 2 - w / 2 + 8, 7)
    g.setColor(1, 1, 1, 1)
end

-- Mission won: hold MISSION COMPLETE briefly, then start the DESTRUCTION
-- STATS screen from the subclass's collect_stats().
function GameplayBase:update_won(dt)
    local mission = self.mission
    if not (mission and mission.state == "won") then return end
    if self.won_timer == nil then self.won_timer = 1.5 end
    if self.won_timer > 0 then
        self.won_timer = self.won_timer - dt
    elseif not self.end_stats_started then
        self.app.end_stats:start(self:collect_stats())
        self.end_stats_started = true
    end
end

function GameplayBase:reset_end_stats()
    self.won_timer            = nil
    self.end_stats_started    = false
    self.app.end_stats.active = false
end

-- Where to go once the stats screen is dismissed. Base returns to the menu;
-- single-player overrides this to continue a campaign run to the next phase.
function GameplayBase:on_stats_done()
    self.app.scenes:switch("main_menu")
end

-- End-stats key handling: any key (Esc included) steps the screen, snapping the
-- tally and then starting the reverse count-down close. The handoff via
-- on_stats_done() fires from update() once the close finishes, so the animation
-- always plays out before the scene changes.
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
    local app = self.app
    if not app.renderer.picker and not app.renderer.kind_picker then
        app.camera:on_wheel(dy)
    end
end

return GameplayBase
