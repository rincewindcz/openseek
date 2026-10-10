-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class        = require "engine.core.class"
local GameplayBase = require "engine.scenes.gameplay_base"
local Camera       = require "engine.core.camera"
local Player       = require "engine.game.player"
local Mission      = require "engine.game.mission"
local Stats        = require "engine.game.stats"
local Vehicles     = require "engine.game.vehicles"
local Campaign     = require "engine.game.campaign"
local Score        = require "engine.game.score"
local PlayerTag    = require "engine.ui.player_tag"
local CrashFX      = require "engine.ui.crash_fx"
local Log          = require "engine.core.log"
local Config       = require "engine.core.config"
local Input        = require "engine.core.input"
local Gamepad      = require "engine.core.gamepad"

-- Split-screen two-player co-op (extra mode, not in the original game): two
-- players, two cameras, one keyboard and a gamepad for whoever was given one.
-- Each half renders the full world stack through its own camera with the
-- teammate projected in.
--
-- Free play (F7) uses the full weapon lists and the setup screen's god mode
-- toggle. The players can hurt each other when the FRIENDLY FIRE option
-- (Config.friendly_fire_pows) is on, in either mode. A co-op campaign (NEW GAME > LOCAL COOP) plays each player's
-- equip loadout and carries score, lives and medals through the run
-- (engine/game/campaign.lua); a player out of the run is not spawned, and a
-- lone survivor gets the whole screen. Slots (input, replay) are numbered in
-- play order; p.number is the player (colours, keys, HUD label).
local CoopGameplay = Class(GameplayBase)

-- Distinct key sets so both players share one keyboard. fire / weapon /
-- action / radar_zoom are read by the scenes; the movement keys feed
-- Player.controls.
CoopGameplay.P1_CONTROLS = {
    up = "w", down = "s", left = "a", right = "d",
    modifier = "lshift", fire = "lctrl", weapon = "q", action = "e", radar_zoom = "tab",
}
CoopGameplay.P2_CONTROLS = {
    up = "up", down = "down", left = "left", right = "right",
    modifier = "rshift", fire = "rctrl", weapon = "kp0", action = "kpenter", radar_zoom = "kp.",
}

-- Stereo side each half owns, fed to the sound system's listeners.
local SPLIT_BIAS = { -1, 1 }

-- Split the half's two vehicles into the draw layers the single-player scene
-- uses (Gameplay:draw): one on the ground goes in with the world objects, over
-- the flat clutter and under the solid props and the enemy flyers; an airborne
-- one goes above all of that. A tank is always grounded, a chopper only while it
-- sits on its skids. Within a layer the southern (larger y) vehicle is on top,
-- and the returned lists are back-to-front, so both halves agree on the order
-- (the local vehicle is centered, the teammate placed by projection).
local function draw_layers(local_p, remote_p)
    local ground, air = {}, {}
    local layer = local_p:is_airborne() and air or ground
    layer[1] = local_p
    if remote_p then
        layer = remote_p:is_airborne() and air or ground
        layer[#layer + 1] = remote_p
    end
    if #ground == 2 and ground[1].y > ground[2].y then ground[1], ground[2] = ground[2], ground[1] end
    if #air    == 2 and air[1].y    > air[2].y    then air[1],    air[2]    = air[2],    air[1]    end
    return ground, air
end

-- Beat between a wreck finishing and the vehicle being back on the pad. Single
-- player holds its crash picture for the same time before respawning.
local RESPAWN_DELAY = 0.8

function CoopGameplay:make_player(slot, number, sx, sy)
    local app  = self.app
    local coop = app.settings.coop
    local run  = self.run
    local p = Player:new(sx, sy)
    local replay_vehicle, replay_skin, replay_tank = self:replay_vehicle(slot)
    p.number       = number
    p.world_size   = app.world.stage.world_size
    p.vehicle      = replay_vehicle or coop.vehicle[number]
    p.chopper_skin = replay_skin or Vehicles.clamp_skin("chopper", coop.chopper_skin[number])
    p.tank_skin    = replay_tank or Vehicles.clamp_skin("tank", coop.tank_skin[number])
    p.world        = app.world
    p.controls     = (number == 1) and CoopGameplay.P1_CONTROLS or CoopGameplay.P2_CONTROLS
    local def = app.vehicle_defs[p.vehicle]
    if def then p:load_vehicle_def(def) end
    -- A campaign plays the equip-screen snapshot, as single player does.
    local loadout = run and coop.loadout[number]
    if loadout then
        p.weapon_list   = loadout.list
        p.weapon_levels = loadout.levels
        p.weapon_name   = loadout.list[1]
        p.weapon_level  = loadout.levels[p.weapon_name] or 1
        p.load_fuel     = loadout.chars.fuel  * 100
        p.load_armor    = loadout.chars.armor * 100
        p:_apply_config()
    else
        local weapon_list = Vehicles.WEAPONS[p.vehicle]
        if weapon_list then p.weapon_name = weapon_list[1] end
    end
    local weapon_def = app.combat.weapons[p.weapon_name]
    p.weapon_icon = weapon_def and weapon_def.icon or 0
    p:seed_ammo(app.combat.weapons, loadout and loadout.counts)
    if run then
        local state = run.players[number]
        p.score, p.lives, p.next_bonus_life = state.score, state.lives, state.bonus_life
    end
    p.unlimited = (not run) and coop.god or false
    self:apply_replay_player(p, slot)   -- playback: the recorded loadout wins
    return p
end

-- The players this phase spawns, as player numbers in slot order: the recorded
-- ones on playback, the run's remaining players in a campaign, else both.
function CoopGameplay:_numbers()
    if self.playback then
        local out = {}
        for slot = 1, self.playback:number("players", 2) do
            out[slot] = self.playback:number("player." .. slot .. ".number", slot)
        end
        return out
    end
    if self.run then return Campaign.active_players(self.app) end
    return { 1, 2 }
end

-- Shared lives: every player's lives field mirrors one pool. Whatever changed a
-- player's count since the last sync (a spent vehicle, a bonus one) is applied
-- to the pool, and the pool is copied back to all of them.
function CoopGameplay:_sync_lives()
    if self.lives_mode ~= "shared" then return end
    local pool = self.pool
    for i, p in ipairs(self.players) do pool = pool + (p.lives - self.lives_seen[i]) end
    pool = math.max(0, math.min(Score.MAX_LIVES, pool))
    self.pool = pool
    for i, p in ipairs(self.players) do
        p.lives            = pool
        self.lives_seen[i] = pool
    end
end

-- Vehicles player idx still has after spending one: their own count, or on a
-- shared pool what is left once every teammate still in play keeps theirs.
function CoopGameplay:_vehicles_left(idx, p)
    if self.lives_mode ~= "shared" then return p.lives end
    local in_play = 0
    for j = 1, #self.players do
        if j ~= idx and not self.out[j] then in_play = in_play + 1 end
    end
    return p.lives - in_play
end

-- True when no other player is still flying: everyone else is wrecked or out.
function CoopGameplay:_last_in_play(idx)
    for i, p in ipairs(self.players) do
        if i ~= idx and not p.death and not self.out[i] then return false end
    end
    return true
end

function CoopGameplay:_all_out()
    for i = 1, #self.players do
        if not self.out[i] then return false end
    end
    return true
end

function CoopGameplay:enter()
    local app = self.app
    self:reload_stage()   -- a phase starts from a fresh stage (recordings depend on it)
    local world, combat = app.world, app.combat
    self:seed_phase()              -- randomness and clock, before anything rolls
    self:apply_replay_settings()   -- playback: the recorded mode flags
    self.run        = (not self.playback) and Campaign.coop(app) or nil
    self.lives_mode = self.playback and self.playback.header.coop_lives
        or (self.run and self.run.lives_mode) or nil
    self.game_over  = false
    app.viewer_zoom_index = app.camera.zoom_index
    self.paused = false
    self:reset_end_stats()
    app.renderer.in_game = true
    self:enter_weather()
    app.lightfx:enter(world)
    app.impactfx:enter(world)
    app.postfx:enter(world)
    app.tracks:enter(world)
    app.detailfx:enter(world)
    self:begin_audio()
    self:enter_music()
    self.death_timers = {}
    self.out          = {}   -- players who spent their last vehicle

    local sx, sy    = world:player_start()
    local numbers   = self:_numbers()
    local spread    = (#numbers > 1) and 40 or 0
    self.players    = {}
    self.cameras    = {}
    self.lives_seen = {}
    for slot, number in ipairs(numbers) do
        local p = self:make_player(slot, number, sx + (slot * 2 - 3) * spread, sy)
        p.home_x, p.home_y    = sx, sy
        self.players[slot]    = p
        self.cameras[slot]    = Camera:new(world.stage.world_size)
        self.lives_seen[slot] = p.lives
    end
    self.pool = self.players[1] and self.players[1].lives or 0
    for i, p in ipairs(self.players) do
        local c = self.cameras[i]
        c:set_zoom(Camera.GAME_ZOOM_INDEX)
        c:set_game_focus()
        c.x, c.y  = p.x, p.y
        c.angle   = p:camera_angle()
        p.camera  = c
    end
    -- Listeners before the lift-off, so the vehicle loops have somebody to reach.
    self:update_audio(self.players, self.cameras, self:_biases())
    for _, p in ipairs(self.players) do
        p:take_off()   -- choppers lift off; no-op for the tank
        self:announce_start(p)
    end

    -- Each player keeps their keyboard set; one given a pad (the setup screen's
    -- CONTROLS choice) is driven by it as well.
    local pads = Gamepad.assign({ Config.coop_device_1, Config.coop_device_2 })
    local bindings, devices = {}, {}
    self.pad_slot = {}   -- pad number -> player slot
    for slot, p in ipairs(self.players) do
        local pad = pads[p.number]
        bindings[slot] = p.controls
        devices[slot]  = pad and { Gamepad:new(pad) } or {}
        if pad then self.pad_slot[pad] = slot end
    end
    self:begin_input("coop", self.players, bindings, devices)
    for _, p in ipairs(self.players) do p.index = p.number end   -- HUD label follows the player
    combat.players       = self.players
    combat.player        = self.players[1]
    if not self.playback then combat.friendly_fire = Config.friendly_fire_pows end
    combat:reset_phase()
    app.helis:reset()
    app.powerups:set_players(self.players)
    app.rescue:reset()
    app.saboteur:reset()
    -- One shared objective, built by the same rules as single player (the stage's
    -- missions.json def, else its decoded objectives); both players contribute.
    self.mission = Mission.for_stage(world, self.players, world.stage_name)
end

function CoopGameplay:leave()
    local app = self.app
    self:end_session()
    self.paused = false
    self:reset_end_stats()
    app.weather:set(nil)
    app.lightfx:reset()
    app.impactfx:reset()
    app.tracks:reset()
    app.detailfx:reset()
    app.postfx:reset()
    self:end_audio()
    app.renderer.in_game = false
    -- Restore the shared overview camera on every system that was pointed at
    -- a split camera, or the overview renders through a stale half-view.
    app.renderer.camera = app.camera
    app.combat.camera   = app.camera
    app.powerups.camera = app.camera
    app.combat.players       = {}
    app.combat.player        = nil
    app.combat.friendly_fire = false
    app.combat:reset_phase()
    app.helis:clear()
    app.powerups:reset(nil)
    app.rescue:clear()
    app.saboteur:clear()
    app.hud.player = nil
    app.hud.coplayer, app.hud.coplayer_color = nil, nil
    app.hud.view_w, app.hud.view_h = nil, nil
    self.players      = {}
    self.cameras      = {}
    self.death_timers = {}
    self.out          = {}
    self.mission      = nil
    self.run          = nil
    self.lives_mode   = nil
    app.camera.angle   = nil
    app.camera.view_oy = 0
    app.camera:set_zoom(app.viewer_zoom_index)
end

-- Co-op: one column per player from their own attributed kills (combat /
-- enemy_heli credit the shooter's stat_kills), against the shared stage totals.
function CoopGameplay:collect_stats()
    local world = self.app.world
    local ground_total, _gd, building_total = Stats.destructible_totals(world)
    local participants = {}
    for i, p in ipairs(self.players) do
        local k = p.stat_kills or {}
        participants[i] = {
            player    = p,
            color     = PlayerTag.color(p.number),
            ground    = { killed = k.ground or 0,   total = ground_total },
            buildings = { killed = k.building or 0, total = building_total },
            choppers  = k.chopper or 0,
            rescues   = p.pows or 0,
            badges    = p.badges or 0,
        }
    end
    return { phase = Stats.stage_phase(world.stage_name), participants = participants }
end

-- A downed player, on single-player rules: the wreck plays out, a life is spent,
-- and the vehicle is put back on the base pad with the stage's progress intact.
-- Out of vehicles the player stays down; the mission fails once both are (see
-- Mission:_all_dead), so a lone survivor can still finish the phase.
function CoopGameplay:_update_down(idx, p, dt)
    if self.out[idx] or not p:death_done() then return end
    -- Objectives were finished as the vehicle went down: the stats screen is
    -- taking over, so no life is spent (single player does the same). A failed
    -- phase spends its vehicles in on_phase_failed.
    local state = self.mission and self.mission.state
    if state == "won" or state == "phase_failed" then return end
    local t = (self.death_timers[idx] or RESPAWN_DELAY) - dt
    self.death_timers[idx] = t
    if t > 0 then return end
    self.death_timers[idx] = nil
    p.lives = math.max(0, (p.lives or 0) - 1)
    self.vehicles_lost = self.vehicles_lost + 1
    self:_sync_lives()
    if self:_vehicles_left(idx, p) <= 0 then
        self.out[idx] = true
        Log.info("game", "P%d out of vehicles, score %d", p.number, p.score or 0)
        return
    end
    Log.info("game", "P%d vehicle lost, %d left", p.number, p.lives)
    p:respawn(p.home_x or p.x, p.home_y or p.y)
    p:take_off()   -- no-op for the tank
    self:announce_start(p)
    local cam = self.cameras[idx]
    if cam then cam.x, cam.y = p.x, p.y end
    -- Both players were down for a frame but this one had a vehicle left: the
    -- mission is live again, like a single-player respawn.
    if self.mission and self.mission.state == "failed" then self.mission.state = "active" end
end

-- Centered lines inside one split-screen half. GameplayBase:draw_overlay_text works
-- in window space, so it cannot be used under a half's viewport transform.
function CoopGameplay:_half_text(vw, vh, lines, dim)
    local g = love.graphics
    if dim and dim > 0 then
        g.setColor(0, 0, 0, dim)
        g.rectangle("fill", 0, 0, vw, vh)
    end
    local font = self.app.hud:font()
    local s    = 3
    local y    = (vh - #lines * font.line_height * s) / 2
    for _, ln in ipairs(lines) do
        font:print(ln, (vw - font:width(ln, s)) / 2, y, { scale = s })
        y = y + font.line_height * s + 8
    end
    g.setColor(1, 1, 1)
end

-- Per-half status, mirroring the single-player overlays: the blinking
-- return-to-base prompt, a recoverable loss, or game over for a player who has
-- spent every vehicle.
function CoopGameplay:_draw_half_status(idx, p, vw, vh)
    if self.out[idx] then
        self:_half_text(vw, vh, { "GAME OVER" }, 0.55)
    elseif p.death then
        self:_half_text(vw, vh, { p.vehicle == "tank" and "TANK DOWN" or "MAYDAY MAYDAY" }, 0)
    elseif self.mission and self.mission.state == "return_to_base"
        and math.floor(love.timer.getTime() * 1.5) % 2 == 0 then
        -- Parked already: the phase is waiting for the rest of the team.
        if self.mission:player_home(p) then
            self:_half_text(vw, vh, { "MISSION COMPLETE", "WAIT FOR TEAMMATE" }, 0)
        else
            self:_half_text(vw, vh, { "MISSION COMPLETE", "RETURN TO BASE" }, 0)
        end
    end
end

function CoopGameplay:update(dt)
    local app = self.app
    if self.paused then
        if app.sound then app.sound:stop_loops() end
        return
    end
    if app.end_stats:is_active() then
        if app.sound then app.sound:stop_loops() end
        -- The recording stopped when the phase did, so playback is done too.
        if self.playback then self:finish_playback("phase ended"); return end
        app.end_stats:update(dt)
        if app.end_stats:is_active() then
            app.world:update(dt)
        else
            self:on_stats_done()   -- stats screen dismissed: hand off (base -> menu)
        end
        return
    end
    self:begin_tick()
    for i, p in ipairs(self.players) do
        self:apply_input(p, self.sources[i])
        p:update(dt)
        if not p.death then app.combat:crush_units(p) end
        if not p.death and p:_held("fire") then self:fire_for(p) end
        if app.settings.death_enabled and not p.death and p:is_dead() then
            -- Going down on the way home with every objective already met still
            -- completes the phase, as in single player, but only once this was
            -- the last vehicle that could have flown home: while a teammate is
            -- still up, the phase waits for them. Not when the people the phase
            -- was about went down with it (Mission:vehicle_lost).
            if self.mission then self.mission:vehicle_lost(p) end
            if self.mission and self.mission.state == "return_to_base" and self:_last_in_play(i) then
                self.mission.state = "won"
            end
            p:start_death()
        end
        self:_update_down(i, p, dt)
    end
    for i, p in ipairs(self.players) do
        local c = self.cameras[i]
        c.x, c.y = p.x, p.y
        c.angle  = p:camera_angle()
    end
    app.combat:update(dt)
    app.helis:update(dt)
    app.powerups:update(dt)
    app.rescue:update(dt)
    app.saboteur:update(dt)
    if self.mission then self.mission:update(dt) end
    self:update_won(dt)
    if self:update_phase_failed(dt) then return end
    self:_sync_lives()   -- bonus vehicles earned this tick join a shared pool
    if self.run and not self.game_over and self:_all_out() then self:_game_over() end
    app.world:update(dt)
    -- One listener per half, each biased toward its own side of the stereo image
    -- so a blast on the right half is heard on the right (engine/game/sound.lua).
    self:update_audio(self.players, self.cameras, self:_biases(), dt)
    app.weather:update(dt, self.cameras[1])   -- split screen: reacts to player 1's view
    app.lightfx:update(dt)
    app.impactfx:update(dt, self.players)
    app.tracks:update(dt, self.players)
    app.detailfx:update(dt, self.players)
    self:tick_replay(self.players)
end

-- Stereo side per listener: split halves pull to their own side, a lone
-- survivor's full screen stays centred.
function CoopGameplay:_biases()
    return (#self.players > 1) and SPLIT_BIAS or nil
end

-- An objective was lost for good: the failed phase costs a vehicle (each
-- player's own, or one of the shared pool) and starts over with whoever still
-- has one. Free play just starts it over.
function CoopGameplay:on_phase_failed()
    local app = self.app
    if self.run then
        if self.lives_mode == "shared" then
            local p = self.players[1]
            p.lives = math.max(0, p.lives - 1)
            self:_sync_lives()
        end
        for i, p in ipairs(self.players) do
            if not self.out[i] then
                if self.lives_mode ~= "shared" then p.lives = math.max(0, p.lives - 1) end
                if self:_vehicles_left(i, p) <= 0 then self.out[i] = true end
            end
        end
        if self:_all_out() then self:_game_over(); return end
        self:_carry_run(true)
    end
    Log.info("game", "phase failed, restart %s", app.world.stage_name)
    app.scenes:switch("coop_gameplay")
end

-- Fold the phase into the run: scores, lives and thresholds, the medals picked
-- up into each purse, and who is out for the rest of it. A failed phase keeps
-- its medals out of the purses, since it is played again.
function CoopGameplay:_carry_run(failed)
    local run = self.run
    self:_sync_lives()   -- the stats screen's phase bonus may have earned vehicles
    for slot, p in ipairs(self.players) do
        local state      = run.players[p.number]
        state.score      = p.score or 0
        state.lives      = p.lives or 0
        state.bonus_life = p.next_bonus_life or Score.BONUS_LIFE_STEP
        state.out        = self.out[slot] or false
        if not failed then state.loadout.medals = state.loadout.medals + (p.medals or 0) end
    end
    if self.lives_mode == "shared" then
        run.pool = self.pool
        for _, state in ipairs(run.players) do state.lives = self.pool end
    end
end

-- Every player of a campaign run is out of vehicles: the crash picture, then
-- the high-score screen with each player's total.
function CoopGameplay:_game_over()
    local app = self.app
    self.game_over = true
    self:_carry_run()
    Log.info("game", "co-op game over")
    local function finish() Campaign.finish(app) end
    CrashFX.show(app.screen, self.players[#self.players] or {}, true,
        { on_done = finish, on_cancel = finish, stats = self:crash_stats() })
end

-- Stats dismissed: a campaign carries the phase into the run and moves on; free
-- play goes back to the menu.
function CoopGameplay:on_stats_done()
    if not self.run then
        GameplayBase.on_stats_done(self)
        return
    end
    self:_carry_run()
    self:record_phase()
    Campaign.advance(self.app)
end

-- One vehicle in a view: the view's own player is drawn centered by its camera,
-- the teammate is projected into it and ringed with its colour (no ring in a
-- plain view).
function CoopGameplay:_draw_vehicle(pl, local_p, cam, plain)
    if pl == local_p then
        pl:draw()
    else
        pl:draw_remote(love.graphics, cam, not plain and PlayerTag.color(pl.number) or nil)
    end
end

-- Player i's view of the world into the viewport at vx, vw wide and vh tall.
-- plain leaves out the HUD, the status line and the teammate ring (photo mode).
function CoopGameplay:_draw_view(i, vx, vw, vh, plain)
    local app   = self.app
    local g     = love.graphics
    local p     = self.players[i]
    local cam   = self.cameras[i]
    local other = self.players[3 - i]
    cam.vw, cam.vh      = vw, vh
    cam.shake_x, cam.shake_y = app.impactfx:shake_offset(cam.x, cam.y)
    app.renderer.camera = cam
    app.combat.camera   = cam
    app.powerups.camera = cam
    g.push()
    g.translate(vx, 0)
    g.setScissor(vx, 0, vw, vh)
    local ground, air = draw_layers(p, other)
    app.postfx:begin_world(app.impactfx:low_armor(p))
    app.lightfx:begin_scene()
    app.renderer:draw_ground()   -- terrain, decals, craters
    -- People on foot are on the ground with the grounded vehicles, under the
    -- roofs: they come out of a building and go into one.
    app.renderer:draw_objects("under")   -- flat clutter the vehicles sit on
    app.rescue:draw()                    -- land pads + walking POWs
    app.saboteur:draw_ground()           -- agent pads + walking agents
    for _, pl in ipairs(ground) do
        if pl == p then p:draw_world() end   -- smoke behind the local vehicle
        self:_draw_vehicle(pl, p, cam, plain)
        if pl == p then p:draw_world_front() end
    end
    app.renderer:draw_objects("over")    -- trees/buildings
    app.powerups:draw()
    app.renderer:draw_explosions()   -- building blasts over the pickups they drop
    local soft = app.postfx:soft_shadows_active()
    app.postfx:begin_shadows()
    app.helis:draw_shadows(soft) -- aircraft ground shadows, under the flyers
    app.combat.air_strike:draw_shadows(soft)   -- EXTRA (air_strike_fx)
    p:draw_shadow(soft)
    if other then other:draw_remote_shadow(g, cam, soft) end
    if soft then
        p:draw_smoke_shadows()
        app.combat:draw_shadows()
    end
    app.postfx:end_shadows()
    if p:is_airborne() then p:draw_world() end
    app.combat:draw()
    app.renderer:draw_detail_air()   -- muzzle and wreck smoke
    app.renderer:draw_debris()   -- shrapnel above the explosion effects
    app.helis:draw()             -- airborne enemy helicopters
    app.combat.air_strike:draw() -- EXTRA (air_strike_fx): friendly craft and their rounds
    for _, pl in ipairs(air) do self:_draw_vehicle(pl, p, cam, plain) end
    if p:is_airborne() then p:draw_world_front() end
    -- Night light map and flash layer per half, from this half's camera.
    app.lightfx:draw_night(cam)
    app.lightfx:draw_additive(cam)
    app.combat:draw_aim_laser(p)   -- EXTRA (aim_laser)
    app.postfx:end_world(vx, 0, vw, vh)
    if not plain then
        app.hud.player         = p
        app.hud.coplayer       = other
        app.hud.coplayer_color = other and PlayerTag.color(other.number) or nil
        app.hud.view_w, app.hud.view_h = vw, vh
        app.hud:draw()
        self:_draw_half_status(i, p, vw, vh)
    end
    g.setScissor()
    g.pop()
end

-- The camera photo mode (engine/dev/photo_mode.lua) takes over: the first
-- player's, which then fills the window instead of its half.
function CoopGameplay:photo_camera()
    return self.cameras[1]
end

-- The world alone, as one full-window view from the first player's camera with
-- the teammate in it. Photo mode draws only this.
function CoopGameplay:draw_world()
    local w, h = love.graphics.getDimensions()
    self:_draw_view(1, 0, w, h, true)
    self.app.weather:draw()
end

function CoopGameplay:draw()
    local app = self.app
    local g    = love.graphics
    local W, H   = g.getDimensions()
    local n      = #self.players
    local half_w = math.floor(W / math.max(1, n))
    for i = 1, n do
        local vx = (i - 1) * half_w
        self:_draw_view(i, vx, (i == n) and (W - vx) or half_w, H)
    end
    app.weather:draw()   -- full-window overlay across both halves
    if n > 1 then
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", half_w - 1, 0, 2, H)
        g.setColor(1, 1, 1)
    end

    if app.end_stats:is_active() then
        app.end_stats:draw()
    elseif self.mission then
        if self.mission.state == "won" then
            self:draw_overlay_text("MISSION COMPLETE")
        elseif self.mission.state == "phase_failed" then
            self:draw_phase_failed(self.mission.fail_lines)
        elseif self.mission.state == "failed" then
            self:draw_overlay_text("MISSION FAILED")
        elseif self.mission.notice then
            self:draw_notice(self.mission.notice)
        end
    end
    self:draw_replay_tag()
    if self.paused then self:draw_overlay_text("PAUSE") end
end

function CoopGameplay:keypressed(key)
    local app = self.app
    if app.end_stats:is_active() then self:end_stats_keypressed(key); return end
    if key == "escape" then
        if self.playback then self:finish_playback("stopped") else app.scenes:push("main_menu") end
        return
    end
    if key == "p" then self.paused = not self.paused; return end
    for _, p in ipairs(self.players) do
        if key == p.controls.radar_zoom then app.hud:toggle_radar_zoom(p) end
    end
    if self.playback then return end
    if key == "r" and (app.dev or not app.campaign) then
        -- Restart reloads the stage first, like single player, so destroyed
        -- entities and spent objectives come back. A campaign has none (it
        -- would be a free retry), outside a developer run.
        Log.info("game", "restart %s", app.world.stage_name)
        app.world:load(app.world.stage_name)
        app.after_stage_load()
        app.scenes:switch("coop_gameplay")
        return
    end
    -- Developer keys (--dev): god mode and the pickup override.
    if app.dev and key == "f5" then
        app.settings.coop.god = not app.settings.coop.god
        for _, src in ipairs(self.sources) do src:queue("god") end
        return
    end
    if app.dev and key == "f6" then self.sources[1]:queue("pickup_mode"); return end
    for i, p in ipairs(self.players) do
        if key == p.controls.weapon then self.sources[i]:queue("weapon") end
        if key == p.controls.action then self.sources[i]:queue("takeoff") end
    end
end

-- Gamepad buttons: START and the pause button act for everyone, the bound edge
-- actions for the player holding that pad.
function CoopGameplay:padpressed(pad, button, from_stick)
    local app = self.app
    if from_stick then return end
    if app.end_stats:is_active() then self:end_stats_keypressed(button); return end
    if button == Gamepad.MENU_BUTTON then
        if self.playback then self:finish_playback("stopped") else app.scenes:push("main_menu") end
        return
    end
    if Input.pressed("pause", button, "pad") then self.paused = not self.paused; return end
    local slot = self.pad_slot[pad]
    local p    = slot and self.players[slot]
    if not p then return end
    if Input.pressed("radar_zoom", button, "pad") then app.hud:toggle_radar_zoom(p); return end
    if self.playback then return end
    if Input.pressed("weapon", button, "pad")  then self.sources[slot]:queue("weapon") end
    if Input.pressed("takeoff", button, "pad") then self.sources[slot]:queue("takeoff") end
end

return CoopGameplay
