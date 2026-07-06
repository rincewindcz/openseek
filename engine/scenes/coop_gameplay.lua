local Class        = require "engine.core.class"
local GameplayBase = require "engine.scenes.gameplay_base"
local Camera       = require "engine.core.camera"
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

function CoopGameplay:make_player(idx, sx, sy)
    local app  = self.app
    local coop = app.settings.coop
    local p = Player:new(sx, sy)
    p.world_size   = app.world.stage.world_size
    p.vehicle      = coop.vehicle[idx]
    p.chopper_skin = coop.skin[idx]
    p.world        = app.world
    p.controls     = (idx == 1) and CoopGameplay.P1_CONTROLS or CoopGameplay.P2_CONTROLS
    local def = app.vehicle_defs[p.vehicle]
    if def then p:load_vehicle_def(def) end
    local weapon_list = Vehicles.WEAPONS[p.vehicle]
    if weapon_list then p.weapon_name = weapon_list[1] end
    p:seed_ammo(app.combat.weapons)
    p.unlimited = coop.god
    return p
end

function CoopGameplay:enter()
    local app = self.app
    local world, combat = app.world, app.combat
    app.viewer_zoom_index = app.camera.zoom_index
    self.paused = false
    self:reset_end_stats()
    app.renderer.in_game = true
    self:enter_weather()

    local sx, sy = world:player_start()
    self.players = {
        self:make_player(1, sx - 40, sy),
        self:make_player(2, sx + 40, sy),
    }
    for _, p in ipairs(self.players) do p.home_x, p.home_y = sx, sy end
    self.cameras = { Camera:new(world.stage.world_size), Camera:new(world.stage.world_size) }
    local _, screen_h = love.graphics.getDimensions()
    for i, p in ipairs(self.players) do
        local c = self.cameras[i]
        c:set_zoom(6)
        c.view_oy = screen_h * 0.24
        c.x, c.y  = p.x, p.y
        c.angle   = p:camera_angle()
        p.camera  = c
        p:take_off()   -- choppers lift off; no-op for the tank
    end

    local coop = app.settings.coop
    combat.players       = self.players
    combat.player        = self.players[1]
    combat.friendly_fire = coop.ff
    combat.projectiles   = {}
    combat.effects       = {}
    app.helis:reset()
    app.powerups:set_players(self.players)
    app.rescue.pow_counts = Mission.rescue_counts(world.stage_name)
    app.rescue:reset()
    -- Shared co-op objective from the stage's decoded objectives (nil = free play).
    self.mission = Mission.coop(world, self.players)
end

function CoopGameplay:leave()
    local app = self.app
    self.paused = false
    self:reset_end_stats()
    app.weather:set(nil)
    app.renderer.in_game = false
    -- Restore the shared overview camera on every system that was pointed at
    -- a split camera, or the overview renders through a stale half-view.
    app.renderer.camera = app.camera
    app.combat.camera   = app.camera
    app.powerups.camera = app.camera
    app.combat.players       = {}
    app.combat.player        = nil
    app.combat.friendly_fire = false
    app.combat.projectiles   = {}
    app.combat.effects       = {}
    app.helis:clear()
    app.powerups:reset(nil)
    app.hud.player = nil
    app.hud.coplayer, app.hud.coplayer_color = nil, nil
    app.hud.view_w, app.hud.view_h = nil, nil
    self.players = {}
    self.cameras = {}
    self.mission = nil
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

function CoopGameplay:update(dt)
    local app = self.app
    if self.paused then return end
    if app.end_stats:is_active() then
        app.end_stats:update(dt)
        if app.end_stats:is_active() then
            app.world:update(dt)
        else
            self:on_stats_done()   -- reverse close finished: hand off (base -> menu)
        end
        return
    end
    for _, p in ipairs(self.players) do
        p:update(dt)
        if not p.death and p:_held("fire") then self:fire_for(p) end
        if app.settings.death_enabled and not p.death and p:is_dead() then p:start_death() end
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
    if self.mission then self.mission:update(dt) end
    self:update_won(dt)
    app.world:update(dt)
    app.weather:update(dt, self.cameras[1])   -- split screen: reacts to player 1's view
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
        app.renderer:_draw_world()
        app.rescue:draw()            -- land pads + walking POWs, on the ground under everything
        app.powerups:draw()
        app.helis:draw_shadows()     -- aircraft ground shadows, under the flyers
        p:draw_shadow()
        if other then other:draw_remote_shadow(g, cam) end
        p:draw_world()
        app.combat:draw()
        app.renderer:draw_debris()   -- shrapnel above the explosion effects
        app.helis:draw()             -- airborne enemy helicopters
        -- Draw both vehicles back-to-front: a chopper always sits above a tank (it is
        -- airborne), and two of the same layer order by world y so the southern one is
        -- on top, identically in both halves (the local one centered, the teammate
        -- placed by projection). Without this the teammate always covered the local
        -- player, and a tank could end up over a flying chopper.
        local function layer(pl) return pl.vehicle == "tank" and 0 or 1 end
        local p_front
        if other then
            if layer(p) ~= layer(other) then p_front = layer(p) > layer(other)
            else p_front = p.y >= other.y end
        end
        if other and not p_front then
            other:draw_remote(g, cam, COLORS[3 - i])
            p:draw()
        else
            p:draw()
            if other then other:draw_remote(g, cam, COLORS[3 - i]) end
        end
        p:draw_world_front()
        app.hud.player         = p
        app.hud.coplayer       = other
        app.hud.coplayer_color = other and COLORS[3 - i] or nil
        app.hud.view_w, app.hud.view_h = vw, H
        app.hud:draw()
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
            self:overlay_text("MISSION COMPLETE")
        elseif self.mission.state == "failed" then
            self:overlay_text("MISSION FAILED")
        end
    end
    if self.paused then self:overlay_text("PAUSE") end
end

function CoopGameplay:keypressed(key)
    local app = self.app
    if app.end_stats:is_active() then self:end_stats_keypressed(key); return end
    if key == "escape" then app.scenes:push("main_menu"); return end
    if key == "p" then self.paused = not self.paused; return end
    if key == "r" then app.scenes:switch("coop_gameplay"); return end   -- full re-enter
    if key == "f5" then
        local coop = app.settings.coop
        coop.god = not coop.god
        for _, p in ipairs(self.players) do p.unlimited = coop.god end
        return
    end
    if key == "f6" then app.powerups.easy_mode = not app.powerups.easy_mode; return end
    for _, p in ipairs(self.players) do
        if key == p.controls.weapon then self:cycle_weapon(p) end
        if key == p.controls.action then self:toggle_land(p) end
    end
end

return CoopGameplay
