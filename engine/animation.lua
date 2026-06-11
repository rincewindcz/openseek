local Class = require "engine.class"
local json  = require "lib.json"

-- ── AnimClip ──────────────────────────────────────────────────────────────────
-- Immutable definition loaded once from animations.json.
-- Shared across all AnimState instances that use the same clip.

local AnimClip = Class()

function AnimClip:init(def, image_cache)
  self.fps   = def.fps or 12
  self.loop  = def.loop ~= false   -- default true unless explicitly false
  self.frames = {}
  for _, path in ipairs(def.frames or {}) do
    local img = image_cache[path]
    if not img then
      local ok, loaded = pcall(love.graphics.newImage, "assets/" .. path)
      if ok then
        loaded:setFilter("nearest", "nearest")
        image_cache[path] = loaded
        img = loaded
      end
    end
    if img then
      self.frames[#self.frames + 1] = img
    end
  end
end

function AnimClip:frame_count()
  return #self.frames
end

function AnimClip:is_empty()
  return #self.frames == 0
end

-- ── AnimState ─────────────────────────────────────────────────────────────────
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
  return self.done
end

function AnimState:reset()
  self.frame = 1
  self.timer = 0
  self.done  = false
end

-- ── Animation module ──────────────────────────────────────────────────────────
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

function Animation.clip_names()
  local names = {}
  for k in pairs(clips) do names[#names + 1] = k end
  table.sort(names)
  return names
end

return Animation
