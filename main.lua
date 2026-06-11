local World        = require "engine.world"
local Camera       = require "engine.camera"
local Renderer     = require "engine.renderer"
local Debug        = require "engine.debug"
local Animation    = require "engine.animation"
local Player       = require "engine.player"
local Hud          = require "engine.hud"
local CombatSystem = require "engine.combat"
local json         = require "lib.json"

local world
local camera
local renderer
local dbg
local hud
local player
local combat
local game_mode    = false
local sandbox_mode = false
local sel_vehicle  = "chopper"
local viewer_zi    = 4
local vehicle_defs = {}

-- Weapon lists per vehicle (order determines cycle order)
local VEHICLE_WEAPONS = {
  chopper = {"chaingun", "rockets", "air_to_ground", "air_to_air", "bomb"},
  tank    = {"chaingun", "shells"},
}

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

-- ── mode transitions ──────────────────────────────────────────────────────────

local function after_stage_load()
  camera.world_size = world.stage.world_size
  camera:clamp()
  renderer:refresh_kinds()
  dbg.world = world
  hud.world = world
  love.window.setTitle(world:title())
  if player then player.world_size = world.stage.world_size end
end

local function enter_game_mode()
  viewer_zi  = camera.zi
  game_mode  = true
  camera:set_zoom(6)
  local ws = world.stage.world_size
  player = Player:new(ws / 2, ws / 2)
  player.world_size = ws
  player.vehicle    = sel_vehicle
  local def = vehicle_defs[sel_vehicle]
  if def then player:load_vehicle_def(def) end
  -- Set default weapon for vehicle
  local wlist = VEHICLE_WEAPONS[sel_vehicle]
  if wlist then player.weapon_name = wlist[1] end
  hud.player    = player
  combat.player = player
  love.window.setTitle(world:title() .. "  [" .. sel_vehicle .. "]")
end

local function leave_game_mode()
  game_mode         = false
  sandbox_mode      = false
  player            = nil
  hud.player        = nil
  combat.player     = nil
  combat.projectiles = {}
  camera.angle      = nil
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
  renderer:refresh_kinds()
  love.window.setTitle(world:title())
end

local function _try_fire(dt)
  if not (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then return end
  local wdef = combat.weapons[player.weapon_name]
  if not wdef then return end
  if player.fire_timer > 0 then return end
  local level = wdef.levels and wdef.levels[player.weapon_level] or wdef
  combat:tick_swing("player", player.weapon_name)
  combat:fire(player.x, player.y, player.angle, player.weapon_name, "player", player.weapon_level)
  player.fire_timer = 1.0 / (level.fire_rate or wdef.fire_rate or 10)
end

function love.update(dt)
  if game_mode and player then
    player:update(dt)
    _try_fire(dt)
    combat:update(dt)
    camera.x     = player.x
    camera.y     = player.y
    camera.angle = player:camera_angle()
  else
    if not renderer.picker and not renderer.kind_picker then
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
  renderer:draw()

  if game_mode and player then
    combat:draw()
    player:draw()
    hud:draw()
    -- Weapon indicator (top-left, below renderer bar)
    local g = love.graphics
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 22, 220, 20)
    g.setColor(1, 1, 0.2, 1)
    local wdef  = combat.weapons[player.weapon_name]
    local n_lvl = wdef and wdef.levels and #wdef.levels or 1
    g.print(string.format("Q: %s  E: lv%d/%d  ctrl: fire",
      player.weapon_name, player.weapon_level, n_lvl), 4, 24)
    g.setColor(1, 1, 1)
    if sandbox_mode then
      draw_sandbox_panel()
    end
  else
    -- vehicle / sandbox hint below the renderer bar
    local g = love.graphics
    g.setColor(0, 0, 0, 0.55)
    g.rectangle("fill", 0, 22, 260, 20)
    g.setColor(1, 1, 1, 0.9)
    g.print("V: [" .. sel_vehicle .. "]  F1: play  F3: sandbox", 4, 24)
    g.setColor(1, 1, 1)
  end

  dbg:draw()
end

function love.wheelmoved(_, dy)
  if not renderer.picker and not renderer.kind_picker then
    camera:on_wheel(dy)
  end
end

function love.keypressed(key)
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
    if key == "l" then renderer.show_segments = not renderer.show_segments end
    if key == "g" then renderer.show_grid     = not renderer.show_grid     end
    if key == "+" or key == "=" or key == "kp+" then camera:set_zoom(camera.zi + 1) end
    if key == "-" or key == "kp-"               then camera:set_zoom(camera.zi - 1) end
  end
end

function love.mousepressed(x, y, button)
  dbg:mousepressed(x, y, button)
end
