-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class        = require "engine.core.class"
local GameplayBase = require "engine.scenes.gameplay_base"
local Camera       = require "engine.core.camera"
local Font         = require "engine.core.font"
local Player       = require "engine.game.player"
local Mission      = require "engine.game.mission"
local Stats        = require "engine.game.stats"
local Vehicles     = require "engine.game.vehicles"

-- Split-screen two-player co-op (extra mode, not in the original game): two
-- players, two cameras, one keyboard. Each half renders the full world stack
-- through its own camera with the teammate projected in.
local CoopGameplay = Class(GameplayBase)

CoopGameplay.COLORS = { { 0.30, 0.65, 1.0 }, { 1.0, 0.55, 0.15 } }  -- P1 blue, P2 orange

-- Distinct key sets so both players share one keyboard. fire / weapon /
-- action are read by the scenes; the movement keys feed Player.controls.
CoopGameplay.P1_CONTROLS = {
    up = "w", down = "s", left = "a", right = "d",
    modifier = "lshift", fire = "lctrl", weapon = "q", action = "e",
}
CoopGameplay.P2_CONTROLS = {
    up = "up", down = "down", left = "left", right = "right",
    modifier = "rshift", fire = "rctrl", weapon = "kp0", action = "kpenter",
}

local COLORS = CoopGameplay.COLORS

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

function CoopGameplay:make_player(idx, sx, sy)
    local app  = self.app
    local coop = app.settings.coop
    local p = Player:new(sx, sy)
    local replay_vehicle, replay_skin = self:replay_vehicle(idx)
    p.world_size   = app.world.stage.world_size
    p.vehicle      = replay_vehicle or coop.vehicle[idx]
    p.chopper_skin = replay_skin or coop.skin[idx]
    p.world        = app.world
    p.controls     = (idx == 1) and CoopGameplay.P1_CONTROLS or CoopGameplay.P2_CONTROLS
    local def = app.vehicle_defs[p.vehicle]
    if def then p:load_vehicle_def(def) end
    local weapon_list = Vehicles.WEAPONS[p.vehicle]
    if weapon_list then p.weapon_name = weapon_list[1] end
    p:seed_ammo(app.combat.weapons)
    p.unlimited = coop.god
    self:apply_replay_player(p, idx)   -- playback: the recorded loadout wins
    return p
end

function CoopGameplay:enter()
    local app = self.app
    self:reload_stage()   -- a phase starts from a fresh stage (recordings depend on it)
    local world, combat = app.world, app.combat
    self:seed_phase()              -- randomness and clock, before anything rolls
    self:apply_replay_settings()   -- playback: the recorded mode flags
    app.viewer_zoom_index = app.camera.zoom_index
    self.paused = false
    self:reset_end_stats()
    app.renderer.in_game = true
    self:enter_weather()
    app.lightfx:enter(world)
    self:begin_audio()
    self:enter_music()
    self.death_timers = {}
    self.out          = {}   -- players who spent their last vehicle

    local sx, sy = world:player_start()
    self.players = {
        self:make_player(1, sx - 40, sy),
        self:make_player(2, sx + 40, sy),
    }
    for _, p in ipairs(self.players) do p.home_x, p.home_y = sx, sy end
    self.cameras = { Camera:new(world.stage.world_size), Camera:new(world.stage.world_size) }
    for i, p in ipairs(self.players) do
        local c = self.cameras[i]
        c:set_zoom(Camera.GAME_ZOOM_INDEX)
        c:set_game_focus()
        c.x, c.y  = p.x, p.y
        c.angle   = p:camera_angle()
        p.camera  = c
    end
    -- Listeners before the lift-off, or the takeoff sound has nobody to reach.
    self:update_audio(self.players, self.cameras, SPLIT_BIAS)
    for _, p in ipairs(self.players) do
        p:take_off()   -- choppers lift off; no-op for the tank
    end

    local coop = app.settings.coop
    self:begin_input("coop", self.players,
        { CoopGameplay.P1_CONTROLS, CoopGameplay.P2_CONTROLS })
    combat.players       = self.players
    combat.player        = self.players[1]
    if not self.playback then combat.friendly_fire = coop.ff end
    combat:reset_phase()
    app.helis:reset()
    app.powerups:set_players(self.players)
    app.rescue.pow_counts = Mission.rescue_counts(world.stage_name)
    app.rescue:reset()
    app.saboteur.spec = Mission.sabotage_spec(world.stage_name)
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
            color     = COLORS[i],
            ground    = { killed = k.ground or 0,   total = ground_total },
            buildings = { killed = k.building or 0, total = building_total },
            choppers  = k.chopper or 0,
            rescues   = p.pows or 0,
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
    -- taking over, so no life is spent (single player does the same).
    if self.mission and self.mission.state == "won" then return end
    local t = (self.death_timers[idx] or RESPAWN_DELAY) - dt
    self.death_timers[idx] = t
    if t > 0 then return end
    self.death_timers[idx] = nil
    p.lives = math.max(0, (p.lives or 0) - 1)
    if p.lives <= 0 then
        self.out[idx] = true
        return
    end
    p:respawn(p.home_x or p.x, p.home_y or p.y)
    p:take_off()   -- no-op for the tank
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
    local font = Font.get("chars")
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
        self:_half_text(vw, vh, { "MISSION COMPLETE", "RETURN TO BASE" }, 0)
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
            self:on_stats_done()   -- reverse close finished: hand off (base -> menu)
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
            -- completes the phase, as in single player.
            if self.mission and self.mission.state == "return_to_base" then
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
    app.world:update(dt)
    -- One listener per half, each biased toward its own side of the stereo image
    -- so a blast on the right half is heard on the right (engine/game/sound.lua).
    self:update_audio(self.players, self.cameras, SPLIT_BIAS)
    app.weather:update(dt, self.cameras[1])   -- split screen: reacts to player 1's view
    app.lightfx:update(dt)
    self:tick_replay(self.players)
end

-- One vehicle in half i: the half's own player is drawn centered by its camera,
-- the teammate is projected into this half and tinted with its colour.
function CoopGameplay:_draw_vehicle(pl, local_p, i, cam)
    if pl == local_p then
        pl:draw()
    else
        pl:draw_remote(love.graphics, cam, COLORS[3 - i])
    end
end

function CoopGameplay:draw()
    local app = self.app
    local g    = love.graphics
    local W, H = g.getDimensions()
    local half_w = math.floor(W / 2)
    for i, p in ipairs(self.players) do
        local vx    = (i - 1) * half_w
        local vw    = (i == 2) and (W - half_w) or half_w
        local cam   = self.cameras[i]
        local other = self.players[3 - i]
        cam.vw, cam.vh      = vw, H
        app.renderer.camera = cam
        app.combat.camera   = cam
        app.powerups.camera = cam
        g.push()
        g.translate(vx, 0)
        g.setScissor(vx, 0, vw, H)
        local ground, air = draw_layers(p, other)
        app.postfx:begin_world()
        app.renderer:draw_ground()   -- terrain, decals, craters
        if #ground > 0 then
            app.renderer:draw_objects("under")   -- flat clutter the vehicles sit on
            for _, pl in ipairs(ground) do
                if pl == p then p:draw_world() end   -- smoke behind the local vehicle
                self:_draw_vehicle(pl, p, i, cam)
                if pl == p then p:draw_world_front() end
            end
            app.renderer:draw_objects("over")    -- trees/buildings + objective markers
        else
            app.renderer:draw_objects()          -- nothing on the ground to split around
        end
        app.rescue:draw()            -- land pads + walking POWs, on the ground under everything
        app.saboteur:draw()          -- saboteur pads + walking saboteurs + target reticles
        app.powerups:draw()
        local soft = app.postfx:soft_shadows_active()
        app.postfx:begin_shadows()
        app.helis:draw_shadows(soft) -- aircraft ground shadows, under the flyers
        p:draw_shadow(soft)
        if other then other:draw_remote_shadow(g, cam, soft) end
        if soft then
            p:draw_smoke_shadows()
            app.combat:draw_shadows()
        end
        app.postfx:end_shadows()
        if p:is_airborne() then p:draw_world() end
        app.combat:draw()
        app.renderer:draw_debris()   -- shrapnel above the explosion effects
        app.helis:draw()             -- airborne enemy helicopters
        for _, pl in ipairs(air) do self:_draw_vehicle(pl, p, i, cam) end
        if p:is_airborne() then p:draw_world_front() end
        -- Night light map and flash layer per half, from this half's camera; the
        -- headlight follows the player it belongs to and cuts on destruction.
        app.lightfx.headlight_on = not p.death
        app.lightfx:draw_night(cam)
        app.lightfx:draw_additive(cam)
        app.postfx:end_world(vx, 0, vw, H)
        app.hud.player         = p
        app.hud.coplayer       = other
        app.hud.coplayer_color = other and COLORS[3 - i] or nil
        app.hud.view_w, app.hud.view_h = vw, H
        app.hud:draw()
        self:_draw_half_status(i, p, vw, H)
        g.setScissor()
        g.pop()
    end
    app.weather:draw()   -- full-window overlay across both halves
    -- Center divider
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", half_w - 1, 0, 2, H)
    g.setColor(1, 1, 1)

    if app.end_stats:is_active() then
        app.end_stats:draw()
    elseif self.mission then
        if self.mission.state == "won" then
            self:draw_overlay_text("MISSION COMPLETE")
        elseif self.mission.state == "failed" then
            self:draw_overlay_text("MISSION FAILED")
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
    if self.playback then return end
    if key == "r" then
        -- Restart reloads the stage first, like single player, so destroyed
        -- entities and spent objectives come back.
        app.world:load(app.world.stage_name)
        app.after_stage_load()
        app.scenes:switch("coop_gameplay")
        return
    end
    if key == "f5" then
        app.settings.coop.god = not app.settings.coop.god
        for _, src in ipairs(self.sources) do src:queue("god") end
        return
    end
    if key == "f6" then self.sources[1]:queue("pickup_mode"); return end
    for i, p in ipairs(self.players) do
        if key == p.controls.weapon then self.sources[i]:queue("weapon") end
        if key == p.controls.action then self.sources[i]:queue("takeoff") end
    end
end

return CoopGameplay
