-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local Gamepad = require "engine.core.gamepad"

-- Base class for scenes managed by engine/core/scene_manager.lua. Every hook
-- is an overridable no-op so scenes only implement what they use. Update,
-- draw, and input reach only the scene on top of the stack. Touch input goes to
-- the touch hooks first; a hook returning false (the default) passes the touch
-- on to the mouse handlers, with the finger acting as the pointer.
local Scene = Class()

-- Menu-family scenes set this true: the app hides the OS cursor and draws the
-- original SELPOINT pointer sprite instead while such a scene is on top.
Scene.ui_pointer = false

-- Scenes that show no pointer at all (the ending) set this true: the OS cursor
-- is hidden and no pointer sprite is drawn.
Scene.hide_cursor = false

-- Simulation scenes set this true (see engine/scenes/gameplay_base.lua): main.lua
-- advances them in whole fixed ticks instead of passing the frame delta, so a run
-- plays out identically at any frame rate.
Scene.fixed_step = false

function Scene:init(app)
    self.app = app
end

function Scene:enter() end
function Scene:leave() end
-- suspend/resume bracket another scene being pushed on top / popped off.
function Scene:suspend() end
function Scene:resume() end

function Scene:update(_dt) end
function Scene:draw() end

function Scene:keypressed(_key) end
-- True while the scene wants every key raw (a rebind prompt), so global
-- shortcuts stand aside.
function Scene:captures_keys() return false end
-- A gamepad button (or a trigger, or the left stick tipped into a direction:
-- from_stick, reported as the d-pad button). pad is the pad number. A menu
-- scene takes it as the key the button stands for; the gameplay scenes
-- override this with their bound actions.
function Scene:padpressed(_pad, button, _from_stick)
    local key = Gamepad.MENU_KEYS[button]
    if key then self:keypressed(key) end
end
function Scene:wheelmoved(_dx, _dy) end
function Scene:mousemoved(_x, _y, _dx, _dy) end
function Scene:mousepressed(_x, _y, _button) end
function Scene:mousereleased(_x, _y, _button) end
function Scene:touchpressed(_id, _x, _y) return false end
function Scene:touchmoved(_id, _x, _y) return false end
function Scene:touchreleased(_id, _x, _y) return false end

return Scene
