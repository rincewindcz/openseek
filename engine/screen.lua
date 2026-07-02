local Class = require "engine.class"

-- Fullscreen image overlay with fade-in / hold / fade-out phases, used for the
-- title card, the per-mission briefing picture, and the crash end screen.
-- Only one overlay is active at a time.
local Screen = Class()

function Screen:init()
    self._cache = {}
    self.active = nil
end

function Screen:_img(name)
    if self._cache[name] == nil then
        local ok, img = pcall(love.graphics.newImage, "assets/fullscreen/" .. name .. ".png")
        if ok then
            img:setFilter("nearest", "nearest")
            self._cache[name] = img
        else
            print("screen: missing asset " .. name)
            self._cache[name] = false
        end
    end
    return self._cache[name] or nil
end

-- opts: fade_in, hold, fade_out (seconds); wait_key (hold until a key dismisses
-- it instead of timing out); on_done (called once fully faded out).
function Screen:show(name, opts)
    opts = opts or {}
    self.active = {
        img      = self:_img(name),
        fade_in  = opts.fade_in  or 0.5,
        hold     = opts.hold     or 1.5,
        fade_out = opts.fade_out or 0.5,
        wait_key = opts.wait_key or false,
        on_done  = opts.on_done,
        phase    = "in",
        t        = 0,
    }
end

function Screen:is_active()
    return self.active ~= nil
end

-- Drop the current overlay immediately without running its on_done callback.
function Screen:cancel()
    self.active = nil
end

function Screen:update(dt)
    local a = self.active
    if not a then return end
    a.t = a.t + dt
    if a.phase == "in" then
        if a.t >= a.fade_in then a.t = 0; a.phase = a.wait_key and "wait" or "hold" end
    elseif a.phase == "hold" then
        if a.t >= a.hold then a.t = 0; a.phase = "out" end
    elseif a.phase == "out" then
        if a.t >= a.fade_out then
            local cb = a.on_done
            self.active = nil
            if cb then cb() end
        end
    end
end

-- Dismiss a wait_key overlay; returns true if a key was consumed.
function Screen:keypressed()
    local a = self.active
    if a and a.phase == "wait" then
        a.t = 0
        a.phase = "out"
        return true
    end
    return a ~= nil
end

function Screen:_alpha(a)
    if a.phase == "in" then
        return a.fade_in > 0 and math.min(1, a.t / a.fade_in) or 1
    elseif a.phase == "out" then
        return a.fade_out > 0 and math.max(0, 1 - a.t / a.fade_out) or 0
    end
    return 1
end

function Screen:draw()
    local a = self.active
    if not a then return end
    local g      = love.graphics
    local sw, sh = g.getDimensions()
    local al     = self:_alpha(a)
    g.setColor(0, 0, 0, al)
    g.rectangle("fill", 0, 0, sw, sh)
    if a.img then
        local iw, ih = a.img:getDimensions()
        local s = math.min(sw / iw, sh / ih)
        g.setColor(1, 1, 1, al)
        g.draw(a.img, (sw - iw * s) / 2, (sh - ih * s) / 2, 0, s, s)
    end
    g.setColor(1, 1, 1)
end

return Screen
