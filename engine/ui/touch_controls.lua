-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local Config     = require "engine.core.config"
local Font       = require "engine.core.font"
local Mathx      = require "engine.core.mathx"
local InputFrame = require "engine.core.input_frame"
local Pointer    = require "engine.ui.pointer"

-- On-screen controls for touch play in the single-player gameplay scene. The left
-- half of the screen is a floating stick (it centers wherever the thumb lands),
-- the right side carries the action buttons, each showing its white icon from
-- content/mobileui/ (or its label when the icon is missing). Held state is sampled by the input
-- source once per tick like a key (held), with the stick angle as an analog
-- turn (turn); button presses queue edge events on the source, so touch reaches
-- the simulation only through the input frame.
-- Drawn while the last pointer input was a touch. Colour, opacity, sizes and a
-- mirrored left-handed layout come from the MOBILE UI options (Config.touch_*).
local TouchControls = Class()

-- Sizes and positions in units of screen height; x is measured from the right
-- edge (the left one when left-handed), y from the bottom edge.
local STICK_RADIUS = 0.13
local DEAD_ZONE    = 0.25   -- fraction of STICK_RADIUS before the stick counts

-- Stick angle, measured from straight up (or straight down when reversing):
-- within STRAIGHT it steers straight, and the turn rate grows linearly to full
-- at a sideways push. Within DRIVE_ARC it also drives forward or back.
local STRAIGHT  = math.rad(8)
local DRIVE_ARC = math.rad(65)
local BUTTON_R     = 0.075
local LABEL_SCALE  = 2
local ICON_FIT     = 0.7    -- icon's longer side as a fraction of the button diameter
local ICON_ALPHA   = 0.8
local ICON_DIR     = "content/mobileui/"

-- Base alphas, scaled by Config.touch_opacity.
local STICK_BASE_ALPHA = 0.12
local STICK_RING_ALPHA = 0.35
local STICK_KNOB_ALPHA = 0.5
local BUTTON_ALPHA     = 0.15
local BUTTON_DOWN      = 0.4
local OUTLINE_ALPHA    = 0.45

-- The gold is the in-game CHARS font's.
local COLORS = {
    gold  = { 1, 0.8, 0.2 },
    white = { 1, 1, 1 },
}

local TOUCH_OS = { Web = true, Android = true, iOS = true }

local BUTTONS = {
    { id = "fire",   label = "FIRE",   held  = "fire",     x = 0.17, y = 0.36, r = 1.45 },
    { id = "strafe", label = "STRAFE", held  = "modifier", x = 0.43, y = 0.47, r = 1 },
    { id = "land",   label = "LAND",   event = "takeoff",  x = 0.14, y = 0.66, r = 1 },
    { id = "weapon", label = "WEAPON", event = "weapon",   x = 0.40, y = 0.74, r = 1 },
    { id = "menu",   label = "MENU",   menu  = true,       x = 0.62, y = 0.92, r = 0.7 },
}

-- Whether this build can be played by touch, so the MOBILE UI options apply:
-- web and phone builds, or a desktop run with the `--touch` emulation.
function TouchControls.available(app)
    return TOUCH_OS[love.system.getOS()] or (app and app.touch_emulation) or false
end

function TouchControls:init()
    self:reset()
    -- Icons are drawn well below their size, so they filter linearly.
    self.icons = {}
    for _, b in ipairs(BUTTONS) do
        local path = ICON_DIR .. "icon_" .. b.id .. ".png"
        if love.filesystem.getInfo(path) then
            local ok, img = pcall(love.graphics.newImage, path)
            if ok then
                img:setFilter("linear", "linear")
                self.icons[b.id] = img
            end
        end
    end
end

-- Drop every tracked touch (scene change, menu, pause): a release that happens
-- elsewhere must not leave an action held.
function TouchControls:reset()
    self.stick   = nil   -- { id, ox, oy, x, y }
    self.pressed = {}    -- touch id -> button
end

function TouchControls:visible()
    return Pointer.touch
end

local function button_at(b, screen_w, screen_h)
    local offset = b.x * screen_h
    local x      = Config.touch_left_handed and offset or screen_w - offset
    return x, screen_h - b.y * screen_h, BUTTON_R * b.r * Config.touch_button_scale * screen_h
end

-- Window position of a button's center, for the desktop `--touch` emulation.
function TouchControls.button_center(id)
    local screen_w, screen_h = love.graphics.getDimensions()
    for _, b in ipairs(BUTTONS) do
        if b.id == id then
            local bx, by = button_at(b, screen_w, screen_h)
            return bx, by
        end
    end
end

function TouchControls:_hit(x, y)
    local screen_w, screen_h = love.graphics.getDimensions()
    for _, b in ipairs(BUTTONS) do
        local bx, by, br = button_at(b, screen_w, screen_h)
        local dx, dy = x - bx, y - by
        if dx * dx + dy * dy <= br * br * 1.2 then return b end
    end
end

-- Returns "menu" when the menu button was hit, true when the touch was taken,
-- false when it belongs to someone else.
function TouchControls:touchpressed(id, x, y, source)
    local b = self:_hit(x, y)
    if b then
        self.pressed[id] = b
        if b.event then source:queue(b.event) end
        if b.menu then
            self:reset()
            return "menu"
        end
        return true
    end
    local screen_w = love.graphics.getDimensions()
    local stick_side = (x < screen_w * 0.5) ~= (Config.touch_left_handed == true)
    if stick_side and not self.stick then
        self.stick = { id = id, ox = x, oy = y, x = x, y = y }
        return true
    end
    return false
end

function TouchControls:touchmoved(id, x, y)
    local stick = self.stick
    if stick and stick.id == id then
        stick.x, stick.y = x, y
        return true
    end
    return self.pressed[id] ~= nil
end

function TouchControls:touchreleased(id)
    if self.stick and self.stick.id == id then
        self.stick = nil
        return true
    end
    if self.pressed[id] then
        self.pressed[id] = nil
        return true
    end
    return false
end

-- Stick offset clamped to the stick radius, in pixels.
function TouchControls:_stick_offset()
    local stick = self.stick
    local _, screen_h = love.graphics.getDimensions()
    local radius = STICK_RADIUS * Config.touch_stick_scale * screen_h
    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local len = math.sqrt(dx * dx + dy * dy)
    if len > radius then dx, dy = dx / len * radius, dy / len * radius end
    return dx, dy, radius
end

-- Stick angle from the nearest vertical in [-pi/2, pi/2] (positive to the right)
-- and the vertical offset, or nil inside the dead zone.
function TouchControls:_stick_angle()
    if not self.stick then return nil end
    local dx, dy, radius = self:_stick_offset()
    if dx * dx + dy * dy < (DEAD_ZONE * radius) ^ 2 then return nil end
    return Mathx.atan2(dx, math.abs(dy)), dy
end

function TouchControls:held(action)
    for _, b in pairs(self.pressed) do
        if b.held == action then return true end
    end
    local a, dy = self:_stick_angle()
    if not a then return false end
    if action == "up"    then return dy < 0 and math.abs(a) <= DRIVE_ARC end
    if action == "down"  then return dy > 0 and math.abs(a) <= DRIVE_ARC end
    if action == "left"  then return a < -STRAIGHT end
    if action == "right" then return a >  STRAIGHT end
    return false
end

-- Analog turn in InputFrame steps, or nil when the stick is not steering.
function TouchControls:turn()
    local a = self:_stick_angle()
    if not a or math.abs(a) <= STRAIGHT then return nil end
    local k    = math.min(1, (math.abs(a) - STRAIGHT) / (math.pi / 2 - STRAIGHT))
    local step = math.floor(k * InputFrame.TURN_STEPS + 0.5)
    if step == 0 then return nil end
    return a < 0 and -step or step
end

function TouchControls:draw()
    if not self:visible() then return end
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local font = Font.get("chars")
    local col  = COLORS[Config.touch_color] or COLORS.gold
    local function tint(alpha)
        g.setColor(col[1], col[2], col[3], math.min(1, alpha * Config.touch_opacity))
    end
    g.setLineWidth(math.max(2, screen_h * 0.004))

    if self.stick then
        local stick = self.stick
        local dx, dy, radius = self:_stick_offset()
        tint(STICK_BASE_ALPHA)
        g.circle("fill", stick.ox, stick.oy, radius)
        tint(STICK_RING_ALPHA)
        g.circle("line", stick.ox, stick.oy, radius)
        tint(STICK_KNOB_ALPHA)
        g.circle("fill", stick.ox + dx, stick.oy + dy, radius * 0.4)
    end

    local down = {}
    for _, b in pairs(self.pressed) do down[b] = true end
    for _, b in ipairs(BUTTONS) do
        local bx, by, br = button_at(b, screen_w, screen_h)
        tint(down[b] and BUTTON_DOWN or BUTTON_ALPHA)
        g.circle("fill", bx, by, br)
        tint(OUTLINE_ALPHA)
        g.circle("line", bx, by, br)
        local icon = self.icons[b.id]
        if icon then
            local w, h  = icon:getDimensions()
            local scale = ICON_FIT * 2 * br / math.max(w, h)
            tint(down[b] and 1 or ICON_ALPHA)
            g.draw(icon, bx, by, 0, scale, scale, w / 2, h / 2)
        else
            local w     = font:width(b.label, LABEL_SCALE)
            local alpha = math.min(1, (down[b] and 1 or ICON_ALPHA) * Config.touch_opacity)
            font:print(b.label, math.floor(bx - w / 2),
                math.floor(by - font.line_height * LABEL_SCALE / 2),
                { scale = LABEL_SCALE, color = { 1, 1, 1, alpha } })
        end
    end
    g.setLineWidth(1)
    g.setColor(1, 1, 1, 1)
end

return TouchControls
