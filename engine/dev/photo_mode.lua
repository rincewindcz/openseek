-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Camera     = require "engine.core.camera"
local Input      = require "engine.core.input"
local Screenshot = require "engine.core.screenshot"
local json       = require "lib.json"

-- Photo mode, a developer tool for promotional stills: `love . --photo`, then
-- F8 in a gameplay scene or the overview. It holds the simulation like a pause,
-- leaves out the HUD and every overlay, and frees the view. The scene's camera
-- keeps its focus (the vehicle); photo mode moves where that focus sits on
-- screen, how far the view is zoomed and how far it is turned. A capture draws
-- the world again into a canvas of the chosen output size, so a still can be
-- larger than the window and of another shape; the frame guide marks the part
-- of the window it covers.
--
-- Presentation only: the view is put on the camera for the length of a draw and
-- taken off again, and the only simulation it runs is whole ticks through the
-- scene's own update (the step key).
local PhotoMode = Class()

local DATA_PATH  = "data/photo.json"
local TOGGLE_KEY = "f8"
local STEP_KEY   = "."
local HOLD_DELAY = 0.35   -- seconds the step key is held before slow motion starts
local TICK_RATE  = 60     -- main.lua's fixed simulation rate
local NOTE_TIME  = 5

local DEFAULTS = {
    outputs     = { { label = "WINDOW" } },   -- an entry without w / h is the window's size
    zoom_min    = 0.1,
    zoom_max    = 12,
    zoom_step   = 1.1,    -- zoom factor per wheel notch
    turn_step   = 15,     -- degrees per [ / ] press
    turn_drag   = 0.25,   -- degrees per pixel of right drag
    slow_motion = 0.25,   -- simulation speed while the step key is held
}

local HELP = {
    "F8 / ESC leave    L-DRAG move    WHEEL zoom    R-DRAG, [ ] turn    0 reset    V stage view",
    "O output size    . step a tick (hold: slow motion)    ENTER capture    C copy cursor position    TAB hide this",
}

function PhotoMode:init(app)
    self.app    = app
    self.active = false
    self.output = 1
    self.help   = true
    local raw = love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    decoded = (ok and type(decoded) == "table") and decoded or {}
    self.def = {}
    for key, v in pairs(DEFAULTS) do
        self.def[key] = decoded[key] ~= nil and decoded[key] or v
    end
end

-- True while photo mode owns the frame. It closes when its scene is no longer on
-- top (a stepped tick ended the phase).
function PhotoMode:engaged()
    if self.active and self.app.scenes:top() ~= self.scene then self:close() end
    return self.active
end

function PhotoMode:open(scene)
    local camera = scene:photo_camera()
    self.active    = true
    self.scene     = scene
    self.camera    = camera
    self.home_ox   = camera.view_ox
    self.home_oy   = camera.view_oy
    self.steps     = 0
    self.step_frac = 0
    self.hold      = 0
    self.capture   = false
    self.note      = nil
    self:reset()
end

function PhotoMode:close()
    self.active = false
    self.scene  = nil
    self.camera = nil
end

-- Back to the scene's own framing. ox / oy is where the camera's focus sits,
-- in window pixels from the window center.
function PhotoMode:reset()
    self.ox, self.oy = self.home_ox, self.home_oy
    self.zoom        = 1
    self.turn        = 0       -- radians, clockwise
    self.pinned      = false   -- held on the stage view (see _stage_view)
end

-- The stage's own framing, the same picture in every stage whatever the vehicle
-- does: photo_view of the stage data (written by the scene generator: the world
-- point at the window center, window pixels per world unit, the world's turn in
-- degrees), else the world center, north up, at the game zoom. The view is
-- relative to the camera's focus and angle, so a pinned view is worked out
-- again before every draw.
function PhotoMode:_stage_view()
    local cam   = self.camera
    local view  = self.app.world.stage.photo_view or {}
    local size  = cam.world_size
    local scale = view.scale or Camera.game_zoom()
    local turn  = math.rad(view.turn or 0)
    local dx    = (cam.x - (view.x or size / 2) + size / 2) % size - size / 2
    local dy    = (cam.y - (view.y or size / 2) + size / 2) % size - size / 2
    local c, s  = math.cos(turn), math.sin(turn)
    self.zoom = scale / cam:base_zoom()
    self.turn = turn - (cam.angle or 0)
    self.ox   = scale * (dx * c - dy * s)
    self.oy   = scale * (dx * s + dy * c)
end

function PhotoMode:_say(text)
    self.note       = text
    self.note_timer = NOTE_TIME
end

-- Turn the view by d radians about the window center.
function PhotoMode:_turn(d)
    self.pinned = false
    local c, s = math.cos(d), math.sin(d)
    self.ox, self.oy = self.ox * c - self.oy * s, self.ox * s + self.oy * c
    self.turn = self.turn + d
end

-- The output size, and the window rectangle a capture covers: the largest
-- centered one of the output's shape.
function PhotoMode:_frame()
    local w, h   = love.graphics.getDimensions()
    local output = self.def.outputs[self.output] or DEFAULTS.outputs[1]
    local out_w  = output.w or w
    local out_h  = output.h or h
    local scale  = math.min(w / out_w, h / out_h)
    local fw, fh = out_w * scale, out_h * scale
    return out_w, out_h, (w - fw) / 2, (h - fh) / 2, fw, fh
end

-- Put the photo view on the camera, k target pixels per window pixel.
function PhotoMode:_put_view(k)
    local cam = self.camera
    self.kept = { view_ox = cam.view_ox, view_oy = cam.view_oy, angle = cam.angle }
    cam.view_ox, cam.view_oy = self.ox * k, self.oy * k
    cam.zoom_scale = self.zoom * k
    if self.turn ~= 0 then
        cam.angle       = (cam.angle or 0) + self.turn
        cam.subject_rot = self.turn
    end
    cam.cull_margin = math.sqrt(self.ox * self.ox + self.oy * self.oy) * k / cam:zoom()
end

function PhotoMode:_take_view()
    local cam, kept = self.camera, self.kept
    cam.view_ox, cam.view_oy, cam.angle = kept.view_ox, kept.view_oy, kept.angle
    cam.zoom_scale, cam.subject_rot, cam.cull_margin = nil, nil, nil
end

function PhotoMode:_draw_world()
    local app = self.app
    app.renderer.highlight = nil
    app.weather:update(0, self.camera)   -- the precipitation is drawn through the view it last saw
    self.scene:draw_world()
end

-- World position under the mouse, with the photo view on the camera.
function PhotoMode:_cursor_world()
    local cam    = self.camera
    local mx, my = love.mouse.getPosition()
    local cx, cy = cam:screen_center()
    local z      = cam:zoom()
    local a      = cam.angle or 0
    local dx, dy = (mx - cx) / z, (my - cy) / z
    local size   = cam.world_size
    return (cam.x + dx * math.cos(a) + dy * math.sin(a)) % size,
           (cam.y - dx * math.sin(a) + dy * math.cos(a)) % size
end

-- Draw the world into a canvas of the output size and write it out. k is output
-- pixels per window pixel.
function PhotoMode:_capture(out_w, out_h, k)
    local g     = love.graphics
    local limit = g.getSystemLimits().texturesize
    if out_w > limit or out_h > limit then
        self:_say(("%d x %d is over this GPU's texture limit of %d"):format(out_w, out_h, limit))
        return
    end
    local canvas = g.newCanvas(out_w, out_h)
    -- The render path sizes its targets and viewports from the window, which
    -- getDimensions reports whatever canvas is bound. It is told the output size
    -- for the length of this draw.
    local get_dimensions, get_width, get_height = g.getDimensions, g.getWidth, g.getHeight
    rawset(g, "getDimensions", function() return out_w, out_h end)
    rawset(g, "getWidth", function() return out_w end)
    rawset(g, "getHeight", function() return out_h end)
    g.push("all")
    g.setCanvas({ canvas, stencil = true })
    g.clear(0, 0, 0, 1)
    self:_put_view(k)
    local ok, err = pcall(self._draw_world, self)
    self:_take_view()
    if ok then
        -- The blended passes leave their own alpha behind; the still is opaque.
        g.origin()
        g.setScissor()
        g.setShader()
        g.setBlendMode("alpha")
        g.setColorMask(false, false, false, true)
        g.setColor(1, 1, 1, 1)
        g.rectangle("fill", 0, 0, out_w, out_h)
    end
    g.pop()
    rawset(g, "getDimensions", get_dimensions)
    rawset(g, "getWidth", get_width)
    rawset(g, "getHeight", get_height)
    if not ok then error(err, 0) end
    local path = Screenshot.save(canvas:newImageData())
    self:_say(path and ("saved " .. path) or "capture failed: could not write the file")
end

-- update

-- Runs once a frame while engaged, in place of the scene's update. Returns the
-- whole ticks the scene is to simulate this frame: one per press of the step
-- key, a slow run while it is held.
function PhotoMode:update(dt)
    if self.note then
        self.note_timer = self.note_timer - dt
        if self.note_timer <= 0 then self.note = nil end
    end
    if love.keyboard.isDown(STEP_KEY) then
        self.hold = self.hold + dt
        if self.hold > HOLD_DELAY then
            self.step_frac = self.step_frac + dt * TICK_RATE * self.def.slow_motion
        end
    else
        self.hold      = 0
        self.step_frac = 0
    end
    local steps = self.steps + math.floor(self.step_frac)
    self.steps     = 0
    self.step_frac = self.step_frac % 1
    local sound = self.app.sound
    if steps == 0 and sound then sound:stop_loops() end
    return steps
end

-- input: each returns true when photo mode took the event

function PhotoMode:keypressed(key)
    if not self:engaged() then
        if key ~= TOGGLE_KEY then return false end
        local scene = self.app.scenes:top()
        if not (scene and scene.draw_world) or self.app.screen:is_active() then return false end
        self:open(scene)
        return true
    end
    local def = self.def
    if key == TOGGLE_KEY or key == "escape" then
        self:close()
    elseif key == "return" or key == "kpenter" or Input.pressed("screenshot", key) then
        self.capture = true
    elseif key == STEP_KEY then
        self.steps = self.steps + 1
    elseif key == "o" then
        self.output = self.output % #def.outputs + 1
    elseif key == "[" then
        self:_turn(-math.rad(def.turn_step))
    elseif key == "]" then
        self:_turn(math.rad(def.turn_step))
    elseif key == "0" then
        self:reset()
    elseif key == "v" then
        self.pinned = true
    elseif key == "tab" then
        self.help = not self.help
    elseif key == "c" and self.cursor_x then
        local text = ("%d, %d"):format(math.floor(self.cursor_x), math.floor(self.cursor_y))
        love.system.setClipboardText(text)
        self:_say("copied " .. text)
    end
    return true
end

-- Zoom about the mouse, so the point under it stays put.
function PhotoMode:wheelmoved(dy)
    if not self:engaged() then return false end
    local def    = self.def
    local zoom   = math.max(def.zoom_min, math.min(def.zoom_max, self.zoom * def.zoom_step ^ dy))
    local factor = zoom / self.zoom
    local w, h   = love.graphics.getDimensions()
    local mx, my = love.mouse.getPosition()
    mx, my = mx - w / 2, my - h / 2
    self.pinned = false
    self.ox   = mx + (self.ox - mx) * factor
    self.oy   = my + (self.oy - my) * factor
    self.zoom = zoom
    return true
end

function PhotoMode:mousemoved(dx, dy)
    if not self:engaged() then return false end
    if love.mouse.isDown(1) then
        self.pinned      = false
        self.ox, self.oy = self.ox + dx, self.oy + dy
    elseif love.mouse.isDown(2) then
        self:_turn(math.rad(dx * self.def.turn_drag))
    end
    return true
end

-- draw

function PhotoMode:_draw_guide(w, h, fx, fy, fw, fh)
    local g = love.graphics
    if fw >= w and fh >= h then return end
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", 0, 0, fx, h)
    g.rectangle("fill", fx + fw, 0, w - fx - fw, h)
    g.rectangle("fill", fx, 0, fw, fy)
    g.rectangle("fill", fx, fy + fh, fw, h - fy - fh)
    g.setColor(1, 1, 1, 0.5)
    g.setLineWidth(1)
    g.rectangle("line", fx + 0.5, fy + 0.5, fw - 1, fh - 1)
end

function PhotoMode:_draw_help(h, out_w, out_h)
    local g      = love.graphics
    local output = self.def.outputs[self.output] or DEFAULTS.outputs[1]
    local lines  = {
        ("PHOTO    zoom %.2f    turn %d%s    %s %d x %d    tick %d    cursor %d, %d"):format(
            self.zoom, math.floor(math.deg(self.turn) % 360 + 0.5), self.pinned and "    STAGE VIEW" or "",
            output.label or "OUTPUT", out_w, out_h,
            self.app.tick, math.floor(self.cursor_x), math.floor(self.cursor_y)),
    }
    if self.help then
        for _, line in ipairs(HELP) do lines[#lines + 1] = line end
    end
    if self.note then lines[#lines + 1] = self.note end
    local font   = g.getFont()
    local line_h = font:getHeight() + 4
    local box_w  = 0
    for _, line in ipairs(lines) do box_w = math.max(box_w, font:getWidth(line)) end
    local y = h - #lines * line_h - 12
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", 6, y - 6, box_w + 16, #lines * line_h + 8, 3)
    for i, line in ipairs(lines) do
        if i == 1 or line == self.note then g.setColor(1, 0.85, 0.35, 1) else g.setColor(1, 1, 1, 0.85) end
        g.print(line, 14, y + (i - 1) * line_h)
    end
end

function PhotoMode:draw()
    local g    = love.graphics
    local w, h = g.getDimensions()
    local out_w, out_h, fx, fy, fw, fh = self:_frame()
    if self.pinned then self:_stage_view() end
    if self.capture then
        self.capture = false
        self:_capture(out_w, out_h, out_h / fh)
    end
    self:_put_view(1)
    self:_draw_world()
    self.cursor_x, self.cursor_y = self:_cursor_world()
    self:_take_view()
    self:_draw_guide(w, h, fx, fy, fw, fh)
    self:_draw_help(h, out_w, out_h)
    g.setColor(1, 1, 1, 1)
end

return PhotoMode
