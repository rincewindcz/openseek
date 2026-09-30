-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Font   = require "engine.core.font"
local Log    = require "engine.core.log"
local Assets = require "engine.core.assets"
local Audio  = require "engine.core.audio"
local Config = require "engine.core.config"

-- Fullscreen image overlay with fade-in / hold / fade-out phases, used for the
-- title card, the per-mission briefing picture, and the crash end screen.
-- Only one overlay is active at a time.
local Screen = Class()

function Screen:init()
    self._cache = {}
    self.active = nil
end

-- name is a decoded fullscreen picture ("TITLE") or a full content path
-- ("content/intro/openseek_intro.png"). Content pictures are high resolution
-- art, so they are filtered when scaled instead of kept pixel sharp.
function Screen:_img(name)
    if self._cache[name] == nil then
        local content = name:match("%.png$") ~= nil
        local path    = content and name or Assets.path("fullscreen/" .. name .. ".png")
        local ok, img = false, nil
        if love.filesystem.getInfo(path) then ok, img = pcall(love.graphics.newImage, path) end
        if ok then
            local filter = content and "linear" or "nearest"
            img:setFilter(filter, filter)
            self._cache[name] = img
        else
            Log.warn("screen", "missing asset %s", name)
            self._cache[name] = false
        end
    end
    return self._cache[name] or nil
end

-- opts: fade_in, hold, fade_out (seconds); wait_key (hold until a key dismisses
-- it instead of timing out); tag (small bottom-right build-tag text drawn at the
-- overlay's alpha); skippable (Enter / Space cancel it like Esc, in any phase);
-- on_done (called once fully faded out); on_cancel (called when the overlay is
-- cancelled, so the shower decides where Esc goes); cues (a data/audio.json
-- sequence name: radio lines played at their times while the overlay is up)
-- with variant (the vehicle picking each line's per-vehicle entry).
function Screen:show(name, opts)
    opts = opts or {}
    self.active = {
        img       = self:_img(name),
        fade_in   = opts.fade_in  or 0.5,
        hold      = opts.hold     or 1.5,
        fade_out  = opts.fade_out or 0.5,
        wait_key  = opts.wait_key or false,
        skippable = opts.skippable or false,
        timeout   = opts.timeout,   -- wait_key overlays: auto-advance after this many seconds
        tag       = opts.tag,
        on_done   = opts.on_done,
        on_cancel = opts.on_cancel,
        cues      = opts.cues and Audio.sequence(opts.cues),
        variant   = opts.variant,
        next_cue  = 1,
        age       = 0,
        phase     = "in",
        t         = 0,
    }
end

-- Play the overlay's cues that have come due. A dismissed overlay plays no
-- more of them, like the original's key-skippable sequence.
function Screen:_play_cues(overlay)
    local cues = overlay.cues
    while cues and cues[overlay.next_cue] and cues[overlay.next_cue].at <= overlay.age do
        if Config.voice_callouts then
            Audio.play_event(cues[overlay.next_cue].event, { variant = overlay.variant })
        end
        overlay.next_cue = overlay.next_cue + 1
    end
end

function Screen:is_active()
    return self.active ~= nil
end

-- Overlay a mission's intro picture (assets/fullscreen/STAGE0M_MPIC) above
-- whatever scene is active. Appears instantly (no fade-in, so the briefing behind
-- it never bleeds through), holds for one second, then fades out; a key, click or
-- touch dismisses it early. Shown when a campaign run crosses into a new mission
-- (including the first mission of a NEW GAME).
function Screen:show_mission(m)
    if not m then return end
    self:show(string.format("STAGE0%d_MPIC", m),
        { fade_in = 0, fade_out = 0.3, wait_key = true, timeout = 1.0 })
end

-- Drop the current overlay immediately without running its on_done callback;
-- runs on_cancel instead when one was given.
function Screen:cancel()
    local overlay = self.active
    self.active = nil
    if overlay and overlay.on_cancel then overlay.on_cancel() end
end

function Screen:update(dt)
    local overlay = self.active
    if not overlay then return end
    overlay.t   = overlay.t + dt
    overlay.age = overlay.age + dt
    if overlay.phase ~= "out" then self:_play_cues(overlay) end
    if overlay.phase == "in" then
        if overlay.t >= overlay.fade_in then overlay.t = 0; overlay.phase = overlay.wait_key and "wait" or "hold" end
    elseif overlay.phase == "wait" then
        if overlay.timeout and overlay.t >= overlay.timeout then overlay.t = 0; overlay.phase = "out" end
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

local SKIP_KEYS = { ["return"] = true, kpenter = true, space = true }

-- Dismiss a wait_key overlay, or cancel a skippable one on Enter / Space;
-- returns true if a key was consumed.
function Screen:keypressed(key)
    local overlay = self.active
    if overlay and overlay.skippable and SKIP_KEYS[key] then
        self:cancel()
        return true
    end
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
    if overlay.tag then
        self.tag_font = self.tag_font or Font.get("chars")
        local vw = self.tag_font:width(overlay.tag)
        self.tag_font:print(overlay.tag, screen_w - vw - 4,
            screen_h - self.tag_font.line_height - 3, { color = { 1, 1, 1, alpha } })
    end
    g.setColor(1, 1, 1)
end

return Screen
