-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local json      = require "lib.json"
local Animation = require "engine.core.animation"
local Config    = require "engine.core.config"
local Mathx     = require "engine.core.mathx"

-- Shards thrown by explosions, after the original's spawners (research/LEVELS.md,
-- "Effect spawner"). data/debris.json names the kinds of piece and the bursts
-- that throw them. A piece flies out and slows to rest; one with a `fall` sinks
-- from its height, drawn from a smaller row of its clip as it drops, and lands
-- in a dust puff, where a kind with `lie` stays on the ground for a while; the
-- others last for their `life`. Some trail smoke.
-- Presentation only: fed by the one-way World:spawn_debris, advanced with the
-- world and never read back by the simulation (DETERMINISM.md D2), so it draws
-- its random numbers from math.random and leaves world.rng alone.

local Debris = Class()

local DATA_PATH         = "data/debris.json"
local DEFAULT_MAX       = 900
local DEFAULT_MAX_LYING = 600

function Debris:init(world)
    local raw  = love.filesystem.read(DATA_PATH)
    self.data  = raw and json.decode(raw) or {}
    self.world = world
    self:reset()
end

function Debris:reset()
    self.pieces = {}   -- flying {clip, base, frames, sizes, tumble, spin, x, y, vx, vy, ...}
    self.puffs  = {}   -- trail smoke {anim, x, y}
    self.lying  = {}   -- landed pieces, oldest first {image, x, y, left}
end

local function pick(range)
    if type(range) ~= "table" then return range or 0 end
    return range[1] + math.random() * (range[2] - range[1])
end

-- Frame layout of a kind's clip: `variants` blocks of `sizes` rows of `frames`
-- tumble frames, the largest row first. A clip that does not hold exactly that
-- many frames (a pack with frames missing) is played as one plain loop.
local function layout(kind, clip)
    local frames, sizes, variants = kind.frames or #clip.frames, kind.sizes or 1, kind.variants or 1
    if frames * sizes * variants ~= #clip.frames then return #clip.frames, 1, 1 end
    return frames, sizes, variants
end

local function image_of(piece)
    local row = 0
    if piece.height and piece.sizes > 1 then
        row = math.min(piece.sizes - 1, math.floor((1 - piece.height / piece.height0) * piece.sizes))
    end
    return piece.clip.frames[piece.base + row * piece.frames + math.floor(piece.tumble) + 1]
end

function Debris:_spawn(kind, x, y, angle)
    local clip = Animation.clip(kind.clips[math.random(#kind.clips)])
    if not clip or clip:is_empty() then return end
    local frames, sizes, variants = layout(kind, clip)
    local speed = pick(kind.speed)
    local spin  = pick(kind.spin)
    if math.random() < (kind.reverse or 0) then spin = -spin end
    local piece = {
        clip   = clip,
        base   = (math.random(variants) - 1) * frames * sizes,
        frames = frames,
        sizes  = sizes,
        tumble = math.random() * frames,
        spin   = spin,
        x      = x,
        y      = y,
        vx     = math.cos(angle) * speed,
        vy     = math.sin(angle) * speed,
        rest   = kind.rest,
        age    = 0,
        alpha  = 1,
    }
    if kind.fall then
        piece.height0 = kind.height or 4
        piece.height  = piece.height0
        piece.fall    = pick(kind.fall)
        piece.dust    = kind.dust
        piece.lie     = kind.lie
    else
        piece.life = pick(kind.life)
        piece.fade = kind.fade
    end
    if kind.trail and math.random() < kind.trail.chance then
        piece.trail      = kind.trail
        piece.trail_left = kind.trail.time
        piece.trail_wait = 0
    end
    piece.image = image_of(piece)
    self.pieces[#self.pieces + 1] = piece
end

-- Throw the named burst from (x, y). opts.dx / opts.dy aim the kinds that fly
-- in a `cone`, opts.count overrides the piece count of every part.
function Debris:burst(name, x, y, opts)
    local parts = self.data.bursts and self.data.bursts[name]
    if not parts then return end
    local base = math.random() * 2 * math.pi
    if opts and opts.dx and (opts.dx ~= 0 or opts.dy ~= 0) then base = Mathx.atan2(opts.dy, opts.dx) end
    for _, part in ipairs(parts) do
        local kind  = self.data.kinds[part.kind]
        local count = (opts and opts.count) or part.count or 1
        -- EXTRA (shard_amount): more or fewer pieces than the original threw.
        if not part.fixed then count = math.floor(count * Config.shard_amount + 0.5) end
        for i = 1, kind and count or 0 do
            if #self.pieces >= (self.data.max or DEFAULT_MAX) then return end
            local angle
            if part.ring then
                -- Evenly round the burst's own axis (the original's cross of plates).
                angle = base + (part.ring + (i - 1) * 360 / count) * math.pi / 180
                    + (math.random() - 0.5) * (part.jitter or 0)
            elseif kind.cone then
                angle = base + (math.random() - 0.5) * kind.cone
            else
                angle = math.random() * 2 * math.pi
            end
            self:_spawn(kind, x, y, angle)
        end
    end
end

-- A piece reached the ground: a dust puff, and with EXTRA (lying_shards) the
-- piece stays where it fell for its kind's `lie` seconds, the oldest making
-- room past `max_lying`. The original removes it with the puff.
function Debris:_land(piece)
    if piece.dust then self.world:add_ground_dust(piece.x, piece.y) end
    if not piece.lie or not Config.lying_shards then return end
    piece.height = 0
    local lying  = self.lying
    lying[#lying + 1] = { image = image_of(piece), x = piece.x, y = piece.y, left = pick(piece.lie), alpha = 1 }
    local over = #lying - (self.data.max_lying or DEFAULT_MAX_LYING)
    if over > 0 then
        local kept = {}
        for i = over + 1, #lying do kept[#kept + 1] = lying[i] end
        self.lying = kept
    end
end

function Debris:_update_pieces(dt)
    local live = {}
    for _, piece in ipairs(self.pieces) do
        piece.age = piece.age + dt
        local drive = piece.rest and math.max(0, 1 - piece.age / piece.rest) or 1
        piece.x      = piece.x + piece.vx * drive * dt
        piece.y      = piece.y + piece.vy * drive * dt
        piece.tumble = (piece.tumble + piece.spin * dt) % piece.frames
        if piece.trail and piece.trail_left > 0 then
            piece.trail_left = piece.trail_left - dt
            piece.trail_wait = piece.trail_wait - dt
            if piece.trail_wait <= 0 then
                piece.trail_wait = piece.trail_wait + piece.trail.interval
                local anim = Animation.new(piece.trail.clip)
                if not anim:is_done() then
                    self.puffs[#self.puffs + 1] = { anim = anim, x = piece.x, y = piece.y }
                end
            end
        end
        local done
        if piece.height then
            piece.height = piece.height - piece.fall * dt
            done = piece.height <= 0
            if done then self:_land(piece) end
        else
            done = piece.age >= piece.life
            if piece.fade then piece.alpha = math.min(1, (piece.life - piece.age) / piece.fade) end
        end
        if not done then
            piece.image = image_of(piece)
            live[#live + 1] = piece
        end
    end
    self.pieces = live
end

function Debris:update(dt)
    if #self.pieces > 0 then self:_update_pieces(dt) end
    if #self.puffs > 0 then
        local live = {}
        for _, puff in ipairs(self.puffs) do
            puff.anim:update(dt)
            if not puff.anim:is_done() then live[#live + 1] = puff end
        end
        self.puffs = live
    end
    if #self.lying > 0 then
        local fade = self.data.lie_fade or 1
        local live = {}
        for _, piece in ipairs(self.lying) do
            piece.left = piece.left - dt
            if piece.left > 0 then
                piece.alpha = math.min(1, piece.left / fade)
                live[#live + 1] = piece
            end
        end
        self.lying = live
    end
end

return Debris
