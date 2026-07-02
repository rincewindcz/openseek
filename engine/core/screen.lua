local Class = require "engine.core.class"

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
    local overlay = self.active
    if not overlay then return end
    overlay.t = overlay.t + dt
    if overlay.phase == "in" then
        if overlay.t >= overlay.fade_in then overlay.t = 0; overlay.phase = overlay.wait_key and "wait" or "hold" end
    elseif overlay.phase == "hold" then
        if overlay.t >= overlay.hold then overlay.t = 0; overlay.phase = "out" end
    elseif overlay.phase == "out" then
        if overlay.t >= overlay.fade_out then
            local cb = overlay.on_done
            self.active = nil
            if cb then cb() end
        end
    end
end

-- Dismiss a wait_key overlay; returns true if a key was consumed.
function Screen:keypressed()
    local overlay = self.active
    if overlay and overlay.phase == "wait" then
        overlay.t = 0
        overlay.phase = "out"
        return true
    end
    return overlay ~= nil
end

function Screen:_alpha(overlay)
    if overlay.phase == "in" then
        return overlay.fade_in > 0 and math.min(1, overlay.t / overlay.fade_in) or 1
    elseif overlay.phase == "out" then
        return overlay.fade_out > 0 and math.max(0, 1 - overlay.t / overlay.fade_out) or 0
    end
    return 1
end

function Screen:draw()
    local overlay = self.active
    if not overlay then return end
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local alpha = self:_alpha(overlay)
    g.setColor(0, 0, 0, alpha)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    if overlay.img then
        local img_w, img_h = overlay.img:getDimensions()
        local scale = math.min(screen_w / img_w, screen_h / img_h)
        g.setColor(1, 1, 1, alpha)
        g.draw(overlay.img, (screen_w - img_w * scale) / 2, (screen_h - img_h * scale) / 2, 0, scale, scale)
    end
    g.setColor(1, 1, 1)
end

return Screen
