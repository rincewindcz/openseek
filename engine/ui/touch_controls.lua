local Class   = require "engine.core.class"
local Font    = require "engine.core.font"
local Pointer = require "engine.ui.pointer"

-- On-screen controls for touch play in the single-player gameplay scene. The left
-- half of the screen is a floating stick (it centers wherever the thumb lands),
-- the right side carries the action buttons. Held state is sampled by the input
-- source once per tick like a key (held); button presses queue edge events on
-- the source, so touch reaches the simulation only through the input frame.
-- Drawn while the last pointer input was a touch.
local TouchControls = Class()

-- Sizes and positions in units of screen height; x is measured from the right
-- edge, y from the bottom edge.
local STICK_RADIUS = 0.13
local DEAD_ZONE    = 0.3    -- fraction of STICK_RADIUS before a direction counts
local BUTTON_R     = 0.075
local LABEL_SCALE  = 2

local BUTTONS = {
    { id = "fire",   label = "FIRE",   held  = "fire",     x = 0.17, y = 0.36, r = 1.45 },
    { id = "strafe", label = "STRAFE", held  = "modifier", x = 0.43, y = 0.47, r = 1 },
    { id = "land",   label = "LAND",   event = "takeoff",  x = 0.14, y = 0.66, r = 1 },
    { id = "weapon", label = "WEAPON", event = "weapon",   x = 0.40, y = 0.74, r = 1 },
    { id = "menu",   label = "MENU",   menu  = true,       x = 0.62, y = 0.92, r = 0.7 },
}

function TouchControls:init()
    self:reset()
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
    return screen_w - b.x * screen_h, screen_h - b.y * screen_h, BUTTON_R * b.r * screen_h
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
    if x < screen_w * 0.5 and not self.stick then
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
    local radius = STICK_RADIUS * screen_h
    local dx, dy = stick.x - stick.ox, stick.y - stick.oy
    local len = math.sqrt(dx * dx + dy * dy)
    if len > radius then dx, dy = dx / len * radius, dy / len * radius end
    return dx, dy, radius
end

function TouchControls:held(action)
    for _, b in pairs(self.pressed) do
        if b.held == action then return true end
    end
    if not self.stick then return false end
    local dx, dy, radius = self:_stick_offset()
    local dead = DEAD_ZONE * radius
    if action == "up"    then return dy < -dead end
    if action == "down"  then return dy >  dead end
    if action == "left"  then return dx < -dead end
    if action == "right" then return dx >  dead end
    return false
end

function TouchControls:draw()
    if not self:visible() then return end
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local font = Font.get("chars")
    g.setLineWidth(math.max(2, screen_h * 0.004))

    if self.stick then
        local stick = self.stick
        local dx, dy, radius = self:_stick_offset()
        g.setColor(1, 1, 1, 0.12)
        g.circle("fill", stick.ox, stick.oy, radius)
        g.setColor(1, 1, 1, 0.35)
        g.circle("line", stick.ox, stick.oy, radius)
        g.setColor(1, 1, 1, 0.5)
        g.circle("fill", stick.ox + dx, stick.oy + dy, radius * 0.4)
    end

    local down = {}
    for _, b in pairs(self.pressed) do down[b] = true end
    for _, b in ipairs(BUTTONS) do
        local bx, by, br = button_at(b, screen_w, screen_h)
        g.setColor(1, 1, 1, down[b] and 0.4 or 0.15)
        g.circle("fill", bx, by, br)
        g.setColor(1, 1, 1, 0.45)
        g.circle("line", bx, by, br)
        local w = font:width(b.label, LABEL_SCALE)
        font:print(b.label, math.floor(bx - w / 2),
            math.floor(by - font.line_height * LABEL_SCALE / 2), { scale = LABEL_SCALE })
    end
    g.setLineWidth(1)
    g.setColor(1, 1, 1, 1)
end

return TouchControls
