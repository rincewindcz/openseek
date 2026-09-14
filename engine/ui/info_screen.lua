local Class     = require "engine.core.class"
local Layout    = require "engine.ui.layout"
local Pointer   = require "engine.ui.pointer"
local Animation = require "engine.core.animation"

-- Shared animated info screen behind the CREDITS and HIGH SCORES entries: a
-- fullscreen backdrop, a one-shot title zoom-in animation across the top,
-- caller-supplied body content, and a single EXIT button in the bottom-right
-- corner. Fades in on open and through black on confirm, then calls
-- self.on_exit(). The owner scene sets self.on_exit and (optionally)
-- self.on_draw_content(g, fade), which draws in the 320x240 design space.
local InfoScreen = Class()

local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local TITLE_CY     = 24     -- vertical center of the zoom-in title
local TITLE_MAX_W  = 300    -- title art is scaled down to fit this width
local EXIT_MARGIN  = 8      -- design px the EXIT button is inset from the corner
local FOCUS_PAD    = 2
local OPEN_TIME    = 0.3
local CONFIRM_TIME = 0.3

local function img(path)
    local ok, i = false, nil
    if love.filesystem.getInfo(path) then ok, i = pcall(love.graphics.newImage, path) end
    if ok then i:setFilter("nearest", "nearest"); return i end
    print("infoscreen: missing " .. path)
    return nil
end

function InfoScreen:init(backdrop_name, title_clip)
    self.backdrop = img("assets/fullscreen/" .. backdrop_name .. ".png")
    if self.backdrop then self.backdrop:setFilter("linear", "linear") end

    -- Title fly-in. Scaled uniformly so its widest frame fits TITLE_MAX_W (the
    -- HIGH SCORES art ends wider than the screen; CREDITS already fits).
    self.title_clip = title_clip
    self.title      = Animation.new(title_clip)
    local clip, maxw = Animation.clip(title_clip), 1
    if clip then
        for i = 1, clip:frame_count() do
            local f = clip.frames[i]
            if f and f:getWidth() > maxw then maxw = f:getWidth() end
        end
    end
    self.title_scale = math.min(1, TITLE_MAX_W / maxw)

    self.exit_up   = img("assets/mission/exit.png")
    self.exit_down = img("assets/mission/exit_hi.png")
    self.focus     = img("assets/hud/selfocus_f01.png")
    local ew = self.exit_up and self.exit_up:getWidth()  or 46
    local eh = self.exit_up and self.exit_up:getHeight() or 12
    self.exit = { x = DW - ew - EXIT_MARGIN, y = DH - eh - EXIT_MARGIN, w = ew, h = eh }

    self.active = false
end

function InfoScreen:is_active() return self.active end
function InfoScreen:close() self.active = false end

function InfoScreen:open()
    self.title:reset()
    self.open_t     = 0
    self.confirming = false
    self.confirm_t  = 0
    self.pressed    = false
    self.active     = true
end

function InfoScreen:_over_exit(x, y)
    local dx, dy = Pointer.to_design(x, y, DW, DH)
    local e = self.exit
    return dx >= e.x and dx <= e.x + e.w and dy >= e.y and dy <= e.y + e.h
end

-- Hover has no state to move (EXIT is the only widget), but the app dispatches
-- it, so keep the no-op explicit.
function InfoScreen:hover() end

function InfoScreen:press(x, y)
    if not self.active or self.confirming then return end
    if self:_over_exit(x, y) then self.pressed = true end
end

function InfoScreen:release(x, y)
    if not self.active or self.confirming then return end
    local was = self.pressed
    self.pressed = false
    if was and self:_over_exit(x, y) then self:_confirm() end
end

function InfoScreen:keypressed(key)
    if not self.active or self.confirming then return end
    if key == "escape" or key == "return" or key == "space" or key == "kpenter" then
        self:_confirm()
    end
end

function InfoScreen:_confirm()
    self.confirming = true
    self.confirm_t  = 0
    self.pressed    = true   -- keep EXIT shown pressed during the fade
end

function InfoScreen:update(dt)
    if not self.active then return end
    self.title:update(dt)
    if self.open_t < OPEN_TIME then self.open_t = self.open_t + dt end
    if not self.confirming then return end
    self.confirm_t = self.confirm_t + dt
    if self.confirm_t >= CONFIRM_TIME then
        self.confirming = false
        self.pressed    = false
        if self.on_exit then self.on_exit() end
    end
end

function InfoScreen:_fade()
    if self.confirming then return math.max(0, 1 - self.confirm_t / CONFIRM_TIME) end
    if self.open_t and self.open_t < OPEN_TIME then return self.open_t / OPEN_TIME end
    return 1
end

function InfoScreen:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade = self:_fade()
    local scale, ox, oy = Layout.fit(screen_w, screen_h)

    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    if self.backdrop then
        g.setColor(fade, fade, fade, 1)
        g.draw(self.backdrop, 0, 0, 0, DW / self.backdrop:getWidth(), DH / self.backdrop:getHeight())
    end

    -- Title fly-in, centered horizontally over the top of the backdrop.
    local frame = self.title:current_image()
    if frame then
        local ax, ay = Animation.frame_anchor(self.title_clip, self.title.frame)
        local s = self.title_scale
        g.setColor(1, 1, 1, fade)
        g.draw(frame, DW / 2, TITLE_CY, 0, s, s, ax, ay)
    end

    if self.on_draw_content then self.on_draw_content(g, fade) end

    -- EXIT button, bottom-right, with its focus ring (it is the only widget).
    local sprite = self.pressed and self.exit_down or self.exit_up
    if sprite then g.setColor(1, 1, 1, fade); g.draw(sprite, self.exit.x, self.exit.y) end
    if self.focus then
        g.setColor(1, 1, 1, fade)
        g.draw(self.focus, self.exit.x - FOCUS_PAD, self.exit.y - FOCUS_PAD, 0,
            (self.exit.w + FOCUS_PAD * 2) / self.focus:getWidth(),
            (self.exit.h + FOCUS_PAD * 2) / self.focus:getHeight())
    end

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return InfoScreen
