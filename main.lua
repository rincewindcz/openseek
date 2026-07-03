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
local Mission         = require "engine.game.mission"
local Screen          = require "engine.core.screen"
local EndStats        = require "engine.ui.end_stats"
local Pointer         = require "engine.ui.pointer"
local SceneManager    = require "engine.core.scene_manager"
local json            = require "lib.json"

local Title           = require "engine.scenes.title"
local MainMenu        = require "engine.scenes.main_menu"
local MissionBriefing = require "engine.scenes.mission_briefing"
local MissionSelect   = require "engine.scenes.mission_select"
local Overview        = require "engine.scenes.overview"
local Gameplay        = require "engine.scenes.gameplay"
local Sandbox         = require "engine.scenes.sandbox"
local CoopSetup       = require "engine.scenes.coop_setup"
local CoopGameplay    = require "engine.scenes.coop_gameplay"
local AnimGallery     = require "engine.scenes.anim_gallery"
local FontGallery     = require "engine.scenes.font_gallery"
local Credits         = require "engine.scenes.credits"
local HiScores        = require "engine.scenes.hiscores"

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
    love.window.setTitle(world:title())
    local top = app.scenes:top()
    local player = top and top.player
    if player then
        player.world_size = world.stage.world_size
        player.world      = world
    end
end

function love.load(args)
    love.graphics.setDefaultFilter("nearest", "nearest")
    Animation.load("data/animations.json")

    local vehicle_defs = {}
    for _, fname in ipairs(love.filesystem.getDirectoryItems("data/vehicles")) do
        if fname:match("%.json$") then
            local raw  = love.filesystem.read("data/vehicles/" .. fname)
            local name = fname:match("^(.+)%.json$")
            if raw and name then vehicle_defs[name] = json.decode(raw) end
        end
    end

    local world = World:new()
    world:load(args[1] or world.stages[1])
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
        viewer_zoom_index = 4,     -- overview zoom, restored when a game mode ends
        settings = {
            vehicle       = "chopper",
            chopper_skin  = 1,     -- player chopper variant (1 green, 2 magenta, 3 white)
            death_enabled = false, -- optional game-over (chopper falls, tank burns)
            coop = { vehicle = { "chopper", "tank" }, skin = { 1, 1 }, god = false, ff = false },
        },
    }
    app.hud:load("data/hud.json")
    app.hud.world = world
    app.hud:set_mission(tonumber(world.stage_name:match("^stage(%d)")) or 0)
    app.combat = CombatSystem:new(world, camera)
    app.combat:load("data/weapons.json")
    app.helis  = HeliSystem:new(world, app.combat)
    app.combat.heli_sys = app.helis
    Mission.load("data/missions.json")
    app.powerups = Powerups:new(world, camera, app.combat.weapons)
    app.rescue   = RescueSystem:new(world, app.combat)
    app.renderer:refresh_kinds()
    love.window.setTitle(world:title())

    -- A 1x1 transparent hardware cursor, used to hide the pointer reliably (LOVE's
    -- setVisible(false) is flaky under some Wayland compositors).
    local ok, c = pcall(function() return love.mouse.newCursor(love.image.newImageData(1, 1), 0, 0) end)
    app.hidden_cursor = ok and c or nil

    local scenes = app.scenes
    scenes:register("title",            Title:new(app))
    scenes:register("main_menu",        MainMenu:new(app))
    scenes:register("mission_briefing", MissionBriefing:new(app))
    scenes:register("mission_select",   MissionSelect:new(app))
    scenes:register("overview",         Overview:new(app))
    scenes:register("gameplay",         Gameplay:new(app))
    scenes:register("sandbox",          Sandbox:new(app))
    scenes:register("coop_setup",       CoopSetup:new(app))
    scenes:register("coop_gameplay",    CoopGameplay:new(app))
    scenes:register("anim_gallery",     AnimGallery:new(app))
    scenes:register("font_gallery",     FontGallery:new(app))
    scenes:register("credits",          Credits:new(app))
    scenes:register("hiscores",         HiScores:new(app))
    scenes:switch("title")
end

function love.update(dt)
    app.screen:update(dt)
    app.scenes:dispatch("update", dt)
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
end

function love.keypressed(key)
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

function love.mousemoved(x, y)
    Pointer.moved(x, y, false)
    app.scenes:dispatch("mousemoved", x, y)
end

function love.mousepressed(x, y, button)
    app.debug_panel:mousepressed(x, y, button)
    if button == 1 then
        Pointer.moved(x, y, false)
        pointer_pressed(x, y)
    end
end

function love.mousereleased(x, y, button)
    if button == 1 then
        Pointer.moved(x, y, false)
        pointer_released(x, y)
    end
end

-- Touch mirrors the mouse (each touch acts as the pointer); Pointer is told
-- it's touch so it suppresses the cursor sprite (the finger is the pointer).
function love.touchmoved(_, x, y)
    Pointer.moved(x, y, true)
    app.scenes:dispatch("mousemoved", x, y)
end

function love.touchpressed(_, x, y)
    Pointer.moved(x, y, true)
    pointer_pressed(x, y)
end

function love.touchreleased(_, x, y)
    Pointer.moved(x, y, true)
    pointer_released(x, y)
end
