-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local Log   = require "engine.core.log"

-- Autodesk FLI / FLC animation, decoded one frame at a time into a palette
-- index buffer and an RGBA image that the caller draws. Covers the common
-- chunk set: COLOR_256 (4), DELTA_FLC (7), COLOR_64 (11), DELTA_FLI (12),
-- BLACK (13), BYTE_RUN (15) and FLI_COPY (16). Playback speed is the caller's
-- (the original drives REGANIM.FLC from its own timer; the header says 0).
--
--   local anim = Flic.open("assets/ending/reganim.flc")
--   if anim then anim:next_frame(); love.graphics.draw(anim.image) end
local Flic = Class()

local FLI_MAGIC    = 0xAF11
local FLC_MAGIC    = 0xAF12
local FRAME_MAGIC  = 0xF1FA
local HEADER_SIZE  = 128

local COLOR_256 = 4
local DELTA_FLC = 7
local COLOR_64  = 11
local DELTA_FLI = 12
local BLACK     = 13
local BYTE_RUN  = 15
local FLI_COPY  = 16

local byte = string.byte

local function u16(s, p)
    local a, b = byte(s, p, p + 1)
    return a + b * 256
end

local function u32(s, p)
    local a, b, c, d = byte(s, p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function s8(s, p)
    local v = byte(s, p)
    return v < 128 and v or v - 256
end

-- The animation at `path`, or nil when it is missing or not a FLI / FLC.
function Flic.open(path)
    if not love.filesystem.getInfo(path) then return nil end
    local ok, data = pcall(love.filesystem.read, path)
    if not ok or not data or #data < HEADER_SIZE then
        Log.warn("flic", "cannot read %s", path)
        return nil
    end
    local magic = u16(data, 5)
    if magic ~= FLC_MAGIC and magic ~= FLI_MAGIC then
        Log.warn("flic", "%s is not a FLI / FLC", path)
        return nil
    end
    return Flic:new(data, magic)
end

function Flic:init(data, magic)
    self.data    = data
    self.frames  = u16(data, 7)
    self.width   = u16(data, 9)
    self.height  = u16(data, 11)
    self.decoded = 0
    local first  = magic == FLC_MAGIC and u32(data, 81) or 0
    self._pos    = (first > 0 and first or HEADER_SIZE) + 1

    self._index   = {}
    self._palette = {}
    for i = 0, 255 do self._palette[i] = { 0, 0, 0 } end
    for i = 0, self.width * self.height - 1 do self._index[i] = 0 end

    self.pixels = love.image.newImageData(self.width, self.height)
    self.pixels:mapPixel(function() return 0, 0, 0, 1 end)
    self.image = love.graphics.newImage(self.pixels)
    self.image:setFilter("nearest", "nearest")
end

function Flic:done()
    return self.decoded >= self.frames
end

-- Decode the next frame into self.image. Returns false past the last frame
-- (the ring frame some files append, which loops back to the first, is never
-- played).
function Flic:next_frame()
    if self:done() then return false end
    local s = self.data
    while self._pos + 6 <= #s do
        local size = u32(s, self._pos)
        local kind = u16(s, self._pos + 4)
        local at   = self._pos
        if size < 6 then
            self.decoded = self.frames
            return false
        end
        self._pos = self._pos + size
        if kind == FRAME_MAGIC then
            self:_frame(at)
            self.decoded = self.decoded + 1
            self.image:replacePixels(self.pixels)
            return true
        end
    end
    self.decoded = self.frames
    return false
end

function Flic:_frame(at)
    local s      = self.data
    local chunks = u16(s, at + 6)
    local p      = at + 16
    self._repaint = false
    for _ = 1, chunks do
        local size = u32(s, p)
        local kind = u16(s, p + 4)
        local body = p + 6
        if kind == COLOR_256 or kind == COLOR_64 then
            self:_color(body, kind == COLOR_64 and 63 or 255)
        elseif kind == DELTA_FLC then
            self:_delta_flc(body)
        elseif kind == DELTA_FLI then
            self:_delta_fli(body)
        elseif kind == BYTE_RUN then
            self:_byte_run(body)
        elseif kind == BLACK then
            self:_fill_black()
        elseif kind == FLI_COPY then
            self:_copy(body)
        end
        p = p + size
    end
    if self._repaint then self:_repaint_all() end
end

function Flic:_color(p, max)
    local s       = self.data
    local packets = u16(s, p)
    p = p + 2
    local i = 0
    for _ = 1, packets do
        i = i + byte(s, p)
        local count = byte(s, p + 1)
        if count == 0 then count = 256 end
        p = p + 2
        for _ = 1, count do
            local r, g, b = byte(s, p, p + 2)
            self._palette[i % 256] = { r / max, g / max, b / max }
            i = i + 1
            p = p + 3
        end
    end
    self._repaint = true
end

-- Store one pixel. While the palette changed this frame, the whole image is
-- repainted afterwards, so only the index is kept.
function Flic:_put(x, y, c)
    self._index[y * self.width + x] = c
    if not self._repaint then
        local col = self._palette[c]
        self.pixels:setPixel(x, y, col[1], col[2], col[3], 1)
    end
end

function Flic:_repaint_all()
    local index, palette, w = self._index, self._palette, self.width
    self.pixels:mapPixel(function(x, y)
        local col = palette[index[y * w + x]]
        return col[1], col[2], col[3], 1
    end)
end

-- Word-oriented delta: per line, packets of pixel pairs; line words with the
-- top bits set skip lines (11) or store the line's last pixel (10).
function Flic:_delta_flc(p)
    local s, w = self.data, self.width
    local lines = u16(s, p)
    p = p + 2
    local y = 0
    while lines > 0 do
        local word = u16(s, p)
        p = p + 2
        if word >= 0xC000 then
            y = y + (65536 - word)
        elseif word >= 0x8000 then
            self:_put(w - 1, y, word % 256)
        else
            local x = 0
            for _ = 1, word do
                x = x + byte(s, p)
                local n = s8(s, p + 1)
                p = p + 2
                if n > 0 then
                    for _ = 1, n do
                        self:_put(x, y, byte(s, p))
                        self:_put(x + 1, y, byte(s, p + 1))
                        x = x + 2
                        p = p + 2
                    end
                elseif n < 0 then
                    local a, b = byte(s, p, p + 1)
                    p = p + 2
                    for _ = 1, -n do
                        self:_put(x, y, a)
                        self:_put(x + 1, y, b)
                        x = x + 2
                    end
                end
            end
            y = y + 1
            lines = lines - 1
        end
    end
end

function Flic:_delta_fli(p)
    local s = self.data
    local y0, count = u16(s, p), u16(s, p + 2)
    p = p + 4
    for y = y0, y0 + count - 1 do
        local packets = byte(s, p)
        p = p + 1
        local x = 0
        for _ = 1, packets do
            x = x + byte(s, p)
            local n = s8(s, p + 1)
            p = p + 2
            if n > 0 then
                for _ = 1, n do
                    self:_put(x, y, byte(s, p))
                    x = x + 1
                    p = p + 1
                end
            elseif n < 0 then
                local c = byte(s, p)
                p = p + 1
                for _ = 1, -n do
                    self:_put(x, y, c)
                    x = x + 1
                end
            end
        end
    end
end

function Flic:_byte_run(p)
    local s, w = self.data, self.width
    for y = 0, self.height - 1 do
        p = p + 1   -- packet count, unused
        local x = 0
        while x < w do
            local n = s8(s, p)
            p = p + 1
            if n < 0 then
                for _ = 1, -n do
                    self:_put(x, y, byte(s, p))
                    x = x + 1
                    p = p + 1
                end
            else
                local c = byte(s, p)
                p = p + 1
                for _ = 1, n do
                    self:_put(x, y, c)
                    x = x + 1
                end
            end
        end
    end
end

function Flic:_fill_black()
    for i = 0, self.width * self.height - 1 do self._index[i] = 0 end
    self._repaint = true
end

function Flic:_copy(p)
    local s = self.data
    for i = 0, self.width * self.height - 1 do self._index[i] = byte(s, p + i) end
    self._repaint = true
end

return Flic
