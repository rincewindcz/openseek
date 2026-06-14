local World        = require "engine.world"
local Camera       = require "engine.camera"
local Renderer     = require "engine.renderer"
local Debug        = require "engine.debug"
local Animation    = require "engine.animation"
local Player       = require "engine.player"
local Hud          = require "engine.hud"
local CombatSystem = require "engine.combat"
local Powerups     = require "engine.powerups"
local Mission      = require "engine.mission"
local json         = require "lib.json"

local world
local camera
local renderer
local dbg
local hud
local player
local combat
local powerups
local mission
local game_mode    = false
local sandbox_mode = false
local death_enabled = false   -- optional game-over (chopper falls, tank burns)
local paused        = false
local sel_vehicle  = "chopper"
local viewer_zi    = 4
local vehicle_defs = {}

-- ── split-screen two-player (extra mode, not in the original game) ───────────────
local split_mode  = false
local menu_open   = false          -- the 2P setup menu overlay
local sp_players  = {}             -- two Player instances
local sp_cameras  = {}             -- two Camera instances, one per screen half
local mp_setup    = { vehicle = { "chopper", "tank" }, god = false, ff = false }
local MP_COLORS   = { { 0.30, 0.65, 1.0 }, { 1.0, 0.55, 0.15 } }  -- P1 blue, P2 orange

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
  local wdef = combat.weapons[player.weapon_name]
  player.weapon_icon = wdef and wdef.icon or 0
end

-- ── sandbox UI ────────────────────────────────────────────────────────────────

local SB_PARAMS = {
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
local sb_cursor   = 1
local sb_status   = ""
local sb_status_t = 0

local function sb_apply()
  if not player then return end
  local def = vehicle_defs[sel_vehicle]
  if def then player:load_vehicle_def(def) end
end

local function sb_adjust(dir)
  local def = vehicle_defs[sel_vehicle]
  if not def then return end
  local p = SB_PARAMS[sb_cursor]
  def[p.name] = (def[p.name] or 0) + dir * p.step
  sb_apply()
end

local function sb_save()
  local def = vehicle_defs[sel_vehicle]
  if not def then return end
  local src  = love.filesystem.getSource()
  local path = src .. "/data/vehicles/" .. sel_vehicle .. ".json"
  local f    = io.open(path, "w")
  if not f then
    sb_status   = "ERROR: cannot write"
    sb_status_t = 3
    return
  end
  f:write("{\n")
  local keys = {}
  for k in pairs(def) do keys[#keys + 1] = k end
  table.sort(keys)
  for i, k in ipairs(keys) do
    local v  = def[k]
    local vs = type(v) == "number" and string.format("%.4g", v) or tostring(v)
    f:write(string.format('  "%s": %s%s\n', k, vs, i < #keys and "," or ""))
  end
  f:write("}\n")
  f:close()
  sb_status   = "Saved!"
  sb_status_t = 2
end

local function draw_sandbox_panel()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  local pw     = 220
  local ph     = #SB_PARAMS * 18 + 58
  local bx     = sw - pw - 4
  local by     = 30

  g.setColor(0, 0, 0, 0.88)
  g.rectangle("fill", bx, by, pw, ph, 4)
  g.setColor(0.3, 0.9, 0.3, 1)
  g.print("SANDBOX: " .. sel_vehicle, bx + 8, by + 6)

  local def = vehicle_defs[sel_vehicle] or {}
  for i, p in ipairs(SB_PARAMS) do
    local y = by + 24 + (i - 1) * 18
    if i == sb_cursor then
      g.setColor(0.2, 0.5, 1, 0.3)
      g.rectangle("fill", bx + 2, y - 1, pw - 4, 18)
      g.setColor(1, 1, 0, 1)
    else
      g.setColor(0.75, 0.75, 0.75, 1)
    end
    local val = def[p.name]
    local vs  = val ~= nil and string.format("%.4g", val) or "?"
    g.print(string.format("%-16s %6s", p.name, vs), bx + 8, y)
  end

  g.setColor(0.45, 0.45, 0.45, 1)
  g.print("[/] nav  +/- adj  F4 save  F3 exit", bx + 4, by + ph - 18)

  if sb_status ~= "" then
    g.setColor(0.1, 1, 0.4, 1)
    g.print(sb_status, bx + 8, by + ph + 4)
  end
end

local function draw_overlay_text(title, hint, title_color)
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  g.setColor(0, 0, 0, 0.55)
  g.rectangle("fill", 0, 0, sw, sh)
  g.setColor(title_color[1], title_color[2], title_color[3], 1)
  local font = g.getFont()
  g.print(title, (sw - font:getWidth(title) * 3) / 2, sh / 2 - 40, 0, 3, 3)
  if hint then
    g.setColor(1, 1, 1, 0.9)
    g.print(hint, (sw - font:getWidth(hint)) / 2, sh / 2 + 16)
  end
  g.setColor(1, 1, 1)
end

local function draw_pause()
  draw_overlay_text("PAUSE", "P - resume", { 0.6, 0.8, 1 })
end

local function draw_game_over()
  draw_overlay_text("GAME OVER", "R - restart level     F1 - exit to overview", { 1, 0.25, 0.2 })
end

local function draw_victory()
  draw_overlay_text("MISSION COMPLETE", "R - restart level     F1 - exit to overview", { 0.4, 1, 0.5 })
end

-- ── mode transitions ──────────────────────────────────────────────────────────

local function after_stage_load()
  camera.world_size = world.stage.world_size
  camera:clamp()
  renderer:refresh_kinds()
  dbg.world = world
  hud.world = world
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
  player.vehicle      = sel_vehicle
  player.world        = world
  player.camera       = camera
  local def = vehicle_defs[sel_vehicle]
  if def then player:load_vehicle_def(def) end
  local wlist = VEHICLE_WEAPONS[sel_vehicle]
  if wlist then player.weapon_name = wlist[1] end
  player:seed_ammo(combat.weapons)
  sync_weapon_icon()
  local _, sh = love.graphics.getDimensions()
  camera.view_oy = sh * 0.24
  hud.player    = player
  combat.player = player
  combat.players = { player }
  combat.projectiles = {}
  combat.effects     = {}
  powerups:reset(player)
  mission = Mission.for_stage(world, player, world.stage_name)
  player:take_off()   -- chopper lifts off automatically; no-op for the tank
end

local function enter_game_mode()
  viewer_zi  = camera.zi
  game_mode  = true
  paused     = false
  renderer.in_game = true
  camera:set_zoom(6)
  spawn_player()
  love.window.setTitle(world:title() .. "  [" .. sel_vehicle .. "]")
end

-- Reload the current stage and respawn the player (R in game mode).
local function restart_level()
  local name = world.stage_name
  world:load(name)
  after_stage_load()
  spawn_player()
  love.window.setTitle(world:title() .. "  [" .. sel_vehicle .. "]")
end

local function leave_game_mode()
  game_mode         = false
  sandbox_mode      = false
  paused            = false
  renderer.in_game  = false
  player            = nil
  hud.player        = nil
  combat.player     = nil
  combat.players    = {}
  combat.projectiles = {}
  combat.effects     = {}
  powerups:reset(nil)
  mission           = nil
  camera.angle      = nil
  camera.view_oy    = 0
  camera:set_zoom(viewer_zi)
  love.window.setTitle(world:title())
end

local function enter_sandbox()
  if not game_mode then enter_game_mode() end
  sandbox_mode = true
  love.window.setTitle(world:title() .. "  [sandbox:" .. sel_vehicle .. "]")
end

local function leave_sandbox()
  leave_game_mode()
end

-- ── split-screen two-player mode ────────────────────────────────────────────────

local function make_split_player(idx, sx, sy)
  local p = Player:new(sx, sy)
  p.world_size = world.stage.world_size
  p.vehicle    = mp_setup.vehicle[idx]
  p.world      = world
  p.controls   = (idx == 1) and P1_CONTROLS or P2_CONTROLS
  local def = vehicle_defs[p.vehicle]
  if def then p:load_vehicle_def(def) end
  local wlist = VEHICLE_WEAPONS[p.vehicle]
  if wlist then p.weapon_name = wlist[1] end
  p:seed_ammo(combat.weapons)
  p.unlimited = mp_setup.god
  return p
end

local function enter_split()
  viewer_zi  = camera.zi
  menu_open  = false
  split_mode = true
  game_mode  = false
  paused     = false
  renderer.in_game = true

  local sx, sy = world:player_start()
  sp_players = {
    make_split_player(1, sx - 40, sy),
    make_split_player(2, sx + 40, sy),
  }
  sp_cameras = { Camera:new(world.stage.world_size), Camera:new(world.stage.world_size) }
  local _, sh = love.graphics.getDimensions()
  for i, p in ipairs(sp_players) do
    local c = sp_cameras[i]
    c:set_zoom(6)
    c.view_oy = sh * 0.24
    c.x, c.y  = p.x, p.y
    c.angle   = p:camera_angle()
    p.camera  = c
    p:take_off()   -- choppers lift off; no-op for the tank
  end

  combat.players      = sp_players
  combat.player       = sp_players[1]
  combat.friendly_fire = mp_setup.ff
  combat.projectiles  = {}
  combat.effects      = {}
  powerups:set_players(sp_players)
  -- Shared co-op objective from the stage's decoded objectives (nil = free play).
  mission = Mission.coop(world, sp_players)
  love.window.setTitle(world:title() .. "  [2P SPLIT]")
end

local function leave_split()
  split_mode       = false
  renderer.in_game = false
  renderer.camera  = camera
  combat.camera    = camera
  powerups.camera  = camera
  combat.players   = {}
  combat.player    = nil
  combat.friendly_fire = false
  combat.projectiles = {}
  combat.effects     = {}
  powerups:reset(nil)
  hud.player = nil
  hud.coplayer, hud.coplayer_color = nil, nil
  hud.view_w, hud.view_h = nil, nil
  sp_players = {}
  sp_cameras = {}
  camera.angle   = nil
  camera.view_oy = 0
  camera:set_zoom(viewer_zi)
  love.window.setTitle(world:title())
end

local function draw_split()
  local g    = love.graphics
  local W, H = g.getDimensions()
  local hw   = math.floor(W / 2)
  for i, p in ipairs(sp_players) do
    local vx    = (i - 1) * hw
    local vw    = (i == 2) and (W - hw) or hw
    local cam   = sp_cameras[i]
    local other = sp_players[3 - i]
    cam.vw, cam.vh  = vw, H
    renderer.camera = cam
    combat.camera   = cam
    powerups.camera = cam
    g.push()
    g.translate(vx, 0)
    g.setScissor(vx, 0, vw, H)
    renderer:_draw_world()
    powerups:draw()
    p:draw_world()
    combat:draw()
    -- Draw both vehicles back-to-front by world y so the southern one is on top,
    -- identically in both halves (the local one is centered, the teammate placed
    -- by projection). Without this the teammate always covered the local player.
    if other and other.y < p.y then
      other:draw_remote(g, cam, MP_COLORS[3 - i])
      p:draw()
    else
      p:draw()
      if other then other:draw_remote(g, cam, MP_COLORS[3 - i]) end
    end
    p:draw_world_front()
    hud.player          = p
    hud.coplayer        = other
    hud.coplayer_color  = other and MP_COLORS[3 - i] or nil
    hud.view_w, hud.view_h = vw, H
    hud:draw()
    g.setScissor()
    g.pop()

    -- Per-half status line (screen space, above the viewport), in player color.
    local wdef = combat.weapons[p.weapon_name]
    local ammo = p.ammo[p.weapon_name]
    local col  = MP_COLORS[i]
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", vx, 0, vw, 20)
    g.setColor(col[1], col[2], col[3], 1)
    g.print(string.format("P%d %s   %s:%s   PTS:%d%s", i, p.vehicle,
      (wdef and wdef.short) or "?", ammo and tostring(ammo) or "inf",
      p.score or 0, p.unlimited and "   [GOD]" or ""), vx + 6, 3)
    g.setColor(1, 1, 1)
  end
  -- Center divider
  g.setColor(0, 0, 0, 1)
  g.rectangle("fill", hw - 1, 0, 2, H)
  g.setColor(1, 1, 1)

  -- Shared co-op objective banner (top center, spanning both halves).
  if mission then
    local line = mission:status_line()
    local tw   = g.getFont():getWidth(line)
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", W / 2 - tw / 2 - 10, 22, tw + 20, 20)
    g.setColor(1, 1, 0.4, 1)
    g.print(line, W / 2 - tw / 2, 25)
    g.setColor(1, 1, 1)
    if mission.state == "won" then
      draw_overlay_text("MISSION COMPLETE", "R - restart    F1 - exit", { 0.4, 1, 0.5 })
    elseif mission.state == "failed" then
      draw_overlay_text("MISSION FAILED", "R - restart    F1 - exit", { 1, 0.25, 0.2 })
    end
  end
end

-- Draw a representative vehicle sprite (chopper body or tank hull+turret),
-- centered and scaled to fit a menu box.
local function draw_vehicle_icon(g, vehicle, cx, cy, scale)
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
    local body = img("choppit1", 8)   -- neutral pitch frame
    if body then local w, h = body:getDimensions(); g.draw(body, cx, cy, 0, scale, scale, w/2, h/2) end
    local rotor = img("bladep", 1)
    if rotor then local w, h = rotor:getDimensions(); g.draw(rotor, cx, cy, 0, scale, scale, w/2, h/2) end
  end
end

-- One player's vehicle selection box: a square in the player's color holding the
-- current vehicle icon. Each player toggles their own box independently, so both
-- boxes are always live (no cursor / focus).
local function draw_player_box(g, idx, bx, by, bw, bh)
  local col = MP_COLORS[idx]
  g.setColor(0, 0, 0, 0.5)
  g.rectangle("fill", bx, by, bw, bh)
  g.setColor(col[1], col[2], col[3], 1)
  g.setLineWidth(4)
  g.rectangle("line", bx, by, bw, bh)
  g.setLineWidth(1)
  g.print("PLAYER " .. idx, bx + 8, by + 6)
  draw_vehicle_icon(g, mp_setup.vehicle[idx], bx + bw / 2, by + bh / 2 + 6, 2)
  g.setColor(1, 1, 1, 1)
  local name = mp_setup.vehicle[idx]:upper()
  g.print("< " .. name .. " >", bx + bw / 2 - 40, by + bh - 22)
end

local function draw_2p_menu()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  g.setColor(0, 0, 0, 0.85)
  g.rectangle("fill", 0, 0, sw, sh)

  g.setColor(0.5, 0.9, 1, 1)
  local title = "SPLIT SCREEN CO-OP"
  g.print(title, sw / 2 - g.getFont():getWidth(title) * 1.5 / 2, sh / 2 - 200, 0, 1.5, 1.5)

  local bw, bh = 200, 150
  local gap    = 40
  local boxy   = sh / 2 - 150
  draw_player_box(g, 1, sw / 2 - bw - gap / 2, boxy, bw, bh)
  draw_player_box(g, 2, sw / 2 + gap / 2,      boxy, bw, bh)

  local ty = boxy + bh + 36
  g.setColor(1, 1, 1, 1)
  g.print(string.format("[G] God mode:     < %s >", mp_setup.god and "ON" or "OFF"), sw / 2 - 120, ty)
  g.print(string.format("[F] Friendly fire: < %s >", mp_setup.ff and "ON" or "OFF"), sw / 2 - 120, ty + 30)

  g.setColor(0.6, 0.6, 0.6, 1)
  local fy = ty + 78
  g.print("P1 (blue): A/D pick vehicle      P2 (orange): Left/Right pick vehicle", sw / 2 - 240, fy)
  g.print("G god mode      F friendly fire      SPACE start      Esc cancel", sw / 2 - 240, fy + 22)
  g.print("In game  P1: WASD + L-Shift/L-Ctrl/Q/E    P2: Arrows + R-Shift/R-Ctrl/Num0/NumEnter",
    sw / 2 - 240, fy + 46)
  g.setColor(1, 1, 1)
end

local function toggle_vehicle(idx)
  mp_setup.vehicle[idx] = (mp_setup.vehicle[idx] == "chopper") and "tank" or "chopper"
end

-- ── love callbacks ────────────────────────────────────────────────────────────

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
  dbg      = Debug:new(world, camera)
  hud      = Hud:new()
  hud:load("data/hud.json")
  hud.world = world
  combat   = CombatSystem:new(world, camera)
  combat:load("data/weapons.json")
  Mission.load("data/missions.json")
  powerups = Powerups:new(world, camera, combat.weapons)
  renderer:refresh_kinds()
  love.window.setTitle(world:title())
end

-- Fire p's current weapon if its reload is up and it has ammo. owner stays the
-- literal "player" so projectiles hit enemies (not the other player) regardless
-- of which of the two fired.
local function fire_for(p, dt)
  local wdef = combat.weapons[p.weapon_name]
  if not wdef then return end
  if p.fire_timer > 0 then return end
  if not p:has_ammo(p.weapon_name) then return end
  local level = wdef.levels and wdef.levels[p.weapon_level] or wdef
  combat:tick_swing("player", p.weapon_name)
  combat:fire(p.x, p.y, p:fire_angle(), p.weapon_name, "player", p.weapon_level, nil, p)
  p:consume_ammo(p.weapon_name, wdef.ammo_cost or 1)
  p.fire_timer = 1.0 / (level.fire_rate or wdef.fire_rate or 10)
end

local function _try_fire(dt)
  if not (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then return end
  fire_for(player, dt)
end

-- Cycle p's weapon to the next one valid for its vehicle.
local function cycle_weapon(p)
  local wlist = VEHICLE_WEAPONS[p.vehicle] or {}
  if #wlist == 0 then return end
  local idx = 1
  for i, w in ipairs(wlist) do
    if w == p.weapon_name then idx = i; break end
  end
  p.weapon_name  = wlist[idx % #wlist + 1]
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
  if paused then return end
  if split_mode then
    for _, p in ipairs(sp_players) do
      p:update(dt)
      if not p.death and p:_held("fire") then fire_for(p, dt) end
      if death_enabled and not p.death and p:is_dead() then p:start_death() end
    end
    for i, p in ipairs(sp_players) do
      local c = sp_cameras[i]
      c.x, c.y = p.x, p.y
      c.angle  = p:camera_angle()
    end
    combat:update(dt)
    powerups:update(dt)
    if mission then mission:update(dt) end
    world:update(dt)
    return
  end
  if game_mode and player then
    player:update(dt)
    if death_enabled and not player.death and player:is_dead() then
      player:start_death()
    end
    if not player.death then _try_fire(dt) end
    combat:update(dt)
    powerups:update(dt)
    if mission then mission:update(dt) end
    camera.x     = player.x
    camera.y     = player.y
    camera.angle = player:camera_angle()
  else
    if not renderer.picker and not renderer.kind_picker and not menu_open then
      camera:update(dt)
    end
  end
  world:update(dt)
  dbg:update()

  if sb_status_t > 0 then
    sb_status_t = sb_status_t - dt
    if sb_status_t <= 0 then
      sb_status   = ""
      sb_status_t = 0
    end
  end
end

function love.draw()
  if split_mode then
    draw_split()
    if paused then draw_pause() end
    return
  end

  renderer.highlight = dbg.enabled and (dbg.selected or dbg.hovered) or nil
  renderer:draw()

  if game_mode and player then
    powerups:draw()
    player:draw_world()
    combat:draw()
    player:draw()
    player:draw_world_front()
    hud:draw()
    -- Weapon indicator (top-left, below renderer bar)
    local g = love.graphics
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 22, 470, 20)
    g.setColor(1, 1, 0.2, 1)
    local wdef   = combat.weapons[player.weapon_name]
    local n_lvl  = wdef and wdef.levels and #wdef.levels or 1
    local short  = wdef and wdef.short or "?"
    local ammo   = player.ammo[player.weapon_name]
    local ammo_s = ammo and tostring(ammo) or "inf"
    local mod    = player.vehicle == "tank" and "shift+turn: turret" or "shift: strafe"
    local flags  = (player.unlimited and " [GOD]" or "")
      .. (powerups.easy_mode and "" or " [LAND]")
    g.print(string.format("Q:%s(%s) E:lv%d/%d ammo:%s ctrl:fire %s%s  R:restart",
      short, player.weapon_name, player.weapon_level, n_lvl, ammo_s, mod, flags), 4, 24)
    g.setColor(1, 1, 1)
    -- Objective banner (top center) for the active mission.
    if mission then
      local line = mission:status_line()
      local sw   = g.getDimensions()
      local tw   = g.getFont():getWidth(line)
      g.setColor(0, 0, 0, 0.6)
      g.rectangle("fill", sw / 2 - tw / 2 - 10, 22, tw + 20, 20)
      g.setColor(1, 1, 0.4, 1)
      g.print(line, sw / 2 - tw / 2, 25)
      g.setColor(1, 1, 1)
    end
    if mission and mission.state == "won" then draw_victory() end
    if mission and mission.state == "failed" then draw_game_over() end
    if player:death_done() then draw_game_over() end
    if paused then draw_pause() end
    if sandbox_mode then
      draw_sandbox_panel()
    end
  else
    -- vehicle / sandbox hint below the renderer bar
    local g = love.graphics
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 22, 470, 20)
    g.setColor(1, 1, 1, 0.9)
    g.print(string.format("V: [%s]  F1: play  F3: sandbox  F7: 2P split  O: game-over [%s]",
      sel_vehicle, death_enabled and "ON" or "OFF"), 4, 24)
    g.setColor(1, 1, 1)
  end

  if menu_open then draw_2p_menu() end
  dbg:draw()
end

function love.wheelmoved(_, dy)
  if not renderer.picker and not renderer.kind_picker then
    camera:on_wheel(dy)
  end
end

function love.keypressed(key)
  -- 2P setup menu. Each player toggles their own vehicle with their own keys at
  -- any time (no cursor); G/F toggle god/friendly-fire; SPACE starts.
  if menu_open then
    if     key == "escape" then menu_open = false
    elseif key == "space"  then enter_split()
    elseif key == "g"      then mp_setup.god = not mp_setup.god
    elseif key == "f"      then mp_setup.ff  = not mp_setup.ff
    elseif key == P1_CONTROLS.left or key == P1_CONTROLS.right then toggle_vehicle(1)
    elseif key == P2_CONTROLS.left or key == P2_CONTROLS.right then toggle_vehicle(2)
    end
    return
  end

  -- Split-screen game keys.
  if split_mode then
    if key == "escape" or key == "f1" then leave_split(); return end
    if key == "p" then paused = not paused; return end
    if key == "r" then paused = false; enter_split(); return end
    if key == "f5" then
      mp_setup.god = not mp_setup.god
      for _, p in ipairs(sp_players) do p.unlimited = mp_setup.god end
      return
    end
    if key == "f6" then powerups.easy_mode = not powerups.easy_mode; return end
    for _, p in ipairs(sp_players) do
      if key == p.controls.weapon then cycle_weapon(p) end
      if key == p.controls.action then toggle_land(p) end
    end
    return
  end

  if key == "f7" and not game_mode then
    menu_open = true
    return
  end

  if key == "f2" then
    dbg:toggle()
    return
  end

  if dbg.enabled then
    if dbg:keypressed(key) then return end
  end

  -- sandbox key handling (before game mode keys so F3/F4 are caught first)
  if sandbox_mode then
    if key == "f3" then leave_sandbox(); return end
    if key == "f4" then sb_save(); return end
    if key == "[" then
      sb_cursor = ((sb_cursor - 2) % #SB_PARAMS) + 1
      return
    end
    if key == "]" then
      sb_cursor = sb_cursor % #SB_PARAMS + 1
      return
    end
    if key == "=" or key == "kp+" then sb_adjust( 1); return end
    if key == "-" or key == "kp-" then sb_adjust(-1); return end
    -- fall through to game keys for movement (WASD, Space, etc.)
  end

  if key == "f1" then
    if game_mode then leave_game_mode() else enter_game_mode() end
    return
  end
  if key == "f3" and not game_mode then
    enter_sandbox()
    return
  end

  if game_mode and player then
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
      local wlist = VEHICLE_WEAPONS[player.vehicle] or {}
      local idx = 1
      for i, w in ipairs(wlist) do
        if w == player.weapon_name then idx = i; break end
      end
      idx = idx % #wlist + 1
      player.weapon_name  = wlist[idx]
      player.weapon_level = 1
      player.fire_timer   = 0
      sync_weapon_icon()
      return
    end
    if key == "e" then
      local wdef = combat.weapons[player.weapon_name]
      if wdef and wdef.levels then
        player.weapon_level = player.weapon_level % #wdef.levels + 1
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

  if key == "escape" then love.event.quit() end
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
      sel_vehicle = (sel_vehicle == "chopper") and "tank" or "chopper"
    end
    if key == "o" then death_enabled = not death_enabled end
    if key == "l" then renderer.show_segments = not renderer.show_segments end
    if key == "g" then renderer.show_grid     = not renderer.show_grid     end
    if key == "+" or key == "=" or key == "kp+" then camera:set_zoom(camera.zi + 1) end
    if key == "-" or key == "kp-"               then camera:set_zoom(camera.zi - 1) end
  end
end

function love.mousepressed(x, y, button)
  dbg:mousepressed(x, y, button)
end
