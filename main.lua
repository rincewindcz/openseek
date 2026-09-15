local World           = require "engine.game.world"
local Camera          = require "engine.core.camera"
local Renderer        = require "engine.game.renderer"
local DebugPanel      = require "engine.dev.debug_panel"
local Animation       = require "engine.core.animation"
local Hud             = require "engine.ui.hud"
local CombatSystem    = require "engine.game.combat"
local HeliSystem      = require "engine.game.enemy_heli"
local Powerups        = require "engine.game.powerups"
local RescueSystem    = require "engine.game.rescue"
local SaboteurSystem  = require "engine.game.saboteur"
local Weather         = require "engine.game.weather"
local LightFX         = require "engine.game.lightfx"
local PostFX          = require "engine.game.postfx"
local Config          = require "engine.core.config"
local Input           = require "engine.core.input"
local Screenshot      = require "engine.core.screenshot"
local Display         = require "engine.core.display"
local Mission         = require "engine.game.mission"
local Score           = require "engine.game.score"
local Screen          = require "engine.core.screen"
local EndStats        = require "engine.ui.end_stats"
local Pointer         = require "engine.ui.pointer"
local SceneManager    = require "engine.core.scene_manager"
local Audio           = require "engine.core.audio"
local Assets          = require "engine.core.assets"
local Sound           = require "engine.game.sound"
local json            = require "lib.json"

local Title           = require "engine.scenes.title"
local MainMenu        = require "engine.scenes.main_menu"
local MissionBriefing = require "engine.scenes.mission_briefing"
local MissionSelect   = require "engine.scenes.mission_select"
local Equip           = require "engine.scenes.equip"
local Shop            = require "engine.scenes.shop"
local AdvancedSettings = require "engine.scenes.advanced_settings"
local Overview        = require "engine.scenes.overview"
local Gameplay        = require "engine.scenes.gameplay"
local Sandbox         = require "engine.scenes.sandbox"
local CoopSetup       = require "engine.scenes.coop_setup"
local CoopGameplay    = require "engine.scenes.coop_gameplay"
local AnimGallery     = require "engine.scenes.anim_gallery"
local FontGallery     = require "engine.scenes.font_gallery"
local SoundGallery    = require "engine.scenes.sound_gallery"
local Credits         = require "engine.scenes.credits"
local HiScores        = require "engine.scenes.hiscores"
local Replays         = require "engine.scenes.replays"
local Selftest        = require "engine.dev.selftest"

-- The shared app context handed to every scene: the world and the systems
-- around it, the fullscreen fade overlay, the stats screen, and the pre-game
-- settings. Scenes address each other through app.scenes (the manager).
local app

-- Rewire the shared systems after a different stage is loaded into the world.
local function after_stage_load()
    local world, camera = app.world, app.camera
    camera.world_size = world.stage.world_size
    camera:clamp()
    app.renderer:refresh_kinds()
    app.debug_panel.world = world
    app.hud.world = world
    app.hud:set_mission(tonumber(world.stage_name:match("^stage(%d)")) or 0)
    local top = app.scenes:top()
    local player = top and top.player
    if player then
        player.world_size = world.stage.world_size
        player.world      = world
    end
end

-- Without the decoded pack nothing past this point can load, so the app is
-- reduced to one static message until the user quits.
local function show_missing_data()
    local font = love.graphics.newFont(24)
    local text = "MISSING GAME DATA"
    love.update, love.wheelmoved, love.mousemoved, love.mousepressed = nil, nil, nil, nil
    love.mousereleased, love.touchmoved, love.touchpressed, love.touchreleased = nil, nil, nil, nil
    love.draw = function()
        local g = love.graphics
        local screen_w, screen_h = g.getDimensions()
        g.clear(0, 0, 0, 1)
        g.setFont(font)
        g.setColor(1, 1, 1, 1)
        g.print(text, math.floor((screen_w - font:getWidth(text)) / 2),
            math.floor((screen_h - font:getHeight()) / 2))
    end
    love.keypressed = function(key)
        if key == "escape" then love.event.quit() end
    end
end

function love.load(args)
    print(("openSEEK starting (LOVE %s, %s)"):format(love.getVersion and select(4, love.getVersion()) or "?", _VERSION))
    love.graphics.setDefaultFilter("nearest", "nearest")
    Config.load()   -- overlay persisted advanced settings onto the defaults
    Input.load()    -- overlay persisted key bindings onto the defaults
    Display.apply() -- restore the saved window mode (size / fullscreen / vsync)
    if not Assets.pack_present() then
        print("openSEEK: game data not found in assets/")
        for _, a in ipairs(args or {}) do
            if a == "--selftest" then love.event.quit(1) end
        end
        show_missing_data()
        return
    end
    Animation.load("data/animations.json")
    Audio.load(Assets.path("sounds.json"))
    Audio.load_events("data/audio.json")
    Sound.apply_config()

    local vehicle_defs = {}
    for _, fname in ipairs(love.filesystem.getDirectoryItems("data/vehicles")) do
        if fname:match("%.json$") then
            local raw  = love.filesystem.read("data/vehicles/" .. fname)
            local name = fname:match("^(.+)%.json$")
            if raw and name then vehicle_defs[name] = json.decode(raw) end
        end
    end

    -- Command line: `love . stage12` opens a stage, `love . --selftest [ticks]
    -- [stage]` runs the determinism self-test (below). Flags and the tick count
    -- are skipped when looking for the stage name.
    local stage_arg, selftest_ticks, selftest = nil, nil, false
    for _, a in ipairs(args or {}) do
        if a == "--selftest" then
            selftest = true
        elseif tonumber(a) then
            selftest_ticks = selftest_ticks or tonumber(a)
        elseif not a:match("^%-%-") then
            stage_arg = stage_arg or a
        end
    end

    local world = World:new()
    world:load(stage_arg or world.stages[1])
    local camera = Camera:new(world.stage.world_size)

    app = {
        world             = world,
        camera            = camera,
        renderer          = Renderer:new(world, camera),
        debug_panel       = DebugPanel:new(world, camera),
        hud               = Hud:new(),
        screen            = Screen:new(),
        end_stats         = EndStats:new(),
        scenes            = SceneManager:new(),
        vehicle_defs      = vehicle_defs,
        after_stage_load  = after_stage_load,
        tick              = 0,     -- fixed simulation ticks since the phase started
        record_runs       = true,  -- write a replay file for every phase played
        replay_play       = nil,   -- Replay being played back (set by the replay picker)
        replay_verify     = false, -- playback at speed, only to check for divergence
        replay_result     = nil,   -- outcome of the last playback, shown by the picker
        viewer_zoom_index = 4,     -- overview zoom, restored when a game mode ends
        campaign          = false, -- NEW GAME run: advance phase->phase, accumulate score
        run_score         = 0,     -- score carried across phases of a campaign run
        run_lives         = Score.START_LIVES,        -- spare vehicles carried across phases of a run
        run_bonus_life    = Score.BONUS_LIFE_STEP,    -- next bonus-vehicle threshold, carried with the score
        settings = {
            vehicle       = "chopper",
            death_enabled = false, -- optional game-over (chopper falls, tank burns)
            coop = { vehicle = { "chopper", "tank" }, skin = { 1, 1 }, god = false, ff = false },
        },
    }
    app.hud:load("data/hud.json")
    app.hud.world = world
    app.hud:set_mission(tonumber(world.stage_name:match("^stage(%d)")) or 0)
    app.combat = CombatSystem:new(world, camera)
    app.combat:load("data/weapons.json")
    world.combat = app.combat   -- lets world emit explosion effects (e.g. crushed trees)
    app.hud.combat = app.combat   -- lets the HUD sight query the current weapon / lock target
    app.debug_panel.combat = app.combat   -- lets the editor's FIRE action shoot
    app.helis  = HeliSystem:new(world, app.combat)
    app.combat.heli_sys = app.helis
    Mission.load("data/missions.json")
    app.powerups = Powerups:new(world, camera, app.combat.weapons)
    app.rescue   = RescueSystem:new(world, app.combat)
    app.saboteur = SaboteurSystem:new(world, app.combat)
    app.weather  = Weather:new()
    app.lightfx  = LightFX:new()
    world.lightfx = app.lightfx   -- lets combat / entity emitters reach it via the world
    app.postfx   = PostFX:new()
    app.sound    = Sound:new(world)
    world.sound_sys = app.sound   -- same route for the audio emitters (World:sound / :say)
    app.renderer:refresh_kinds()

    -- A 1x1 transparent hardware cursor, used to hide the pointer reliably (LOVE's
    -- setVisible(false) is flaky under some Wayland compositors).
    local ok, c = pcall(function() return love.mouse.newCursor(love.image.newImageData(1, 1), 0, 0) end)
    app.hidden_cursor = ok and c or nil

    local scenes = app.scenes
    scenes:register("title",            Title:new(app))
    scenes:register("main_menu",        MainMenu:new(app))
    scenes:register("mission_briefing", MissionBriefing:new(app))
    scenes:register("mission_select",   MissionSelect:new(app))
    scenes:register("equip",            Equip:new(app))
    scenes:register("shop",             Shop:new(app))
    scenes:register("advanced_settings", AdvancedSettings:new(app))
    scenes:register("overview",         Overview:new(app))
    scenes:register("gameplay",         Gameplay:new(app))
    scenes:register("sandbox",          Sandbox:new(app))
    scenes:register("coop_setup",       CoopSetup:new(app))
    scenes:register("coop_gameplay",    CoopGameplay:new(app))
    scenes:register("anim_gallery",     AnimGallery:new(app))
    scenes:register("font_gallery",     FontGallery:new(app))
    scenes:register("sound_gallery",    SoundGallery:new(app))
    scenes:register("credits",          Credits:new(app))
    scenes:register("hiscores",         HiScores:new(app))
    scenes:register("replays",          Replays:new(app))
    scenes:switch("title")

    -- Run one scripted phase twice and compare the simulation tick by tick, then
    -- quit. See engine/dev/selftest.lua.
    if selftest then
        love.event.quit(Selftest.run(app, selftest_ticks, stage_arg) and 0 or 1)
    end
end

-- Fixed simulation step. A gameplay scene (Scene.fixed_step) advances in whole
-- ticks of TICK seconds regardless of the frame rate, so the same inputs always
-- produce the same run; every other scene keeps the real frame delta. The
-- catch-up clamp keeps a stall (stage load, alt-tab, a slow frame) from turning
-- into a burst of ticks that would jump the vehicle across the map.
--
-- The scene counts the ticks it actually simulates (GameplayBase:begin_tick), not
-- this loop: a tick the scene skips (paused, stats screen) must not advance the
-- clock a recording is keyed to, or playback would simulate ticks the recording
-- never covered.
local TICK        = 1 / 60
local MAX_CATCHUP = 5
local accumulator = 0

function love.update(dt)
    app.screen:update(dt)
    app.hud:update(dt) -- rolling score readout: presentation, on frame time
    Audio.update(dt)   -- mixer housekeeping (duck release, music fades): real time, not ticks
    local top = app.scenes:top()
    if not (top and top.fixed_step) then
        accumulator = 0
        app.scenes:dispatch("update", dt)
        return
    end
    accumulator = math.min(accumulator + dt, TICK * MAX_CATCHUP)
    while accumulator >= TICK do
        accumulator = accumulator - TICK
        -- tick_scale > 1 fast-forwards the simulation (replay verification): the
        -- step stays TICK, only more of them run per frame.
        for _ = 1, (top.tick_scale or 1) do
            app.scenes:dispatch("update", TICK)
            -- The tick may have handed off (mission complete, game over, replay
            -- finished): the new scene owns the rest of this frame.
            if app.scenes:top() ~= top then break end
        end
        if app.scenes:top() ~= top then accumulator = 0; break end
    end
end

function love.draw()
    local top = app.scenes:top()
    -- Hide the OS cursor while a pointer-driven UI scene, the stats screen, or
    -- a fullscreen overlay is up (the SELPOINT sprite is drawn instead);
    -- restore it for gameplay and the overview.
    local ui = (top and top.ui_pointer) or app.end_stats:is_active() or app.screen:is_active()
    if app.hidden_cursor then
        if ui then love.mouse.setCursor(app.hidden_cursor) else love.mouse.setCursor() end
    else
        love.mouse.setVisible(not ui)
    end

    app.scenes:dispatch("draw")
    app.screen:draw()   -- the fade overlay composes above everything

    -- The pointer sprite: over the menu scenes (unless a passive image overlay
    -- is up front) and over the end-of-phase stats screen.
    if ((top and top.ui_pointer) and not app.screen:is_active()) or app.end_stats:is_active() then
        Pointer.draw()
    end

    if Config.show_fps then
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.print("FPS " .. love.timer.getFPS(), 5, 5)
        love.graphics.setColor(1, 1, 0.4, 1)
        love.graphics.print("FPS " .. love.timer.getFPS(), 4, 4)
        love.graphics.setColor(1, 1, 1, 1)
    end
end

function love.keypressed(key)
    local top = app.scenes:top()
    if Input.pressed("screenshot", key) and not (top and top:captures_keys()) then
        Screenshot.capture()
        return
    end
    -- A fullscreen overlay (title / briefing / crash picture) swallows input.
    -- Esc cancels it (the shower's on_cancel decides where that goes); a
    -- wait_key picture otherwise advances on any key.
    if app.screen:is_active() then
        if key == "escape" then
            app.screen:cancel()
        else
            app.screen:keypressed(key)
        end
        return
    end
    app.scenes:dispatch("keypressed", key)
end

function love.wheelmoved(dx, dy)
    app.scenes:dispatch("wheelmoved", dx, dy)
end

-- Pointer down: arm the widget under the pointer. A passive overlay advances
-- on release, so the press is only consumed.
local function pointer_pressed(x, y)
    if app.screen:is_active() then return end
    app.scenes:dispatch("mousepressed", x, y)
end

-- Pointer up: fire the armed widget, or advance a passive overlay (mirrors
-- the keyboard path). The screen is checked first so a click still advances
-- an overlay shown over a held menu.
local function pointer_released(x, y)
    if app.screen:is_active() then
        app.screen:keypressed()
        return
    end
    app.scenes:dispatch("mousereleased", x, y)
end

-- Mouse events SDL synthesizes from touches (istouch) are dropped: the touch
-- callbacks below already handle those.
function love.mousemoved(x, y, dx, dy, istouch)
    if istouch then return end
    Pointer.moved(x, y, false)
    app.scenes:dispatch("mousemoved", x, y, dx, dy)
end

function love.mousepressed(x, y, button, istouch)
    if istouch then return end
    app.debug_panel:mousepressed(x, y, button)
    if button == 1 then
        Pointer.moved(x, y, false)
        pointer_pressed(x, y)
    elseif not app.screen:is_active() then
        app.scenes:dispatch("mousepressed", x, y, button)
    end
end

function love.mousereleased(x, y, button, istouch)
    if istouch then return end
    if button == 1 then
        Pointer.moved(x, y, false)
        pointer_released(x, y)
    elseif not app.screen:is_active() then
        app.scenes:dispatch("mousereleased", x, y, button)
    end
end

-- A touch goes to the top scene's touch hooks first (gameplay's on-screen
-- controls); otherwise it mirrors the mouse, with Pointer told it is touch so it
-- suppresses the cursor sprite (the finger is the pointer).
function love.touchmoved(id, x, y)
    Pointer.moved(x, y, true)
    if app.scenes:dispatch("touchmoved", id, x, y) then return end
    app.scenes:dispatch("mousemoved", x, y)
end

function love.touchpressed(id, x, y)
    Pointer.moved(x, y, true)
    if not app.screen:is_active() and app.scenes:dispatch("touchpressed", id, x, y) then return end
    pointer_pressed(x, y)
end

function love.touchreleased(id, x, y)
    Pointer.moved(x, y, true)
    if app.scenes:dispatch("touchreleased", id, x, y) then return end
    pointer_released(x, y)
end
