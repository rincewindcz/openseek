local World    = require "engine.world"
local Camera   = require "engine.camera"
local Renderer = require "engine.renderer"
local Debug    = require "engine.debug"

local world
local camera
local renderer
local dbg

function love.load(args)
  love.graphics.setDefaultFilter("nearest", "nearest")
  world    = World:new()
  world:load(args[1] or world.stages[1])
  camera   = Camera:new(world.stage.world_size)
  renderer = Renderer:new(world, camera)
  dbg      = Debug:new(world, camera)
  love.window.setTitle(world:title())
end

function love.update(dt)
  if not renderer.picker then
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
  if not renderer.picker then
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

  local w = world

  if renderer.picker then
    if key == "escape" or key == "tab" then
      renderer.picker = false
    elseif key == "up" then
      w.stage_index = (w.stage_index - 2) % #w.stages + 1
    elseif key == "down" then
      w.stage_index = w.stage_index % #w.stages + 1
    elseif key == "return" then
      renderer.picker = false
      w:load(w.stages[w.stage_index])
      camera.world_size = w.stage.world_size
      camera:clamp()
      dbg.world = w
      love.window.setTitle(w:title())
    end
    return
  end

  if key == "escape" then love.event.quit() end
  if key == "tab"    then renderer.picker = true end

  if key == "pagedown" then
    w:load_index(w.stage_index % #w.stages + 1)
    camera.world_size = w.stage.world_size
    camera:clamp()
    love.window.setTitle(w:title())
  end
  if key == "pageup" then
    w:load_index((w.stage_index - 2) % #w.stages + 1)
    camera.world_size = w.stage.world_size
    camera:clamp()
    love.window.setTitle(w:title())
  end

  if key == "l" then renderer.show_segments = not renderer.show_segments end
  if key == "g" then renderer.show_grid     = not renderer.show_grid     end
  if key == "+" or key == "=" or key == "kp+" then camera:set_zoom(camera.zi + 1) end
  if key == "-" or key == "kp-"               then camera:set_zoom(camera.zi - 1) end
end

function love.mousepressed(x, y, button)
  dbg:mousepressed(x, y, button)
end
