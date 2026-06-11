local World     = require "engine.world"
local Camera    = require "engine.camera"
local Renderer  = require "engine.renderer"
local Debug     = require "engine.debug"
local Animation = require "engine.animation"

local world
local camera
local renderer
local dbg

local function after_stage_load()
  camera.world_size = world.stage.world_size
  camera:clamp()
  renderer:refresh_kinds()
  dbg.world = world
  love.window.setTitle(world:title())
end

function love.load(args)
  love.graphics.setDefaultFilter("nearest", "nearest")
  Animation.load("data/animations.json")
  world    = World:new()
  world:load(args[1] or world.stages[1])
  camera   = Camera:new(world.stage.world_size)
  renderer = Renderer:new(world, camera)
  dbg      = Debug:new(world, camera)
  renderer:refresh_kinds()
  love.window.setTitle(world:title())
end

function love.update(dt)
  if not renderer.picker and not renderer.kind_picker then
    camera:update(dt)
  end
  world:update(dt)
  dbg:update()
end

function love.draw()
  renderer:draw()
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

  -- kind picker intercepts all navigation keys while open
  if renderer.kind_picker then
    if key == "escape" or key == "k" then
      renderer.kind_picker = false
    else
      renderer:on_kind_picker_key(key)
    end
    return
  end

  -- stage picker
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

  if key == "escape"  then love.event.quit() end
  if key == "tab"     then renderer.picker      = true end
  if key == "k"       then renderer:toggle_kind_picker() end

  if key == "pagedown" then
    world:load_index(world.stage_index % #world.stages + 1)
    after_stage_load()
  end
  if key == "pageup" then
    world:load_index((world.stage_index - 2) % #world.stages + 1)
    after_stage_load()
  end

  if key == "l" then renderer.show_segments = not renderer.show_segments end
  if key == "g" then renderer.show_grid     = not renderer.show_grid     end
  if key == "+" or key == "=" or key == "kp+" then camera:set_zoom(camera.zi + 1) end
  if key == "-" or key == "kp-"               then camera:set_zoom(camera.zi - 1) end
end

function love.mousepressed(x, y, button)
  dbg:mousepressed(x, y, button)
end
