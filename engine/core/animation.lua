-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local json   = require "lib.json"
local Assets = require "engine.core.assets"

-- AnimClip
-- Immutable definition loaded once from animations.json.
-- Shared across all AnimState instances that use the same clip.

local AnimClip = Class()

function AnimClip:init(def, image_cache)
    self.fps   = def.fps or 12
    self.loop  = def.loop ~= false   -- default true unless explicitly false
    self.frames = {}
    self.frame_paths = {}   -- parallel to frames; source path for lazy anchor calc
    self.anchors = {}       -- lazily filled art-center anchors keyed by frame index
    for _, path in ipairs(def.frames or {}) do
        local img = image_cache[path]
        if not img then
            local full       = Assets.path(path)
            local ok, loaded = false, nil
            if love.filesystem.getInfo(full) then ok, loaded = pcall(love.graphics.newImage, full) end
            if ok then
                loaded:setFilter("nearest", "nearest")
                image_cache[path] = loaded
                img = loaded
            end
        end
        if img then
            self.frames[#self.frames + 1] = img
            self.frame_paths[#self.frames] = Assets.path(path)
        end
    end
end

-- Origin (in pixels) that centers a frame's visible art rather than its image
-- box. Sprites decoded from rotation arcs sit off-center in their shared canvas,
-- so drawing them by image center skews position and rotation. Computed once
-- per frame from the alpha bounding box and cached.
function AnimClip:anchor(i)
    local cached = self.anchors[i]
    if cached then return cached[1], cached[2] end
    local img = self.frames[i]
    if not img then return 0, 0 end
    local w, h = img:getDimensions()
    local ax, ay = w / 2, h / 2
    local path = self.frame_paths[i]
    if path and love.image then
        local ok, data = pcall(love.image.newImageData, path)
        if ok then
            local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
            for py = 0, h - 1 do
                for px = 0, w - 1 do
                    local _, _, _, a = data:getPixel(px, py)
                    if a > 0 then
                        if px < x0 then x0 = px end
                        if px > x1 then x1 = px end
                        if py < y0 then y0 = py end
                        if py > y1 then y1 = py end
                    end
                end
            end
            if x1 >= 0 then
                ax = (x0 + x1 + 1) / 2
                ay = (y0 + y1 + 1) / 2
            end
        end
    end
    self.anchors[i] = { ax, ay }
    return ax, ay
end

function AnimClip:frame_count()
    return #self.frames
end

function AnimClip:is_empty()
    return #self.frames == 0
end

-- AnimState
-- Per-instance playback state.  Holds a reference to a shared AnimClip.

local AnimState = Class()

function AnimState:init(clip)
    self.clip  = clip
    self.frame = 1
    self.timer = 0
    self.done  = false
end

function AnimState:update(dt)
    if self.done or self.clip:is_empty() then return end
    local spf = 1 / math.max(1, self.clip.fps)
    self.timer = self.timer + dt
    while self.timer >= spf do
        self.timer = self.timer - spf
        self.frame = self.frame + 1
        if self.frame > self.clip:frame_count() then
            if self.clip.loop then
                self.frame = 1
            else
                self.frame = self.clip:frame_count()
                self.done  = true
                break
            end
        end
    end
end

function AnimState:current_image()
    if self.clip:is_empty() then return nil end
    return self.clip.frames[self.frame]
end

function AnimState:is_done()
    return self.done or self.clip:is_empty()
end

function AnimState:reset()
    self.frame = 1
    self.timer = 0
    self.done  = false
end

-- Animation module
-- Singleton loader.  Call Animation.load() once at startup.

local Animation = {}

local clips       = {}   -- name -> AnimClip
local image_cache = {}   -- path -> Image

function Animation.load(path)
    local data = love.filesystem.read(path)
    if not data then error("missing " .. path) end
    local defs = json.decode(data)
    for name, def in pairs(defs) do
        clips[name] = AnimClip:new(def, image_cache)
    end
end

function Animation.new(clip_name)
    local clip = clips[clip_name]
    if not clip then
        -- Return a dummy no-op state rather than erroring.
        clip = AnimClip:new({ frames = {}, fps = 1, loop = false }, image_cache)
    end
    return AnimState:new(clip)
end

function Animation.clip(name)
    return clips[name]
end

function Animation.frame_anchor(name, i)
    local clip = clips[name]
    if not clip then return 0, 0 end
    return clip:anchor(i or 1)
end

function Animation.clip_names()
    local names = {}
    for k in pairs(clips) do names[#names + 1] = k end
    table.sort(names)
    return names
end

return Animation
