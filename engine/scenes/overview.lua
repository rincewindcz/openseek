local Class    = require "engine.core.class"
local Scene    = require "engine.core.scene"
local Config   = require "engine.core.config"
local Vehicles = require "engine.game.vehicles"

-- Pre-game overview (dev/editor view): free camera over the loaded stage, the
-- SETUP/START/VIEW panel, the stage/kind pickers, the debug panel, and the
-- mode-launch keys. Toggles here also feed the live game (Config compat
-- options and the app settings).
local Overview = Class(Scene)

local COLORS = {
    bg    = { 0,    0,    0,    0.82 },
    sect  = { 0.16, 0.18, 0.24, 1    },
    key   = { 0.45, 0.85, 1,    1    },
    label = { 0.80, 0.80, 0.82, 1    },
    value = { 1,    1,    0.35, 1    },
    on    = { 0.35, 0.90, 0.40, 1    },
    off   = { 0.55, 0.55, 0.55, 1    },
    title = { 0.50, 0.90, 1,    1    },
}

local PANEL_W = 252
local ROW_H   = 17

local function section(g, label, x, y)
    g.setColor(COLORS.sect)
    g.rectangle("fill", x, y, PANEL_W, 18, 2)
    g.setColor(COLORS.title)
    g.print(label, x + 8, y + 2)
    return y + 22
end

local function row(g, key, label, value, vcolor, x, y)
    g.setColor(COLORS.key);   g.print(key, x + 8, y)
    g.setColor(COLORS.label); g.print(label, x + 78, y)
    if value then
        g.setColor(vcolor or COLORS.value)
        local tw = g.getFont():getWidth(value)
        g.print(value, x + PANEL_W - tw - 10, y)
    end
    return y + ROW_H
end

-- The per-mission briefing picture (STAGE0X_MPIC) for the loaded stage. Stage
-- names are stage{mission}{phase}, so the first digit selects the picture.
local function mission_pic(world)
    local m = world.stage_name and world.stage_name:match("^stage(%d)")
    return m and ("STAGE0" .. m .. "_MPIC") or nil
end

-- The overview is the editor: its entity editor (the shared debug panel) is
-- always on here, not gated behind F2. Gameplay keeps its own F2 toggle, so we
-- scope the always-on state to this scene with enter/leave.
function Overview:enter()
    self.app.debug_panel.enabled = true
    self.app.debug_panel.editor  = true
    self.panning = false
end

function Overview:leave()
    local dp = self.app.debug_panel
    dp.enabled  = false
    dp.editor   = false
    dp.selected = nil
    dp.pick_list   = nil
    dp.anim_picker = false
end

function Overview:update(dt)
    local app = self.app
    if not app.renderer.picker and not app.renderer.kind_picker
    and not app.debug_panel:captures_arrows() then
        app.camera:update(dt)
    end
    app.world:update(dt)
    app.combat:update(dt)   -- advance any shots fired via the editor FIRE action
    app.debug_panel:update()
end

function Overview:wheelmoved(_dx, dy)
    local app = self.app
    if not app.renderer.picker and not app.renderer.kind_picker then
        app.camera:on_wheel(dy)
    end
end

-- Right-drag pans the camera: the world point under the cursor stays put, so the
-- map follows the mouse. Delta is in screen pixels, converted to world units by
-- the current zoom.
function Overview:mousepressed(_x, _y, button)
    if button == 2 then self.panning = true end
end

function Overview:mousereleased(_x, _y, button)
    if button == 2 then self.panning = false end
end

function Overview:mousemoved(_x, _y, dx, dy)
    if not self.panning then return end
    local camera = self.app.camera
    local z = camera:zoom()
    camera.x = camera.x - dx / z
    camera.y = camera.y - dy / z
    camera:clamp()
end

function Overview:draw()
    local app = self.app
    app.renderer.highlight = app.debug_panel:highlight_entity()
    app.renderer:draw()
    app.combat:draw()            -- projectiles/effects from the editor FIRE action
    app.renderer:draw_debris()   -- shrapnel above any explosion (e.g. F2 kills)
    self:_draw_panel()
    app.debug_panel:draw()
    self:_draw_status_bar()
end

-- Bottom status bar: the live view/world state, consolidated from the old
-- top-left/top-right HUD overlays into one readable strip.
function Overview:_draw_status_bar()
    local app  = self.app
    local g    = love.graphics
    local font = g.getFont()
    local sw, sh = g.getDimensions()
    local barh = 24
    local by   = sh - barh

    g.setColor(0.06, 0.09, 0.13, 0.92)
    g.rectangle("fill", 0, by, sw, barh)
    g.setColor(0.16, 0.42, 0.54, 1)
    g.rectangle("fill", 0, by, sw, 2)

    local cam  = app.camera
    local live = 0
    for _, e in ipairs(app.world.entities) do if e:is_alive() then live = live + 1 end end

    local x  = 10
    local ty = by + (barh - font:getHeight()) / 2
    local function seg(label, value)
        g.setColor(COLORS.label); g.print(label, x, ty)
        x = x + font:getWidth(label) + 5
        g.setColor(COLORS.value); g.print(value, x, ty)
        x = x + font:getWidth(value) + 20
    end

    g.setColor(COLORS.title); g.print("EDITOR", x, ty)
    x = x + font:getWidth("EDITOR") + 20
    seg("stage",    app.world.stage_name or "?")
    seg("cam",      string.format("%d, %d", cam.x, cam.y))
    seg("zoom",     string.format("%gx", cam:zoom()))
    seg("fps",      tostring(love.timer.getFPS()))
    seg("entities", string.format("%d / %d", live, #app.world.entities))

    -- Mission objective, right-aligned in its own color (moved off the world view).
    local obj_text, obj_col = app.renderer:objective_status()
    if obj_text then
        local label = "OBJECTIVE"
        local tw = font:getWidth(label) + 6 + font:getWidth(obj_text)
        local ox = sw - tw - 10
        if ox > x then
            g.setColor(COLORS.label); g.print(label, ox, ty)
            g.setColor(obj_col); g.print(obj_text, ox + font:getWidth(label) + 6, ty)
        end
    end
    g.setColor(1, 1, 1)
end

function Overview:_draw_panel()
    local app      = self.app
    local settings = app.settings
    local g = love.graphics
    local x = 8
    local y = 8

    -- Title strip: mode + current stage.
    g.setColor(0.10, 0.24, 0.34, 1)
    g.rectangle("fill", x, y, PANEL_W, 20, 3)
    g.setColor(COLORS.title)
    g.print("OVERVIEW / EDITOR", x + 8, y + 3)
    local sn = app.world.stage_name or "?"
    g.setColor(COLORS.label)
    g.print(sn, x + PANEL_W - g.getFont():getWidth(sn) - 8, y + 3)
    y = y + 26

    -- SETUP box
    local setup_h = 22 + 6 * ROW_H + 6
    g.setColor(COLORS.bg); g.rectangle("fill", x, y, PANEL_W, setup_h, 4)
    local yy = section(g, "SETUP", x, y + 4)
    yy = row(g, "[V]", "Vehicle",   Vehicles.label(settings.vehicle, settings.chopper_skin),
          COLORS.value, x, yy)
    yy = row(g, "[O]", "Game over", settings.death_enabled and "ON" or "OFF",
          settings.death_enabled and COLORS.on or COLORS.off, x, yy)
    yy = row(g, "[C]", "Pickups",   Config.axis_aligned_pickups and "AXIS-ALIGNED" or "ROTATED",
          COLORS.value, x, yy)
    yy = row(g, "[P]", "POW friendly fire", Config.friendly_fire_pows and "ON" or "OFF",
          Config.friendly_fire_pows and COLORS.on or COLORS.off, x, yy)
    yy = row(g, "[H]", "HUD scale", string.format("%.2f", Config.hud_scale),
          COLORS.value, x, yy)
    row(g, "[ / ]", "Speed",   string.format("%.2f", Config.speed_scale),
          COLORS.value, x, yy)

    -- START box
    y = y + setup_h + 6
    local start_h = 22 + 6 * ROW_H + 6
    g.setColor(COLORS.bg); g.rectangle("fill", x, y, PANEL_W, start_h, 4)
    yy = section(g, "START", x, y + 4)
    yy = row(g, "[F1]",  "Play",              nil, nil, x, yy)
    yy = row(g, "[F3]",  "Sandbox (vehicle)", nil, nil, x, yy)
    yy = row(g, "[F7]",  "2P split screen",   nil, nil, x, yy)
    yy = row(g, "[F8]",  "Animation gallery", nil, nil, x, yy)
    yy = row(g, "[F9]",  "Font gallery",      nil, nil, x, yy)
    row(g, "[F10]", "Sound gallery",     nil, nil, x, yy)

    -- EDITOR box: the entity editor panel is always on in the overview.
    y = y + start_h + 6
    local edit_h = 22 + 3 * ROW_H + 6
    g.setColor(COLORS.bg); g.rectangle("fill", x, y, PANEL_W, edit_h, 4)
    yy = section(g, "ENTITY EDITOR", x, y + 4)
    yy = row(g, "[Click]",  "select entity",    nil, nil, x, yy)
    yy = row(g, "[-/+]",    "adjust field",     nil, nil, x, yy)
    row(g, "[S]",      "save entity_types", nil, nil, x, yy)

    -- VIEW box
    y = y + edit_h + 6
    local view_h = 22 + 4 * ROW_H + 6
    g.setColor(COLORS.bg); g.rectangle("fill", x, y, PANEL_W, view_h, 4)
    yy = section(g, "VIEW", x, y + 4)
    yy = row(g, "[Tab]/[K]", "stage / kinds",    nil, nil, x, yy)
    yy = row(g, "[L]/[G]",   "segments / grid",  nil, nil, x, yy)
    yy = row(g, "[WASD]",    "pan / R-drag",     nil, nil, x, yy)
    row(g, "[+/-]",     "zoom",             nil, nil, x, yy)

    g.setColor(1, 1, 1)
end

-- Stage / kind picker keys, shared with the gameplay scenes (Tab/K/PageUp/
-- PageDown work mid-game too). Returns true when the key was consumed.
function Overview.picker_keys(app, key)
    local renderer, world = app.renderer, app.world
    if renderer.kind_picker then
        if key == "escape" or key == "k" then
            renderer.kind_picker = false
        else
            renderer:on_kind_picker_key(key)
        end
        return true
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
            app.after_stage_load()
        end
        return true
    end
    if key == "tab" then renderer.picker = true end
    if key == "k"   then renderer:toggle_kind_picker() end
    if key == "pagedown" then
        world:load_index(world.stage_index % #world.stages + 1)
        app.after_stage_load()
    end
    if key == "pageup" then
        world:load_index((world.stage_index - 2) % #world.stages + 1)
        app.after_stage_load()
    end
    return false
end

function Overview:keypressed(key)
    local app = self.app
    if key == "f8"  then app.scenes:switch("anim_gallery");  return end
    if key == "f9"  then app.scenes:switch("font_gallery");  return end
    if key == "f10" then app.scenes:switch("sound_gallery"); return end
    if key == "f7"  then app.scenes:switch("coop_setup");    return end
    if key == "f2"  then return end   -- editor is always on here; F2 is a no-op
    if app.debug_panel.enabled and app.debug_panel:keypressed(key) then return end
    if key == "f1" then
        -- Show the mission briefing picture, then drop into the live game. Dev
        -- launch of a single stage, not a campaign run.
        app.campaign = false
        local pic = mission_pic(app.world)
        if pic then
            app.screen:show(pic, { fade_in = 0.3, hold = 0.75, fade_out = 0.3,
                on_done = function() app.scenes:switch("gameplay") end })
        else
            app.scenes:switch("gameplay")
        end
        return
    end
    if key == "f3" then app.scenes:switch("sandbox"); return end
    if Overview.picker_keys(app, key) then return end
    if key == "escape" then app.scenes:switch("main_menu"); return end

    local settings = app.settings
    if key == "v" then
        settings.vehicle, settings.chopper_skin = Vehicles.cycle(settings.vehicle, settings.chopper_skin)
    end
    if key == "o" then settings.death_enabled = not settings.death_enabled end
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
    if key == "l" then app.renderer.show_segments = not app.renderer.show_segments end
    if key == "g" then app.renderer.show_grid     = not app.renderer.show_grid     end
    if key == "+" or key == "=" or key == "kp+" then app.camera:set_zoom(app.camera.zoom_index + 1) end
    if key == "-" or key == "kp-"               then app.camera:set_zoom(app.camera.zoom_index - 1) end
end

return Overview
