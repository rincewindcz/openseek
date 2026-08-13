local Class        = require "engine.core.class"
local GameplayBase = require "engine.scenes.gameplay_base"
local Overview     = require "engine.scenes.overview"
local Player       = require "engine.game.player"
local Mission      = require "engine.game.mission"
local Stats        = require "engine.game.stats"
local Vehicles     = require "engine.game.vehicles"
local Input        = require "engine.core.input"
local Camera       = require "engine.core.camera"
local InputFrame   = require "engine.core.input_frame"

-- Single-player gameplay scene: player lifecycle, camera follow, the death /
-- won / takeoff timers, the pause flag, and the in-game keys. Esc pushes the
-- main menu over the running game (RESUME pops back).
local Gameplay = Class(GameplayBase)

-- Ticks between spending a life and the vehicle being back on the pad. Counted in
-- simulation ticks, not by the crash picture's fade: the respawn has to land on
-- the same tick every run for a recording to replay it (co-op uses the same beat).
local RESPAWN_TICKS = 48

function Gameplay:enter()
    local app = self.app
    self:reload_stage()   -- a phase starts from a fresh stage (recordings depend on it)
    app.viewer_zoom_index = app.camera.zoom_index
    self.paused          = false
    self.death_timer     = nil
    self.respawn_tick    = nil
    self.pending_takeoff = false
    app.renderer.in_game = true
    app.camera:set_zoom(Camera.GAME_ZOOM_INDEX)
    self:enter_weather()
    app.lightfx:enter(app.world)
    self:begin_audio()
    self:enter_music()
    self:spawn_player()
end

function Gameplay:leave()
    local app = self.app
    self:end_session()
    self.paused          = false
    self.death_timer     = nil
    self.respawn_tick    = nil
    self.pending_takeoff = false
    self:reset_end_stats()
    app.weather:set(nil)
    app.lightfx:reset()
    self:end_audio()
    app.renderer.in_game   = false
    self.player            = nil
    app.hud.player         = nil
    app.combat.player      = nil
    app.combat.players     = {}
    app.combat:reset_phase()
    app.helis:clear()
    app.powerups:reset(nil)
    app.rescue:clear()
    app.saboteur:clear()
    self.mission       = nil
    app.camera.angle   = nil
    app.camera.view_oy = 0
    app.camera:set_zoom(app.viewer_zoom_index)
end

-- Sync the HUD weapon icon (WEAPONS.BIN frame) to the active weapon.
function Gameplay:sync_weapon_icon()
    local weapon_def = self.app.combat.weapons[self.player.weapon_name]
    self.player.weapon_icon = weapon_def and weapon_def.icon or 0
end

-- Build a fresh player on the stage spawn and wire it into the systems.
-- carry: keep the previous player's remaining lives and running score (a
-- respawn after losing a vehicle). Omitted for a fresh game / manual R restart,
-- which start over with full lives and a zero score.
function Gameplay:spawn_player(carry)
    local app = self.app
    self:save_recording()          -- a restart closes the previous recording
    self:seed_phase()              -- randomness and clock, before anything rolls
    self:apply_replay_settings()   -- playback: the recorded mode flags
    local world, camera, combat = app.world, app.camera, app.combat
    local settings = app.settings
    local replay_vehicle, replay_skin = self:replay_vehicle(1)
    local sx, sy = world:player_start()
    local prev   = self.player
    local player = Player:new(sx, sy)
    self.player = player
    if carry and prev then
        player.lives = prev.lives
        player.score = prev.score
    elseif app.campaign then
        -- Entering a campaign phase: seed the running score and remaining lives
        -- carried from the previous phase (zero / full on the first phase).
        player.score = app.run_score
        player.lives = app.run_lives
    end
    player.world_size   = world.stage.world_size
    player.home_x, player.home_y = sx, sy
    player.vehicle      = replay_vehicle or settings.vehicle
    player.chopper_skin = replay_skin or settings.chopper_skin
    player.world        = world
    player.camera       = camera
    player.controls     = Input.map   -- single-player movement reads the rebindable map
    local def = app.vehicle_defs[player.vehicle]
    if def then player:load_vehicle_def(def) end
    -- Weapon list: the equip-screen loadout snapshot when one was applied
    -- (campaign / mission play), else the free-play full list. The loadout
    -- carries per-weapon owned levels and bay-count ammo multipliers.
    local loadout = settings.loadout
    if loadout then
        player.weapon_list   = loadout.list
        player.weapon_levels = loadout.levels
        player.weapon_name   = loadout.list[1]
        player.weapon_level  = loadout.levels[player.weapon_name] or 1
        -- Equip-screen characteristics (0..1) scale the fuel/armor loadout; speed
        -- follows from their sum via Player:_apply_config.
        if loadout.chars then
            player.load_fuel  = loadout.chars.fuel  * 100
            player.load_armor = loadout.chars.armor * 100
            player:_apply_config()
        end
    else
        local weapon_list = Vehicles.WEAPONS[player.vehicle]
        if weapon_list then player.weapon_name = weapon_list[1] end
    end
    player:seed_ammo(combat.weapons, loadout and loadout.counts)
    self:apply_replay_player(player, 1)   -- playback: the recorded loadout wins
    self:begin_input("single", { player }, { Input.map })
    self:sync_weapon_icon()
    camera:set_game_focus()
    app.hud.player     = player
    combat.player      = player
    combat.players     = { player }
    combat:reset_phase()
    app.helis:reset()
    app.powerups:reset(player)
    app.rescue.pow_counts = Mission.rescue_counts(world.stage_name)
    app.rescue:reset()
    app.saboteur.spec = Mission.sabotage_spec(world.stage_name)
    app.saboteur:reset()
    self.mission = Mission.for_stage(world, { player }, world.stage_name)
    camera.x, camera.y = player.x, player.y
    camera:start_zoom_intro(1.5, 1.0)   -- smooth zoom-in as the level opens
    self.pending_takeoff = true         -- chopper takes off when the zoom-in ends
    self:reset_end_stats()
end

-- Reload the current stage and respawn the player (R in game mode, or a key
-- on the crash end screen).
function Gameplay:restart(carry)
    local app = self.app
    self.death_timer = nil
    app.world:load(app.world.stage_name)
    app.after_stage_load()
    self:spawn_player(carry)
end

-- A vehicle was destroyed: spend one life (the count shown in the HUD). With
-- spares left, the crash picture holds until a key, then the player respawns at
-- the home base with the stage's progress intact (destroyed enemies stay down,
-- objectives keep their progress). On the last life it is game over: the final
-- score is handed to the high-score screen for a possible entry.
function Gameplay:on_vehicle_lost()
    local app    = self.app
    local player = self.player
    -- Objectives were finished as the vehicle went down: the stats screen is
    -- already taking over (see the death handler), so no life is spent here.
    if self.mission and self.mission.state == "won" then return end
    player.lives = math.max(0, (player.lives or 0) - 1)
    local pic    = (player.vehicle == "tank") and "TANKEND" or "DEATHPIC"
    if player.lives > 0 then
        -- Recoverable: the respawn is scheduled on the simulation clock, and the
        -- crash picture only flashes over it (skipped while replaying, which has
        -- no viewer to inform).
        self.respawn_tick = app.tick + RESPAWN_TICKS
        if not self.playback then
            app.screen:show(pic, { fade_in = 0.1, hold = 0.5, fade_out = 0.1 })
        end
    else
        if self.playback then self:finish_playback("game over"); return end
        local score = player.score or 0
        app.campaign = false   -- out of lives: the run is over
        app.screen:show(pic, {
            fade_in   = 0.6,
            wait_key  = true,
            on_done   = function() app.scenes:switch("hiscores", score) end,
            on_cancel = function() app.scenes:switch("hiscores", score) end,
        })
    end
end

-- Respawn at the home base after a crash without reloading the stage, so the
-- world keeps its progress. The mission flipped to "failed" while the vehicle was
-- down (every player dead); with a spare vehicle it is cleared back to "active" so
-- the remaining objectives can still be finished.
function Gameplay:respawn_at_base()
    local app    = self.app
    local player = self.player
    self.respawn_tick = nil
    player:respawn(player.home_x or player.x, player.home_y or player.y)
    if self.mission and self.mission.state == "failed" then
        self.mission.state = "active"
    end
    app.camera.x, app.camera.y = player.x, player.y
    app.camera:start_zoom_intro(1.5, 1.0)
    self.pending_takeoff = true
    self.death_timer     = nil
end

-- Stats dismissed: in a campaign run, carry the accumulated score and remaining
-- lives forward and open the next phase's briefing (or the next mission once a
-- mission's phases are done). When the last stage is cleared, the run is complete
-- and the total goes to the high-score screen. Outside a run, back to the menu.
function Gameplay:on_stats_done()
    local app = self.app
    if not app.campaign then
        app.scenes:switch("main_menu")   -- single stage done: back to the menu
        return
    end
    app.run_score = self.player.score or app.run_score
    app.run_lives = self.player.lives or app.run_lives
    -- Carry the medals picked up this phase into the shop purse for the next one.
    if app.loadout then
        app.loadout.medals = app.loadout.medals + (self.player.medals or 0)
    end
    local next_stage = app.world.stages[app.world.stage_index + 1]
    if not next_stage then
        app.campaign = false
        app.scenes:switch("hiscores", app.run_score)
        return
    end
    local cur_m  = tonumber((app.world.stage_name or ""):match("^stage(%d)"))
    local next_m = tonumber(next_stage:match("^stage(%d)"))
    app.world:load(next_stage)
    app.after_stage_load()
    app.scenes:switch("mission_briefing", next_stage)
    -- Crossing into a new mission: show that mission's picture over the briefing.
    if next_m and next_m ~= cur_m then
        app.screen:show_mission(next_m)
    end
end

-- Single player: the whole stage's destruction is credited to the lone player
-- (counted from alive versus total), choppers from the heli system counter.
function Gameplay:collect_stats()
    local app = self.app
    local ground_total, ground_down, building_total, building_down = Stats.destructible_totals(app.world)
    return {
        phase = Stats.stage_phase(app.world.stage_name),
        participants = { {
            player    = self.player,
            ground    = { killed = ground_down, total = ground_total },
            buildings = { killed = building_down, total = building_total },
            choppers  = app.helis.kills or 0,
            rescues   = self.player.pows or 0,
        } },
    }
end

function Gameplay:update(dt)
    local app    = self.app
    local player = self.player
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
            self:on_stats_done()   -- reverse close finished: hand off to the next scene
        end
        return
    end
    self:begin_tick()
    local frame = self:apply_input(player, self.source)
    player:update(dt)
    if not player.death then app.combat:crush_units(player) end
    if app.settings.death_enabled and not player.death and player:is_dead() then
        -- Crashing on the way home with every objective already done still counts
        -- as a mission complete: flip to won now (before the death sets the mission
        -- to failed) so the stats screen takes over instead of costing a life.
        if self.mission and self.mission.state == "return_to_base" then
            self.mission.state = "won"
        end
        -- A crash is terminal only when it spends the last life; otherwise it is a
        -- recoverable "MAYDAY" that respawns. Captured now (before the life is
        -- spent) so the overlay and timing stay stable through the death.
        self.terminal_death = (player.lives or 0) <= 1
        player:start_death()
    end
    -- After the crash animation finishes, hold briefly then spend a life and bring
    -- up the crash picture (a quick beat for a recoverable crash, a longer one on
    -- game over); see on_vehicle_lost.
    if self.respawn_tick and app.tick >= self.respawn_tick then
        self.respawn_tick = nil
        self:respawn_at_base()
    end
    if player:death_done() and not app.screen:is_active() then
        if self.death_timer == nil then
            self.death_timer = self.terminal_death and 3.0 or 0.8
        elseif self.death_timer > 0 then
            self.death_timer = self.death_timer - dt
            if self.death_timer <= 0 then
                self.death_timer = 0
                self:on_vehicle_lost()
            end
        end
    end
    if not player.death and InputFrame.held(frame, "fire") then
        self:fire_for(player)
    end
    app.combat:update(dt)
    app.helis:update(dt)
    app.powerups:update(dt)
    app.rescue:update(dt)
    app.saboteur:update(dt)
    if self.mission then self.mission:update(dt) end
    self:update_won(dt)
    app.camera.x     = player.x
    app.camera.y     = player.y
    app.camera.angle = player:camera_angle()
    app.camera:tick_zoom(dt)
    if self.pending_takeoff and not app.camera.zoom_anim then
        player:take_off()   -- no-op for the tank
        self.pending_takeoff = false
    end
    app.world:update(dt)
    self:update_audio({ player }, { app.camera })
    app.weather:update(dt, app.camera)
    app.lightfx.headlight_on = not player.death   -- vehicle lights cut on destruction
    app.lightfx:update(dt)
    app.debug_panel:update()
    self:tick_replay({ player })
end

function Gameplay:draw()
    local app     = self.app
    local mission = self.mission
    app.renderer.highlight = app.debug_panel:highlight_entity()
    app.renderer:draw_ground()   -- terrain, decals, craters
    -- A vehicle on the ground draws (with its smoke) over flat clutter (stones,
    -- dunes, decals) but under the solid props (trees, buildings) that stand taller
    -- than it, and under the enemy flyers. A tank is always down there; a chopper
    -- joins it the moment it touches down and leaves again on takeoff. Airborne, it
    -- keeps its slot on top of it all.
    local grounded = not self.player:is_airborne()
    if grounded then
        app.renderer:draw_objects("under")   -- flat clutter the vehicle sits on
        self.player:draw_world()
        self.player:draw()
        self.player:draw_world_front()
        app.renderer:draw_objects("over")    -- trees/buildings + objective markers
    else
        app.renderer:draw_objects()          -- everything, airborne player drawn later
    end
    app.rescue:draw()            -- land pads + walking POWs, on the ground under everything
    app.saboteur:draw()          -- saboteur pads + walking saboteurs + target reticles
    app.powerups:draw()
    app.helis:draw_shadows()     -- aircraft ground shadows, under the flyers
    self.player:draw_shadow()    -- flyer only (no-op for the grounded tank)
    if not grounded then self.player:draw_world() end
    app.combat:draw()
    app.renderer:draw_debris()   -- shrapnel above the explosion effects
    app.helis:draw()             -- airborne enemy helicopters
    if not grounded then
        self.player:draw()
        self.player:draw_world_front()
    end
    app.weather:draw()
    app.lightfx:draw_night(app.camera)
    app.lightfx:draw_additive(app.camera)
    app.hud:draw()
    if mission and mission.state == "return_to_base" then self:draw_return_prompt() end
    if mission and mission.state == "won" and not app.end_stats:is_active() then
        self:draw_overlay_text("MISSION COMPLETE")
    end
    if mission and mission.state == "failed" then
        if self.terminal_death then
            self:draw_overlay_text("GAME OVER")
        else
            -- recoverable loss, no screen tint: aircraft mayday vs a downed tank
            local msg = (self.player and self.player.vehicle == "tank")
                and "TANK DOWN" or "MAYDAY MAYDAY"
            self:draw_overlay_text(msg, 0)
        end
    end
    if app.end_stats:is_active() then app.end_stats:draw() end
    self:draw_replay_tag()
    if self.paused then self:draw_overlay_text("PAUSE") end
    app.debug_panel:draw()
end

-- Debug-panel keys, shared with the sandbox subclass. Returns true when the
-- key was consumed.
function Gameplay:debug_keys(key)
    local app = self.app
    if key == "f2" then app.debug_panel:toggle(); return true end
    if app.debug_panel.enabled and app.debug_panel:keypressed(key) then return true end
    return false
end

-- The in-game keys after the debug (and sandbox) layers had their chance.
function Gameplay:game_keys(key)
    local app = self.app
    if app.end_stats:is_active() then self:end_stats_keypressed(key); return end
    if Input.pressed("pause", key)   then self.paused = not self.paused; return end
    if self.playback then
        if key == "escape" then self:finish_playback("stopped") end
        return
    end
    if key == "r"  then self.paused = false; self:restart(); return end
    if key == "f5" then self.source:queue("god"); return end
    if key == "f6" then self.source:queue("pickup_mode"); return end
    if Input.pressed("takeoff", key) then self.source:queue("takeoff"); return end
    if Input.pressed("weapon", key)  then self.source:queue("weapon"); return end
    if key == "e" then self.source:queue("level"); return end
    if Overview.picker_keys(app, key) then return end
    local slot = key:match("^(%d)$")
    if slot then self.source:queue("slot:" .. slot); return end
    if key == "escape" then app.scenes:push("main_menu") end
end

function Gameplay:keypressed(key)
    if self:debug_keys(key) then return end
    self:game_keys(key)
end

return Gameplay
