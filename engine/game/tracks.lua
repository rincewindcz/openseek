-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local json      = require "lib.json"
local Config    = require "engine.core.config"
local Camera    = require "engine.core.camera"
local Animation = require "engine.core.animation"
local Vehicles  = require "engine.game.vehicles"

-- EXTRA (tank_tracks): faint tread marks a tank leaves on the ground, fading out
-- after a while. Presentation only: it reads the players after each tick and
-- never writes simulation state. Tuning is data/tracks.json.
--
-- Each mark is a pair of short tread bars across the hull's two tracks, laid
-- every `spacing` world units of travel. `gauge` and `tread` are fractions of
-- the variant's hull width; `mark_length` is in world units (below `spacing`
-- it leaves the gaps of a tread pattern).
local Tracks = Class()

local DATA_PATH = "data/tracks.json"

local DEFAULTS = {
    lifetime    = 12,
    fade        = 5,
    alpha       = 0.09,
    color       = { 0.1, 0.08, 0.06 },
    spacing     = 3,
    mark_length = 1.8,
    gauge       = 0.76,
    tread       = 0.2,
    max_marks   = 1500,
}

local FALLBACK_HULL_WIDTH = 21

function Tracks:init()
    local raw  = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    local data = raw and json.decode(raw) or {}
    self.data  = {}
    for k, v in pairs(DEFAULTS) do
        if data[k] ~= nil then self.data[k] = data[k] else self.data[k] = v end
    end
    self.marks      = {}   -- {x, y, rot, half_gauge, tread, age}, oldest first
    self.last       = setmetatable({}, { __mode = "k" })   -- player -> {x, y} of the last mark
    self.world_size = nil
    self.batch      = nil
    self.dirty      = false
end

function Tracks:enter(world)
    self:reset()
    self.world_size = world and world.stage and world.stage.world_size or nil
end

function Tracks:reset()
    self.marks = {}
    self.last  = setmetatable({}, { __mode = "k" })
    self.dirty = true
end

-- Shortest wrapped offset from a to b on the seamless map.
function Tracks:_offset(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local size = self.world_size
    if size then
        dx = dx % size; if dx > size * 0.5 then dx = dx - size end
        dy = dy % size; if dy > size * 0.5 then dy = dy - size end
    end
    return dx, dy
end

-- Hull width in world units: art pixels at the fixed gameplay zoom.
function Tracks._hull_width(player)
    local clip = Animation.clip(Vehicles.variant("tank", player.tank_skin).hull)
    local img  = clip and clip.frames[1]
    local w    = img and img:getWidth() or FALLBACK_HULL_WIDTH
    return w * player.sprite_scale / Camera.game_zoom()
end

function Tracks:_emit(player, x, y)
    local d     = self.data
    local width = Tracks._hull_width(player)
    self.marks[#self.marks + 1] = {
        x = x, y = y, rot = player.angle * math.pi / 180,
        half_gauge = width * d.gauge * 0.5, tread = width * d.tread, age = 0,
    }
end

function Tracks:_track(player)
    if player.vehicle ~= "tank" or player.death or player:is_airborne() then
        self.last[player] = nil
        return
    end
    local last = self.last[player]
    if not last then
        self.last[player] = { x = player.x, y = player.y }
        return
    end
    local spacing = self.data.spacing
    local dx, dy  = self:_offset(last.x, last.y, player.x, player.y)
    local dist    = math.sqrt(dx * dx + dy * dy)
    if dist > spacing * 8 then
        last.x, last.y = player.x, player.y   -- respawn or teleport, not a drive
    elseif dist >= spacing then
        local x, y = last.x + dx * 0.5, last.y + dy * 0.5
        if self.world_size then x, y = x % self.world_size, y % self.world_size end
        self:_emit(player, x, y)
        last.x, last.y = player.x, player.y
    end
end

function Tracks:update(dt, players)
    local marks    = self.marks
    local lifetime = self.data.lifetime
    for _, m in ipairs(marks) do m.age = m.age + dt end
    if Config.tank_tracks then
        for _, p in ipairs(players) do self:_track(p) end
    else
        self.last = setmetatable({}, { __mode = "k" })
    end
    local expired = 0
    while expired < #marks and marks[expired + 1].age >= lifetime do expired = expired + 1 end
    expired = math.max(expired, #marks - self.data.max_marks)
    if expired > 0 then
        local kept = {}
        for i = expired + 1, #marks do kept[#kept + 1] = marks[i] end
        self.marks = kept
    end
    self.dirty = self.dirty or #marks > 0
end

function Tracks:_rebuild()
    local g = love.graphics
    local d = self.data
    if not self.batch then
        local pixel = love.image.newImageData(1, 1)
        pixel:setPixel(0, 0, 1, 1, 1, 1)
        self.batch = g.newSpriteBatch(g.newImage(pixel), d.max_marks * 2, "stream")
    end
    local batch   = self.batch
    local r, gr, b = d.color[1], d.color[2], d.color[3]
    batch:clear()
    for _, m in ipairs(self.marks) do
        local a = d.alpha * math.min(1, (d.lifetime - m.age) / d.fade)
        if a > 0 then
            batch:setColor(r, gr, b, a)
            local px, py = math.cos(m.rot), math.sin(m.rot)   -- hull's right, as rot is 0 = north
            for side = -1, 1, 2 do
                local o = side * m.half_gauge
                batch:add(m.x + px * o, m.y + py * o, m.rot, m.tread, d.mark_length, 0.5, 0.5)
            end
        end
    end
    self.dirty = false
end

-- Draws every mark in world space; called inside the renderer's ground pass
-- (once per wrapped tile).
function Tracks:draw()
    if not Config.tank_tracks or #self.marks == 0 then return end
    if self.dirty or not self.batch then self:_rebuild() end
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(self.batch)
end

return Tracks
