local World         = require "engine.game.world"
local Camera        = require "engine.core.camera"
local Renderer      = require "engine.game.renderer"
local Debug         = require "engine.dev.debug_panel"
local Animation     = require "engine.core.animation"
local Player        = require "engine.game.player"
local Hud           = require "engine.ui.hud"
local CombatSystem  = require "engine.game.combat"
local HeliSystem    = require "engine.game.enemy_heli"
local Powerups      = require "engine.game.powerups"
local RescueSystem  = require "engine.game.rescue"
local Mission       = require "engine.game.mission"
local Screen        = require "engine.core.screen"
local Menu          = require "engine.ui.menu"
local MissionMenu   = require "engine.ui.mission_menu"
local MissionSelect = require "engine.ui.mission_select"
local Config        = require "engine.core.config"
local Font          = require "engine.core.font"
local EndStats      = require "engine.ui.end_stats"
local Pointer       = require "engine.ui.pointer"
local Stats         = require "engine.game.stats"
local json          = require "lib.json"

local world
local camera
local renderer
local debug_panel
local hud
local player
local combat
local helis
local powerups
local rescue
local mission
local screen
local menu
local mission_menu
local mission_select
local hidden_cursor  -- transparent HW cursor used to hide the pointer reliably
local end_stats
local won_timer             = nil     -- counts down MISSION COMPLETE before DESTRUCTION STATS
local end_stats_started     = false
local anim_gallery          = false   -- test overlay: plays every animation clip at once
local gallery               = nil     -- lazily built { items = {{name, state}, ...} }
local font_gallery          = false   -- test overlay: renders every original bitmap font
local death_timer           = nil     -- counts ~3s after a fatal crash before the end picture
local pending_takeoff       = false   -- chopper lifts off once the level-start zoom-in ends
local game_mode             = false
local sandbox_mode          = false
local death_enabled         = false   -- optional game-over (chopper falls, tank burns)
local paused                = false
local selected_vehicle      = "chopper"
local selected_chopper_skin = 1       -- player chopper variant (1 green, 2 magenta, 3 white)
local viewer_zoom_index     = 4
local vehicle_defs          = {}
local CHOPPER_SKINS         = 3

-- The vehicle picker cycles chopper skin 1->2->3 then tank then back. Returns the
-- next (vehicle, skin) pair; a label like "CHOPPER 2" / "TANK" for the UI.
local function cycle_vehicle(vehicle, skin)
    if vehicle == "tank" then return "chopper", 1 end
    if skin < CHOPPER_SKINS then return "chopper", skin + 1 end
    return "tank", skin
end

local function vehicle_label(vehicle, skin)
    if vehicle == "tank" then return "TANK" end
    return skin > 1 and ("CHOPPER " .. skin) or "CHOPPER"
end

-- split-screen two-player (extra mode, not in the original game)
local split_mode      = false
local coop_setup_open = false   -- the 2P setup menu overlay
local split_players   = {}      -- two Player instances
local split_cameras   = {}      -- two Camera instances, one per screen half
local coop_options    = { vehicle = { "chopper", "tank" }, skin = { 1, 1 }, god = false, ff = false }
local COOP_COLORS     = { { 0.30, 0.65, 1.0 }, { 1.0, 0.55, 0.15 } }  -- P1 blue, P2 orange

-- Distinct key sets so both players share one keyboard. fire / weapon / action
-- are read here in main.lua; the movement keys feed Player.controls.
local P1_CONTROLS = {
    up = "w", down = "s", left = "a", right = "d",
    modifier = "lshift", fire = "lctrl", weapon = "q", action = "e",
}
local P2_CONTROLS = {
    up = "up", down = "down", left = "left", right = "right",
    modifier = "rshift", fire = "rctrl", weapon = "kp0", action = "kpenter",
}

-- Weapon lists per vehicle (order determines cycle order)
local VEHICLE_WEAPONS = {
    chopper = {"chaingun", "napalm", "rockets", "mega_missile", "air_to_ground", "air_to_air", "bomb"},
    tank    = {"chaingun", "shells"},
}

-- Sync the HUD weapon icon (WEAPONS.BIN frame) to the active weapon.
local function sync_weapon_icon()
    if not (player and combat) then return end
    local weapon_def = combat.weapons[player.weapon_name]
    player.weapon_icon = weapon_def and weapon_def.icon or 0
end

-- sandbox UI

local SANDBOX_PARAMS = {
    { name="sprite_scale",   step=0.5  },
    { name="rotor_y_offset", step=1    },
    { name="rotor_fps",      step=2    },
    { name="turn_rate",      step=5    },
    { name="accel",          step=10   },
    { name="decel",          step=10   },
    { name="brake",          step=10   },
    { name="max_fwd",        step=10   },
    { name="max_rev",        step=5    },
    { name="strafe_speed",   step=5    },
    { name="strafe_accel",   step=10   },
    { name="fuel_drain",     step=0.1  },
    { name="takeoff_time",   step=0.05 },
    { name="land_time",      step=0.05 },
}
local sandbox_cursor       = 1
local sandbox_status       = ""
local sandbox_status_timer = 0

local function sandbox_apply()
    if not player then return end
    local def = vehicle_defs[selected_vehicle]
    if def then player:load_vehicle_def(def) end
end

local function sandbox_adjust(dir)
    local def = vehicle_defs[selected_vehicle]
    if not def then return end
    local p = SANDBOX_PARAMS[sandbox_cursor]
    def[p.name] = (def[p.name] or 0) + dir * p.step
    sandbox_apply()
end

local function sandbox_save()
    local def = vehicle_defs[selected_vehicle]
    if not def then return end
    local src  = love.filesystem.getSource()
    local path = src .. "/data/vehicles/" .. selected_vehicle .. ".json"
    local f    = io.open(path, "w")
    if not f then
        sandbox_status       = "ERROR: cannot write"
        sandbox_status_timer = 3
        return
    end
    f:write("{\n")
    local keys = {}
    for k in pairs(def) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local v  = def[k]
        local value_text = type(v) == "number" and string.format("%.4g", v) or tostring(v)
        f:write(string.format('  "%s": %s%s\n', k, value_text, i < #keys and "," or ""))
    end
    f:write("}\n")
    f:close()
    sandbox_status       = "Saved!"
    sandbox_status_timer = 2
end

local function draw_sandbox_panel()
    local g        = love.graphics
    local screen_w = g.getDimensions()
    local pw       = 220
    local ph       = #SANDBOX_PARAMS * 18 + 58
    local bx       = screen_w - pw - 4
    local by       = 30

    g.setColor(0, 0, 0, 0.88)
    g.rectangle("fill", bx, by, pw, ph, 4)
    g.setColor(0.3, 0.9, 0.3, 1)
    g.print("SANDBOX: " .. selected_vehicle, bx + 8, by + 6)

    local def = vehicle_defs[selected_vehicle] or {}
    for i, p in ipairs(SANDBOX_PARAMS) do
        local y = by + 24 + (i - 1) * 18
        if i == sandbox_cursor then
            g.setColor(0.2, 0.5, 1, 0.3)
            g.rectangle("fill", bx + 2, y - 1, pw - 4, 18)
            g.setColor(1, 1, 0, 1)
        else
            g.setColor(0.75, 0.75, 0.75, 1)
        end
        local val = def[p.name]
        local value_text  = val ~= nil and string.format("%.4g", val) or "?"
        g.print(string.format("%-16s %6s", p.name, value_text), bx + 8, y)
    end

    g.setColor(0.45, 0.45, 0.45, 1)
    g.print("[/] nav  +/- adj  F4 save  F3 exit", bx + 4, by + ph - 18)

    if sandbox_status ~= "" then
        g.setColor(0.1, 1, 0.4, 1)
        g.print(sandbox_status, bx + 8, by + ph + 4)
    end
end

-- Centered title in the game's bitmap body font (same as the score readout) over
-- a dimmed screen. No subtitle / key hints: game mode shows game-font text only.
local function draw_overlay_text(title, dim)
    local g      = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, dim or 0.55)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    local font = Font.get("chars")
    local s    = 5
    font:print(title, (screen_w - font:width(title, s)) / 2,
        (screen_h - font.line_height * s) / 2, { scale = s })
    g.setColor(1, 1, 1)
end

local function draw_pause()     draw_overlay_text("PAUSE")            end
local function draw_game_over() draw_overlay_text("GAME OVER")        end
local function draw_victory()   draw_overlay_text("MISSION COMPLETE") end

-- Slow-blinking "MISSION COMPLETE / RETURN TO BASE" once every objective is met
-- and the player only has to fly home (mission state "return_to_base"). Uses the
-- score font (CHARS), not the menu ENDCHARS face.
local function draw_return_prompt()
    if math.floor(love.timer.getTime() * 1.5) % 2 ~= 0 then return end
    local g      = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local font   = Font.get("chars")
    local s      = 4
    local lines  = { "MISSION COMPLETE", "RETURN TO BASE" }
    local y      = screen_h / 2 - 70
    for _, ln in ipairs(lines) do
        font:print(ln, (screen_w - font:width(ln, s)) / 2, y, { scale = s })
        y = y + font.line_height * s + 10
    end
end

-- end-of-phase stats

-- Single player: the whole stage's destruction is credited to the lone player
-- (counted from alive versus total), choppers from the heli system counter.
local function collect_stats()
    local ground_total, ground_down, building_total, building_down = Stats.destructible_totals(world)
    return {
        phase = Stats.stage_phase(world.stage_name),
        participants = { {
            player    = player,
            ground    = { killed = ground_down, total = ground_total },
            buildings = { killed = building_down, total = building_total },
            choppers  = helis.kills or 0,
            rescues   = player.pows or 0,
        } },
    }
end

-- Co-op: one column per player from their own attributed kills (combat /
-- enemy_heli credit the shooter's stat_kills), against the shared stage totals.
local function collect_coop_stats()
    local ground_total, _gd, building_total = Stats.destructible_totals(world)
    local participants = {}
    for i, p in ipairs(split_players) do
        local k = p.stat_kills or {}
        participants[i] = {
            player    = p,
            color     = COOP_COLORS[i],
            ground    = { killed = k.ground or 0,   total = ground_total },
            buildings = { killed = k.building or 0,  total = building_total },
            choppers  = k.chopper or 0,
            rescues   = p.pows or 0,
        }
    end
    return { phase = Stats.stage_phase(world.stage_name), participants = participants }
end

-- mode transitions

local function after_stage_load()
    camera.world_size = world.stage.world_size
    camera:clamp()
    renderer:refresh_kinds()
    debug_panel.world = world
    hud.world = world
    hud:set_mission(tonumber(world.stage_name:match("^stage(%d)")) or 0)
    love.window.setTitle(world:title())
    if player then
        player.world_size = world.stage.world_size
        player.world      = world
    end
end

-- Build a fresh player on the stage spawn and wire it into the systems.
local function spawn_player()
    local sx, sy = world:player_start()
    player = Player:new(sx, sy)
    player.world_size   = world.stage.world_size
    player.home_x, player.home_y = sx, sy
    player.vehicle      = selected_vehicle
    player.chopper_skin = selected_chopper_skin
    player.world        = world
    player.camera       = camera
    local def = vehicle_defs[selected_vehicle]
    if def then player:load_vehicle_def(def) end
    local weapon_list = VEHICLE_WEAPONS[selected_vehicle]
    if weapon_list then player.weapon_name = weapon_list[1] end
    player:seed_ammo(combat.weapons)
    sync_weapon_icon()
    local _, screen_h = love.graphics.getDimensions()
    camera.view_oy = screen_h * 0.24
    hud.player    = player
    combat.player = player
    combat.players = { player }
    combat.projectiles = {}
    combat.effects     = {}
    helis:reset()
    powerups:reset(player)
    rescue.pow_counts = Mission.rescue_counts(world.stage_name)
    rescue:reset()
    mission = Mission.for_stage(world, player, world.stage_name)
    camera.x, camera.y = player.x, player.y
    camera:start_zoom_intro(1.5, 1.0)   -- smooth zoom-in as the level opens
    pending_takeoff = true              -- chopper takes off when the zoom-in ends
    won_timer       = nil
    end_stats_started = false
    if end_stats then end_stats.active = false end
end

local function enter_game_mode()
    if menu then menu:close() end  -- drop the held-black menu once the world is live
    if mission_menu then mission_menu:close() end
    viewer_zoom_index  = camera.zoom_index
    game_mode  = true
    paused     = false
    death_timer = nil
    renderer.in_game = true
    camera:set_zoom(6)
    spawn_player()
    love.window.setTitle(world:title() .. "  [" .. selected_vehicle .. "]")
end

-- The per-mission briefing picture (STAGE0X_MPIC) for the loaded stage. Stage
-- names are stage{mission}{phase}, so the first digit selects the picture.
local function mission_pic()
    local m = world.stage_name and world.stage_name:match("^stage(%d)")
    return m and ("STAGE0" .. m .. "_MPIC") or nil
end

-- Show the mission briefing picture, then drop into the live game.
local function begin_game_mode()
    local pic = mission_pic()
    if pic then
        screen:show(pic, { fade_in = 0.3, hold = 0.75, fade_out = 0.3, on_done = enter_game_mode })
    else
        enter_game_mode()
    end
end

-- Reload the current stage and respawn the player (R in game mode).
local function restart_level()
    death_timer = nil
    local name = world.stage_name
    world:load(name)
    after_stage_load()
    spawn_player()
    love.window.setTitle(world:title() .. "  [" .. selected_vehicle .. "]")
end

local function leave_game_mode()
    game_mode         = false
    sandbox_mode      = false
    paused            = false
    death_timer       = nil
    won_timer         = nil
    end_stats_started  = false
    if end_stats then end_stats.active = false end
    pending_takeoff   = false
    renderer.in_game  = false
    player            = nil
    hud.player        = nil
    combat.player     = nil
    combat.players    = {}
    combat.projectiles = {}
    combat.effects     = {}
    helis:clear()
    powerups:reset(nil)
    rescue:clear()
    mission           = nil
    camera.angle      = nil
    camera.view_oy    = 0
    camera:set_zoom(viewer_zoom_index)
    love.window.setTitle(world:title())
end

-- Opens the main menu over whatever is currently running. RESUME is only
-- selectable when a game is actually in progress behind it.
local function open_menu()
    menu:set_enabled("resume", game_mode or false)  -- coerce nil -> disabled
    menu:open()
end

-- Runs a confirmed menu entry, fired by the menu once its confirm flash/fade
-- has played (see engine/menu.lua). The info screens close the menu and
-- reopen it when dismissed, so the menu fades back in behind them.
local function menu_select(id)
    if id == "new_game" then
        if game_mode then leave_game_mode() end
        menu:close()
        mission_menu:open(world.stage_name or world.stages[1])  -- pre-mission menu
    elseif id == "resume" then
        menu:close()
    elseif id == "options" or id == "credits" or id == "hiscores" then
        local pic = (id == "options" and "OPTPIC") or (id == "credits" and "CREDITS") or "HISCORE"
        menu:hold()  -- stay active but black behind the screen so the game can't show through
        screen:show(pic, { fade_in = 0.3, wait_key = true, fade_out = 0.3, on_done = open_menu })
    elseif id == "mission" then
        menu:close()
        mission_select:open()   -- debug mission/phase picker
    elseif id == "editor" then
        -- Drop into the overview (dev/editor) view. TODO: real level editor.
        if game_mode then leave_game_mode() end
        menu:close()
    elseif id == "exit" then
        love.event.quit()
    end
end

-- Runs a confirmed mission-select button: PLAY loads the chosen stage and opens
-- its pre-mission menu (from there PLAY starts the level); EXIT backs out to the
-- main menu. The mission-select fade-out plays before this runs.
local function mission_picker_select(id, stage_name)
    if id == "play" then
        mission_select:close()
        if game_mode then leave_game_mode() end
        world:load(stage_name)
        after_stage_load()
        mission_menu:open(stage_name)
    elseif id == "exit" then
        mission_select:close()
        open_menu()
    end
end

-- Runs a confirmed mission-menu button. PLAY drops straight into the mission
-- (the menu itself is the briefing now); EXIT backs out to the main menu.
-- SAVE / LOAD / SHOP are stubs for now.
local function mission_menu_select(id)
    if id == "play" then
        mission_menu:close()
        enter_game_mode()
    elseif id == "exit" then
        mission_menu:close()
        open_menu()
    end
end

local function enter_sandbox()
    if not game_mode then enter_game_mode() end
    sandbox_mode = true
    love.window.setTitle(world:title() .. "  [sandbox:" .. selected_vehicle .. "]")
end

local function leave_sandbox()
    leave_game_mode()
end

-- split-screen two-player mode

local function make_split_player(idx, sx, sy)
    local p = Player:new(sx, sy)
    p.world_size = world.stage.world_size
    p.vehicle    = coop_options.vehicle[idx]
    p.chopper_skin = coop_options.skin[idx]
    p.world      = world
    p.controls   = (idx == 1) and P1_CONTROLS or P2_CONTROLS
    local def = vehicle_defs[p.vehicle]
    if def then p:load_vehicle_def(def) end
    local weapon_list = VEHICLE_WEAPONS[p.vehicle]
    if weapon_list then p.weapon_name = weapon_list[1] end
    p:seed_ammo(combat.weapons)
    p.unlimited = coop_options.god
    return p
end

local function enter_split()
    viewer_zoom_index  = camera.zoom_index
    coop_setup_open  = false
    split_mode = true
    game_mode  = false
    paused     = false
    won_timer        = nil
    end_stats_started = false
    if end_stats then end_stats.active = false end
    renderer.in_game = true

    local sx, sy = world:player_start()
    split_players = {
        make_split_player(1, sx - 40, sy),
        make_split_player(2, sx + 40, sy),
    }
    for _, p in ipairs(split_players) do p.home_x, p.home_y = sx, sy end
    split_cameras = { Camera:new(world.stage.world_size), Camera:new(world.stage.world_size) }
    local _, screen_h = love.graphics.getDimensions()
    for i, p in ipairs(split_players) do
        local c = split_cameras[i]
        c:set_zoom(6)
        c.view_oy = screen_h * 0.24
        c.x, c.y  = p.x, p.y
        c.angle   = p:camera_angle()
        p.camera  = c
        p:take_off()   -- choppers lift off; no-op for the tank
    end

    combat.players      = split_players
    combat.player       = split_players[1]
    combat.friendly_fire = coop_options.ff
    combat.projectiles  = {}
    combat.effects      = {}
    helis:reset()
    powerups:set_players(split_players)
    rescue.pow_counts = Mission.rescue_counts(world.stage_name)
    rescue:reset()
    -- Shared co-op objective from the stage's decoded objectives (nil = free play).
    mission = Mission.coop(world, split_players)
    love.window.setTitle(world:title() .. "  [2P SPLIT]")
end

local function leave_split()
    split_mode       = false
    won_timer        = nil
    end_stats_started = false
    if end_stats then end_stats.active = false end
    renderer.in_game = false
    renderer.camera  = camera
    combat.camera    = camera
    powerups.camera  = camera
    combat.players   = {}
    combat.player    = nil
    combat.friendly_fire = false
    combat.projectiles = {}
    combat.effects     = {}
    helis:clear()
    powerups:reset(nil)
    hud.player = nil
    hud.coplayer, hud.coplayer_color = nil, nil
    hud.view_w, hud.view_h = nil, nil
    split_players = {}
    split_cameras = {}
    camera.angle   = nil
    camera.view_oy = 0
    camera:set_zoom(viewer_zoom_index)
    love.window.setTitle(world:title())
end

local function draw_split()
    local g    = love.graphics
    local W, H = g.getDimensions()
    local half_w   = math.floor(W / 2)
    for i, p in ipairs(split_players) do
        local vx    = (i - 1) * half_w
        local vw    = (i == 2) and (W - half_w) or half_w
        local cam   = split_cameras[i]
        local other = split_players[3 - i]
        cam.vw, cam.vh  = vw, H
        renderer.camera = cam
        combat.camera   = cam
        powerups.camera = cam
        g.push()
        g.translate(vx, 0)
        g.setScissor(vx, 0, vw, H)
        renderer:_draw_world()
        rescue:draw()            -- land pads + walking POWs, on the ground under everything
        powerups:draw()
        helis:draw_shadows()     -- aircraft ground shadows, under the flyers
        p:draw_shadow()
        if other then other:draw_remote_shadow(g, cam) end
        p:draw_world()
        combat:draw()
        renderer:draw_debris()   -- shrapnel above the explosion effects
        helis:draw()             -- airborne enemy helicopters
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
            other:draw_remote(g, cam, COOP_COLORS[3 - i])
            p:draw()
        else
            p:draw()
            if other then other:draw_remote(g, cam, COOP_COLORS[3 - i]) end
        end
        p:draw_world_front()
        hud.player          = p
        hud.coplayer        = other
        hud.coplayer_color  = other and COOP_COLORS[3 - i] or nil
        hud.view_w, hud.view_h = vw, H
        hud:draw()
        g.setScissor()
        g.pop()
    end
    -- Center divider
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", half_w - 1, 0, 2, H)
    g.setColor(1, 1, 1)

    if end_stats:is_active() then
        end_stats:draw()
    elseif mission then
        if mission.state == "won" then
            draw_overlay_text("MISSION COMPLETE")
        elseif mission.state == "failed" then
            draw_overlay_text("MISSION FAILED")
        end
    end
end

-- Draw a representative vehicle sprite (chopper body or tank hull+turret),
-- centered and scaled to fit a menu box. skin picks the chopper variant.
local function draw_vehicle_icon(g, vehicle, cx, cy, scale, skin)
    local function img(clip, idx)
        local c = Animation.clip(clip)
        return c and c.frames[idx]
    end
    g.setColor(1, 1, 1)
    if vehicle == "tank" then
        local hull = img("tankbgrn", 1)
        if hull then local w, h = hull:getDimensions(); g.draw(hull, cx, cy, 0, scale, scale, w/2, h/2) end
        local top = img("tanktop", 1)
        if top then
            local ax, ay = Animation.frame_anchor("tanktop", 1)
            g.draw(top, cx, cy, 0, scale, scale, ax, ay)
        end
    else
        local body = img("choppit" .. (skin or 1), 8)   -- neutral pitch frame
        if body then local w, h = body:getDimensions(); g.draw(body, cx, cy, 0, scale, scale, w/2, h/2) end
        local rotor = img("bladep", 1)
        if rotor then local w, h = rotor:getDimensions(); g.draw(rotor, cx, cy, 0, scale, scale, w/2, h/2) end
    end
end

-- One player's vehicle selection box: a square in the player's color holding the
-- current vehicle icon. Each player toggles their own box independently, so both
-- boxes are always live (no cursor / focus).
local function draw_player_box(g, idx, bx, by, bw, bh)
    local col = COOP_COLORS[idx]
    g.setColor(0, 0, 0, 0.5)
    g.rectangle("fill", bx, by, bw, bh)
    g.setColor(col[1], col[2], col[3], 1)
    g.setLineWidth(4)
    g.rectangle("line", bx, by, bw, bh)
    g.setLineWidth(1)
    g.print("PLAYER " .. idx, bx + 8, by + 6)
    draw_vehicle_icon(g, coop_options.vehicle[idx], bx + bw / 2, by + bh / 2 + 6, 2, coop_options.skin[idx])
    g.setColor(1, 1, 1, 1)
    local name = vehicle_label(coop_options.vehicle[idx], coop_options.skin[idx])
    g.print("< " .. name .. " >", bx + bw / 2 - 40, by + bh - 22)
end

local function draw_2p_menu()
    local g      = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 0.85)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    g.setColor(0.5, 0.9, 1, 1)
    local title = "SPLIT SCREEN CO-OP"
    g.print(title, screen_w / 2 - g.getFont():getWidth(title) * 1.5 / 2, screen_h / 2 - 200, 0, 1.5, 1.5)

    local bw, bh = 200, 150
    local gap    = 40
    local boxy   = screen_h / 2 - 150
    draw_player_box(g, 1, screen_w / 2 - bw - gap / 2, boxy, bw, bh)
    draw_player_box(g, 2, screen_w / 2 + gap / 2,      boxy, bw, bh)

    local ty = boxy + bh + 36
    g.setColor(1, 1, 1, 1)
    g.print(string.format("[G] God mode:     < %s >", coop_options.god and "ON" or "OFF"), screen_w / 2 - 120, ty)
    g.print(string.format("[F] Friendly fire: < %s >", coop_options.ff and "ON" or "OFF"), screen_w / 2 - 120, ty + 30)

    g.setColor(0.6, 0.6, 0.6, 1)
    local fy = ty + 78
    g.print("P1 (blue): A/D pick vehicle      P2 (orange): Left/Right pick vehicle", screen_w / 2 - 240, fy)
    g.print("G god mode      F friendly fire      SPACE start      Esc cancel", screen_w / 2 - 240, fy + 22)
    g.print("In game  P1: WASD + L-Shift/L-Ctrl/Q/E    P2: Arrows + R-Shift/R-Ctrl/Num0/NumEnter",
        screen_w / 2 - 240, fy + 46)
    g.setColor(1, 1, 1)
end

local function toggle_vehicle(idx)
    coop_options.vehicle[idx], coop_options.skin[idx] =
        cycle_vehicle(coop_options.vehicle[idx], coop_options.skin[idx])
end

-- animation gallery (test overlay)
-- Plays every clip in data/animations.json at once in a labelled grid so new
-- effects (e.g. the iron/metal debris) can be eyeballed. Non-looping clips are
-- restarted when they finish so they keep playing.

local function gallery_build()
    gallery = { items = {} }
    for _, name in ipairs(Animation.clip_names()) do
        gallery.items[#gallery.items + 1] = { name = name, state = Animation.new(name) }
    end
end

local function gallery_update(dt)
    if not gallery then return end
    for _, it in ipairs(gallery.items) do
        it.state:update(dt)
        if it.state:is_done() then it.state:reset() end
    end
end

local function draw_anim_gallery()
    local g      = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0.06, 0.06, 0.09, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(0.6, 0.9, 1, 1)
    g.print("ANIMATION GALLERY  -  every clip in data/animations.json, looping.   F8 / Esc: close", 10, 8)

    local items = gallery and gallery.items or {}
    local cols  = 8
    local rows  = math.max(1, math.ceil(#items / cols))
    local top   = 30
    local cw, ch = screen_w / cols, (screen_h - top) / rows
    for i, it in ipairs(items) do
        local r  = math.floor((i - 1) / cols)
        local c  = (i - 1) % cols
        local cx = c * cw + cw / 2
        local cy = top + r * ch + (ch - 16) / 2
        g.setColor(1, 1, 1, 0.05)
        g.rectangle("line", c * cw + 2, top + r * ch + 2, cw - 4, ch - 4)
        local img = it.state:current_image()
        if img then
            local iw, ih = img:getDimensions()
            local s = math.max(1, math.min(6, math.min((cw - 16) / iw, (ch - 30) / ih)))
            g.setColor(1, 1, 1, 1)
            g.draw(img, cx, cy, 0, s, s, iw / 2, ih / 2)
        end
        g.setColor(0.8, 0.85, 0.9, 1)
        g.print(it.name, cx - g.getFont():getWidth(it.name) / 2, top + r * ch + ch - 15)
    end
    g.setColor(1, 1, 1)
end

-- font gallery (test overlay)
-- Renders every original bitmap font (assets/fonts/, from tools/export_fonts.py)
-- so glyph decode, mapping, and runtime tinting can be eyeballed. Mask fonts are
-- drawn tinted gold; the truecolor font (OVERKILL) keeps its own palette.

local FONT_SAMPLE = "ABCDEFGHIJKLM NOPQRSTUVWXYZ 0123456789 .,:!?-+"
local FONT_GOLD   = { 1.0, 0.78, 0.20 }

local function draw_font_gallery()
    local g      = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0.06, 0.06, 0.09, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(0.6, 0.9, 1, 1)
    g.print("FONT GALLERY  -  original bitmap fonts, mask fonts tinted gold.   F9 / Esc: close", 10, 8)

    local y     = 40
    local scale = 2
    for _, name in ipairs(Font.NAMES) do
        local font = Font.get(name)
        g.setColor(0.55, 0.6, 0.7, 1)
        g.print(name, 10, y)
        local x = 130
        if font.word then
            font:print_word(x, y, { scale = scale, color = FONT_GOLD })
        else
            font:print(FONT_SAMPLE, x, y, { scale = scale, color = FONT_GOLD })
        end
        y = y + font.line_height * scale + 16
    end
    g.setColor(1, 1, 1)
end

-- overview setup panel
-- Pre-game (overview) UI: vehicle/option setup and the mode-launch keys, grouped
-- into titled boxes. Toggles here also feed the live game (Config compat options).

local OVERVIEW_COLORS = {
    bg    = { 0,    0,    0,    0.82 },
    sect  = { 0.16, 0.18, 0.24, 1    },
    key   = { 0.45, 0.85, 1,    1    },
    label = { 0.80, 0.80, 0.82, 1    },
    value = { 1,    1,    0.35, 1    },
    on    = { 0.35, 0.90, 0.40, 1    },
    off   = { 0.55, 0.55, 0.55, 1    },
    title = { 0.50, 0.90, 1,    1    },
}

local OVERVIEW_PANEL_W = 252
local OVERVIEW_ROW_H   = 17

local function overview_section(g, label, x, y)
    g.setColor(OVERVIEW_COLORS.sect)
    g.rectangle("fill", x, y, OVERVIEW_PANEL_W, 18, 2)
    g.setColor(OVERVIEW_COLORS.title)
    g.print(label, x + 8, y + 2)
    return y + 22
end

local function overview_row(g, key, label, value, vcolor, x, y)
    g.setColor(OVERVIEW_COLORS.key);   g.print(key, x + 8, y)
    g.setColor(OVERVIEW_COLORS.label); g.print(label, x + 78, y)
    if value then
        g.setColor(vcolor or OVERVIEW_COLORS.value)
        local tw = g.getFont():getWidth(value)
        g.print(value, x + OVERVIEW_PANEL_W - tw - 10, y)
    end
    return y + OVERVIEW_ROW_H
end

local function draw_overview_ui()
    local g = love.graphics
    local x = 8
    local y = 30

    -- SETUP box
    local setup_h = 22 + 6 * OVERVIEW_ROW_H + 6
    g.setColor(OVERVIEW_COLORS.bg); g.rectangle("fill", x, y, OVERVIEW_PANEL_W, setup_h, 4)
    local yy = overview_section(g, "SETUP", x, y + 4)
    yy = overview_row(g, "[V]", "Vehicle",   vehicle_label(selected_vehicle, selected_chopper_skin),
          OVERVIEW_COLORS.value, x, yy)
    yy = overview_row(g, "[O]", "Game over", death_enabled and "ON" or "OFF",
          death_enabled and OVERVIEW_COLORS.on or OVERVIEW_COLORS.off, x, yy)
    yy = overview_row(g, "[C]", "Pickups",   Config.axis_aligned_pickups and "AXIS-ALIGNED" or "ROTATED",
          OVERVIEW_COLORS.value, x, yy)
    yy = overview_row(g, "[P]", "POW friendly fire", Config.friendly_fire_pows and "ON" or "OFF",
          Config.friendly_fire_pows and OVERVIEW_COLORS.on or OVERVIEW_COLORS.off, x, yy)
    yy = overview_row(g, "[H]", "HUD scale", string.format("%.2f", Config.hud_scale),
          OVERVIEW_COLORS.value, x, yy)
    overview_row(g, "[ / ]", "Speed",   string.format("%.2f", Config.speed_scale),
          OVERVIEW_COLORS.value, x, yy)

    -- START box
    y = y + setup_h + 6
    local start_h = 22 + 4 * OVERVIEW_ROW_H + 6
    g.setColor(OVERVIEW_COLORS.bg); g.rectangle("fill", x, y, OVERVIEW_PANEL_W, start_h, 4)
    yy = overview_section(g, "START", x, y + 4)
    yy = overview_row(g, "[F1]", "Play",              nil, nil, x, yy)
    yy = overview_row(g, "[F3]", "Sandbox",           nil, nil, x, yy)
    yy = overview_row(g, "[F7]", "2P split screen",   nil, nil, x, yy)
    overview_row(g, "[F8]", "Animation gallery", nil, nil, x, yy)

    -- VIEW box
    y = y + start_h + 6
    local view_h = 22 + 3 * OVERVIEW_ROW_H + 6
    g.setColor(OVERVIEW_COLORS.bg); g.rectangle("fill", x, y, OVERVIEW_PANEL_W, view_h, 4)
    yy = overview_section(g, "VIEW", x, y + 4)
    yy = overview_row(g, "[Tab]/[K]", "stage / kinds",    nil, nil, x, yy)
    yy = overview_row(g, "[L]/[G]",   "segments / grid",  nil, nil, x, yy)
    overview_row(g, "[+/-]",     "zoom",             nil, nil, x, yy)

    g.setColor(1, 1, 1)
end

-- love callbacks

function love.load(args)
    love.graphics.setDefaultFilter("nearest", "nearest")
    Animation.load("data/animations.json")

    for _, fname in ipairs(love.filesystem.getDirectoryItems("data/vehicles")) do
        if fname:match("%.json$") then
            local raw  = love.filesystem.read("data/vehicles/" .. fname)
            local name = fname:match("^(.+)%.json$")
            if raw and name then vehicle_defs[name] = json.decode(raw) end
        end
    end

    world    = World:new()
    world:load(args[1] or world.stages[1])
    camera   = Camera:new(world.stage.world_size)
    renderer = Renderer:new(world, camera)
    debug_panel      = Debug:new(world, camera)
    hud      = Hud:new()
    hud:load("data/hud.json")
    hud.world = world
    hud:set_mission(tonumber(world.stage_name:match("^stage(%d)")) or 0)
    combat   = CombatSystem:new(world, camera)
    combat:load("data/weapons.json")
    helis    = HeliSystem:new(world, combat)
    combat.heli_sys = helis
    Mission.load("data/missions.json")
    powerups = Powerups:new(world, camera, combat.weapons)
    rescue   = RescueSystem:new(world, combat)
    renderer:refresh_kinds()
    love.window.setTitle(world:title())

    screen = Screen:new()
    end_stats = EndStats:new()
    menu = Menu:new()
    menu.on_select = menu_select
    mission_menu = MissionMenu:new()
    mission_menu.on_select = mission_menu_select
    mission_select = MissionSelect:new()
    mission_select.on_select = mission_picker_select
    -- A 1x1 transparent hardware cursor, used to hide the pointer reliably (LOVE's
    -- setVisible(false) is flaky under some Wayland compositors).
    local ok, c = pcall(function() return love.mouse.newCursor(love.image.newImageData(1, 1), 0, 0) end)
    hidden_cursor = ok and c or nil
    -- Hold the menu black behind the title card so the overview never shows
    -- during the intro; open_menu() fades it in once the title is done.
    open_menu()
    menu:hold()
    screen:show("TITLE", { fade_in = 0.6, hold = 2.0, fade_out = 0.6, on_done = open_menu })
end

-- Fire p's current weapon if its reload is up and it has ammo. owner stays the
-- literal "player" so projectiles hit enemies (not the other player) regardless
-- of which of the two fired.
local function fire_for(p)
    local weapon_def = combat.weapons[p.weapon_name]
    if not weapon_def then return end
    if p.fire_timer > 0 then return end
    if not p:has_ammo(p.weapon_name) then return end
    local level = weapon_def.levels and weapon_def.levels[p.weapon_level] or weapon_def
    combat:tick_swing("player", p.weapon_name)
    combat:fire(p.x, p.y, p:fire_angle(), p.weapon_name, "player", p.weapon_level, nil, p)
    p:consume_ammo(p.weapon_name, weapon_def.ammo_cost or 1)
    p.fire_timer = 1.0 / (level.fire_rate or weapon_def.fire_rate or 10)
end

local function _try_fire()
    if not (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then return end
    fire_for(player)
end

-- Cycle p's weapon to the next one valid for its vehicle.
local function cycle_weapon(p)
    local weapon_list = VEHICLE_WEAPONS[p.vehicle] or {}
    if #weapon_list == 0 then return end
    local idx = 1
    for i, w in ipairs(weapon_list) do
        if w == p.weapon_name then idx = i; break end
    end
    p.weapon_name  = weapon_list[idx % #weapon_list + 1]
    p.weapon_level = 1
    p.fire_timer   = 0
end

-- Toggle a flyer between airborne and grounded; no-op for a tank.
local function toggle_land(p)
    if p.land_state == "airborne" then
        p:land()
    elseif p.land_state == "grounded" then
        p:take_off()
    end
end

function love.update(dt)
    if screen then screen:update(dt) end
    if menu and menu:is_active() then menu:update(dt); return end
    if mission_menu and mission_menu:is_active() then mission_menu:update(dt); return end
    if mission_select and mission_select:is_active() then mission_select:update(dt); return end
    if anim_gallery then gallery_update(dt); return end
    if font_gallery then return end
    if paused then return end
    if split_mode then
        if end_stats:is_active() then
            end_stats:update(dt)
            world:update(dt)
            return
        end
        for _, p in ipairs(split_players) do
            p:update(dt)
            if not p.death and p:_held("fire") then fire_for(p) end
            if death_enabled and not p.death and p:is_dead() then p:start_death() end
        end
        for i, p in ipairs(split_players) do
            local c = split_cameras[i]
            c.x, c.y = p.x, p.y
            c.angle  = p:camera_angle()
        end
        combat:update(dt)
        helis:update(dt)
        powerups:update(dt)
        rescue:update(dt)
        if mission then mission:update(dt) end
        if mission and mission.state == "won" then
            if won_timer == nil then won_timer = 1.5 end
            if won_timer > 0 then
                won_timer = won_timer - dt
            elseif not end_stats_started then
                end_stats:start(collect_coop_stats())
                end_stats_started = true
            end
        end
        world:update(dt)
        return
    end
    if game_mode and player then
        if end_stats:is_active() then
            end_stats:update(dt)
            world:update(dt)
            return
        end
        player:update(dt)
        if death_enabled and not player.death and player:is_dead() then
            player:start_death()
        end
        -- After the crash animation finishes, wait ~3s then bring up the end
        -- picture (DEATHPIC for the chopper, TANKEND for the tank); a key restarts.
        if player:death_done() and not screen:is_active() then
            if death_timer == nil then
                death_timer = 3.0
            elseif death_timer > 0 then
                death_timer = death_timer - dt
                if death_timer <= 0 then
                    death_timer = 0
                    local pic = (player.vehicle == "tank") and "TANKEND" or "DEATHPIC"
                    screen:show(pic, { fade_in = 0.6, wait_key = true, on_done = restart_level })
                end
            end
        end
        if not player.death then _try_fire() end
        combat:update(dt)
        helis:update(dt)
        powerups:update(dt)
        rescue:update(dt)
        if mission then mission:update(dt) end
        -- Mission won: hold MISSION COMPLETE briefly, then the DESTRUCTION STATS.
        if mission and mission.state == "won" then
            if won_timer == nil then won_timer = 1.5 end
            if won_timer > 0 then
                won_timer = won_timer - dt
            elseif not end_stats_started then
                end_stats:start(collect_stats())
                end_stats_started = true
            end
        end
        camera.x     = player.x
        camera.y     = player.y
        camera.angle = player:camera_angle()
        camera:tick_zoom(dt)
        if pending_takeoff and not camera.zoom_anim then
            player:take_off()   -- no-op for the tank
            pending_takeoff = false
        end
    else
        if not renderer.picker and not renderer.kind_picker and not coop_setup_open
        and not debug_panel:captures_arrows() then
            camera:update(dt)
        end
    end
    world:update(dt)
    debug_panel:update()

    if sandbox_status_timer > 0 then
        sandbox_status_timer = sandbox_status_timer - dt
        if sandbox_status_timer <= 0 then
            sandbox_status   = ""
            sandbox_status_timer = 0
        end
    end
end

function love.draw()
    -- Hide the OS cursor while a non-game screen owns the pointer (we draw the
    -- original SELPOINT cursor instead); restore it for gameplay.
    local ui = (menu and menu:is_active()) or (mission_menu and mission_menu:is_active())
        or (mission_select and mission_select:is_active())
        or end_stats:is_active() or (screen and screen:is_active())
    if hidden_cursor then
        if ui then love.mouse.setCursor(hidden_cursor) else love.mouse.setCursor() end
    else
        love.mouse.setVisible(not ui)
    end

    -- A passive image overlay (title / briefing / crash) is up front: no cursor,
    -- even over a held menu (the intro card holds the menu black behind it).
    local overlay = screen and screen:is_active()

    if menu and menu:is_active() then
        menu:draw()
        if screen then screen:draw() end
        if not overlay then Pointer.draw() end
        return
    end
    if mission_menu and mission_menu:is_active() then
        mission_menu:draw()
        if screen then screen:draw() end
        if not overlay then Pointer.draw() end
        return
    end
    if mission_select and mission_select:is_active() then
        mission_select:draw()
        if not overlay then Pointer.draw() end
        return
    end
    if anim_gallery then
        draw_anim_gallery()
        return
    end
    if font_gallery then
        draw_font_gallery()
        return
    end
    if split_mode then
        draw_split()
        if paused then draw_pause() end
        if screen then screen:draw() end
        if end_stats:is_active() then Pointer.draw() end
        return
    end

    renderer.highlight = debug_panel:highlight_entity()
    renderer:draw()

    if game_mode and player then
        rescue:draw()            -- land pads + walking POWs, on the ground under everything
        powerups:draw()
        helis:draw_shadows()     -- aircraft ground shadows, under the flyers
        player:draw_shadow()
        player:draw_world()
        combat:draw()
        renderer:draw_debris()   -- shrapnel above the explosion effects
        helis:draw()             -- airborne enemy helicopters
        player:draw()
        player:draw_world_front()
        hud:draw()
        if mission and mission.state == "return_to_base" then draw_return_prompt() end
        if mission and mission.state == "won" and not end_stats:is_active() then draw_victory() end
        if mission and mission.state == "failed" then draw_game_over() end
        if end_stats:is_active() then end_stats:draw() end
        if paused then draw_pause() end
        if sandbox_mode then
            draw_sandbox_panel()
        end
    else
        renderer:draw_debris()   -- shrapnel above any explosion (e.g. F2 kills)
        draw_overview_ui()
    end

    if coop_setup_open then draw_2p_menu() end
    debug_panel:draw()
    if screen then screen:draw() end
    if end_stats:is_active() then Pointer.draw() end
end

function love.wheelmoved(_, dy)
    if not renderer.picker and not renderer.kind_picker then
        camera:on_wheel(dy)
    end
end

function love.keypressed(key)
    -- A fullscreen overlay (title / briefing / crash picture) swallows input. Esc
    -- skips the image immediately and drops back to the overview; a wait_key
    -- picture (the crash end screen) otherwise advances on any key.
    if screen and screen:is_active() then
        if key == "escape" then
            -- A screen launched from the menu (menu held black behind it) just backs
            -- out to the menu; otherwise Esc skips it and drops back to the game.
            if menu and menu:is_active() then
                screen:cancel()
                open_menu()
            else
                screen:cancel()
                if split_mode then leave_split() elseif game_mode then leave_game_mode() end
            end
            return
        end
        screen:keypressed(key)
        return
    end

    -- Main menu: Escape backs out to the running game if there is one (same as
    -- selecting RESUME); otherwise it's swallowed so the menu stays up front.
    -- The F8/F9 dev overlays stay reachable: they close the menu, fall through to
    -- the openers below, and reopen it on exit.
    if menu and menu:is_active() then
        if key == "escape" then
            if game_mode then menu:close() end
            return
        end
        if (key == "f8" or key == "f9") and not game_mode and not split_mode then
            menu:close()
        else
            menu:keypressed(key)  -- confirmed entries dispatch via menu.on_select
            return
        end
    end

    -- Mission menu: arrows move between buttons, Enter confirms, Esc backs out
    -- (dispatched via mission_menu.on_select).
    if mission_menu and mission_menu:is_active() then
        mission_menu:keypressed(key)
        return
    end

    -- Mission-select (debug): left/right pick the mission, 1-4/up-down the phase,
    -- Enter plays, Esc backs out (dispatched via mission_select.on_select).
    if mission_select and mission_select:is_active() then
        mission_select:keypressed(key)
        return
    end

    -- Animation gallery test overlay: F8 toggles it from the overview, Esc/F8
    -- close. Closing returns to the main menu it was opened from.
    if anim_gallery then
        if key == "f8" or key == "escape" then anim_gallery = false; open_menu() end
        return
    end
    if font_gallery then
        if key == "f9" or key == "escape" then font_gallery = false; open_menu() end
        return
    end
    if key == "f8" and not game_mode and not split_mode then
        if not gallery then gallery_build() end
        anim_gallery = true
        return
    end
    if key == "f9" and not game_mode and not split_mode then
        font_gallery = true
        return
    end

    -- 2P setup menu. Each player toggles their own vehicle with their own keys at
    -- any time (no cursor); G/F toggle god/friendly-fire; SPACE starts.
    if coop_setup_open then
        if     key == "escape" then coop_setup_open = false
        elseif key == "space"  then enter_split()
        elseif key == "g"      then coop_options.god = not coop_options.god
        elseif key == "f"      then coop_options.ff  = not coop_options.ff
        elseif key == P1_CONTROLS.left or key == P1_CONTROLS.right then toggle_vehicle(1)
        elseif key == P2_CONTROLS.left or key == P2_CONTROLS.right then toggle_vehicle(2)
        end
        return
    end

    -- Split-screen game keys.
    if split_mode then
        if end_stats:is_active() then
            if key == "escape" then
                end_stats:keypressed(); end_stats.active = false; leave_split()
            elseif end_stats:keypressed() and not end_stats:is_active() then
                leave_split()
            end
            return
        end
        if key == "escape" or key == "f1" then leave_split(); return end
        if key == "p" then paused = not paused; return end
        if key == "r" then paused = false; enter_split(); return end
        if key == "f5" then
            coop_options.god = not coop_options.god
            for _, p in ipairs(split_players) do p.unlimited = coop_options.god end
            return
        end
        if key == "f6" then powerups.easy_mode = not powerups.easy_mode; return end
        for _, p in ipairs(split_players) do
            if key == p.controls.weapon then cycle_weapon(p) end
            if key == p.controls.action then toggle_land(p) end
        end
        return
    end

    if key == "f7" and not game_mode then
        coop_setup_open = true
        return
    end

    if key == "f2" then
        debug_panel:toggle()
        return
    end

    if debug_panel.enabled then
        if debug_panel:keypressed(key) then return end
    end

    -- sandbox key handling (before game mode keys so F3/F4 are caught first)
    if sandbox_mode then
        if key == "f3" then leave_sandbox(); return end
        if key == "f4" then sandbox_save(); return end
        if key == "[" then
            sandbox_cursor = ((sandbox_cursor - 2) % #SANDBOX_PARAMS) + 1
            return
        end
        if key == "]" then
            sandbox_cursor = sandbox_cursor % #SANDBOX_PARAMS + 1
            return
        end
        if key == "=" or key == "kp+" then sandbox_adjust( 1); return end
        if key == "-" or key == "kp-" then sandbox_adjust(-1); return end
        -- fall through to game keys for movement (WASD, Space, etc.)
    end

    if key == "f1" then
        if game_mode then leave_game_mode() else begin_game_mode() end
        return
    end
    if key == "f3" and not game_mode then
        enter_sandbox()
        return
    end

    if game_mode and player then
        if end_stats:is_active() then
            if key == "escape" then
                end_stats:keypressed(); end_stats.active = false; leave_game_mode()
            elseif end_stats:keypressed() and not end_stats:is_active() then
                leave_game_mode()
            end
            return
        end
        if key == "p"  then paused = not paused; return end
        if key == "r"  then paused = false; restart_level(); return end
        if key == "f5" then player.unlimited = not player.unlimited; return end
        if key == "f6" then powerups.easy_mode = not powerups.easy_mode; return end
        if key == "space" or key == "f" then
            if player.land_state == "airborne" then
                player:land()
            elseif player.land_state == "grounded" then
                player:take_off()
            end
            return
        end
        if key == "q" then
            local weapon_list = VEHICLE_WEAPONS[player.vehicle] or {}
            local idx = 1
            for i, w in ipairs(weapon_list) do
                if w == player.weapon_name then idx = i; break end
            end
            idx = idx % #weapon_list + 1
            player.weapon_name  = weapon_list[idx]
            player.weapon_level = 1
            player.fire_timer   = 0
            sync_weapon_icon()
            return
        end
        if key == "e" then
            local weapon_def = combat.weapons[player.weapon_name]
            if weapon_def and weapon_def.levels then
                player.weapon_level = player.weapon_level % #weapon_def.levels + 1
            end
            return
        end
    end

    if renderer.kind_picker then
        if key == "escape" or key == "k" then
            renderer.kind_picker = false
        else
            renderer:on_kind_picker_key(key)
        end
        return
    end

    if renderer.picker then
        if key == "escape" or key == "tab" then
            renderer.picker = false
        elseif key == "up" then
            world.stage_index = (world.stage_index - 2) % #world.stages + 1
        elseif key == "down" then
            world.stage_index = world.stage_index % #world.stages + 1
        elseif key == "return" then
            renderer.picker = false
            world:load(world.stages[world.stage_index])
            after_stage_load()
        end
        return
    end

    if key == "escape" then
        open_menu()
        return
    end
    if key == "tab"    then renderer.picker      = true end
    if key == "k"      then renderer:toggle_kind_picker() end

    if key == "pagedown" then
        world:load_index(world.stage_index % #world.stages + 1)
        after_stage_load()
    end
    if key == "pageup" then
        world:load_index((world.stage_index - 2) % #world.stages + 1)
        after_stage_load()
    end

    if not game_mode then
        if key == "v" then
            selected_vehicle, selected_chopper_skin = cycle_vehicle(selected_vehicle, selected_chopper_skin)
        end
        if key == "o" then death_enabled = not death_enabled end
        if key == "c" then Config.axis_aligned_pickups = not Config.axis_aligned_pickups end
        if key == "p" then Config.friendly_fire_pows = not Config.friendly_fire_pows end
        if key == "h" then
            local steps = { 1.0, 1.25, 1.5, 2.0, 2.5 }
            local i = 1
            for k, v in ipairs(steps) do if math.abs(v - Config.hud_scale) < 0.01 then i = k end end
            Config.hud_scale = steps[i % #steps + 1]
        end
        if key == "[" then Config.speed_scale = math.max(0.1, Config.speed_scale - 0.05) end
        if key == "]" then Config.speed_scale = math.min(2.0, Config.speed_scale + 0.05) end
        if key == "l" then renderer.show_segments = not renderer.show_segments end
        if key == "g" then renderer.show_grid     = not renderer.show_grid     end
        if key == "+" or key == "=" or key == "kp+" then camera:set_zoom(camera.zoom_index + 1) end
        if key == "-" or key == "kp-"               then camera:set_zoom(camera.zoom_index - 1) end
    end
end

-- Route a pointer move to whichever menu is up (hover-to-focus).
local function ui_pointer_moved(x, y)
    if menu and menu:is_active() then
        menu:hover(x, y)
    elseif mission_menu and mission_menu:is_active() then
        mission_menu:hover(x, y)
    elseif mission_select and mission_select:is_active() then
        mission_select:hover(x, y)
    end
end

-- Pointer down: arm the widget under the pointer. A passive overlay / end-stats
-- screen advances on release, so here we only consume the press.
local function ui_pointer_pressed(x, y)
    if screen and screen:is_active() then return true end
    if menu and menu:is_active() then menu:press(x, y); return true end
    if mission_menu and mission_menu:is_active() then mission_menu:press(x, y); return true end
    if mission_select and mission_select:is_active() then mission_select:press(x, y); return true end
    if end_stats:is_active() then return true end
    return false
end

-- Pointer up: fire the armed widget, or advance a passive overlay / end-stats
-- screen (mirrors the keyboard paths in love.keypressed). Screen is checked
-- first so a click still advances an overlay shown over a held menu.
local function ui_pointer_released(x, y)
    if screen and screen:is_active() then screen:keypressed(); return true end
    if menu and menu:is_active() then menu:release(x, y); return true end
    if mission_menu and mission_menu:is_active() then mission_menu:release(x, y); return true end
    if mission_select and mission_select:is_active() then mission_select:release(x, y); return true end
    if end_stats:is_active() then
        if end_stats:keypressed() and not end_stats:is_active() then
            if split_mode then leave_split() elseif game_mode then leave_game_mode() end
        end
        return true
    end
    return false
end

function love.mousemoved(x, y)
    Pointer.moved(x, y, false)
    ui_pointer_moved(x, y)
end

function love.mousepressed(x, y, button)
    debug_panel:mousepressed(x, y, button)
    if button == 1 then
        Pointer.moved(x, y, false)
        ui_pointer_pressed(x, y)
    end
end

function love.mousereleased(x, y, button)
    if button == 1 then
        Pointer.moved(x, y, false)
        ui_pointer_released(x, y)
    end
end

-- Touch mirrors the mouse (primary/each touch acts as the pointer); Pointer is
-- told it's touch so it suppresses the cursor sprite (the finger is the pointer).
function love.touchmoved(_, x, y)
    Pointer.moved(x, y, true)
    ui_pointer_moved(x, y)
end

function love.touchpressed(_, x, y)
    Pointer.moved(x, y, true)
    ui_pointer_pressed(x, y)
end

function love.touchreleased(_, x, y)
    Pointer.moved(x, y, true)
    ui_pointer_released(x, y)
end
