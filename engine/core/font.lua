local Class = require "engine.core.class"
local json  = require "lib.json"

-- Bitmap fonts decoded from the original game's glyph containers
-- (tools/export_fonts.py -> assets/fonts/<name>.{png,json}). Each glyph is a
-- quad into one atlas. Mask fonts (the default) export white-on-alpha intensity
-- so they can be tinted to any color at draw time; truecolor fonts (OVERKILL)
-- carry their real palette and are drawn untinted.
--
--   local Font = require "engine.core.font"
--   Font.get("hichars"):print("HIGH SCORE", x, y, { color = {1, 0.8, 0.2} })
--
-- Char -> frame: a font with an explicit "charmap" maps charmap[i] -> frame i;
-- a full set with no charmap is ASCII-indexed (frame == codepoint); word fonts
-- (gov/overkill) hold only a left-to-right sequence drawn with print_word.

local Font = Class()

local cache = {}

-- Fonts shipped by the exporter, in a stable order for the gallery.
Font.NAMES = {
    "phasenum", "gov", "gov2", "overkill",
    "chars", "charspow", "charstit", "hichars", "hichars2", "savechar", "endchars", "keysfont",
    "mainmen",
}

function Font.get(name)
    local f = cache[name]
    if f then return f end
    f = Font:new(name)
    cache[name] = f
    return f
end

function Font:init(name)
    self.name = name
    local raw = love.filesystem.read("assets/fonts/" .. name .. ".json")
    local meta = json.decode(raw)
    self.line_height = meta.line_height or 8
    self.word        = meta.word or false
    self.charmap     = meta.charmap   -- string or nil (nil => ASCII identity)
    self.truecolor   = meta.mode == "truecolor"

    self.image = love.graphics.newImage("assets/fonts/" .. name .. ".png")
    self.image:setFilter("nearest", "nearest")
    local iw, ih = self.image:getDimensions()

    self.glyphs = {}   -- frame index -> { quad, w, h, oy, advance }
    for k, gm in pairs(meta.glyphs) do
        self.glyphs[tonumber(k)] = {
            quad    = love.graphics.newQuad(gm.x, gm.y, gm.w, gm.h, iw, ih),
            w       = gm.w,
            h       = gm.h,
            oy      = gm.oy,
            advance = gm.advance,
        }
    end

    self.char_to_frame = {}
    if self.charmap then
        for i = 1, #self.charmap do
            self.char_to_frame[self.charmap:sub(i, i)] = i - 1
        end
    end

    self.sequence = {}   -- existing frame indices in order (word fonts)
    for idx in pairs(self.glyphs) do self.sequence[#self.sequence + 1] = idx end
    table.sort(self.sequence)

    local space = self.glyphs[32]
    self.space_advance = (space and space.advance)
        or math.max(3, math.floor(self.line_height * 0.4))
end

function Font:_glyph_for(ch)
    local f = self.char_to_frame[ch]
    if f then return self.glyphs[f] end
    if not self.charmap then
        return self.glyphs[string.byte(ch)]   -- ASCII identity for full sets
    end
    return nil
end

-- Truecolor fonts keep their baked RGB (no tint) but still honor an alpha so
-- callers can fade them (the main menu fades/blinks/dims its entries); mask
-- fonts take the full tint color. No-color callers draw fully opaque as before.
local function set_tint(color, truecolor)
    if truecolor then
        love.graphics.setColor(1, 1, 1, (color and color[4]) or 1)
    elseif color then
        love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
    else
        love.graphics.setColor(1, 1, 1, 1)
    end
end

-- Draws addressable text (full sets / charmap fonts). opts: { scale, color,
-- tracking }. Returns the pixel width drawn. Truecolor fonts ignore color.
function Font:print(text, x, y, opts)
    opts = opts or {}
    local scale    = opts.scale or 1
    local tracking = opts.tracking or 0
    set_tint(opts.color, self.truecolor)
    local pen = x
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == " " then
            pen = pen + (self.space_advance + tracking) * scale
        else
            local gl = self:_glyph_for(ch)
            if gl then
                love.graphics.draw(self.image, gl.quad, pen, y + gl.oy * scale, 0, scale, scale)
                pen = pen + (gl.advance + tracking) * scale
            else
                pen = pen + (self.space_advance + tracking) * scale
            end
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
    return pen - x
end

function Font:width(text, scale, tracking)
    scale, tracking = scale or 1, tracking or 0
    local w = 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        local gl = ch ~= " " and self:_glyph_for(ch)
        w = w + ((gl and gl.advance or self.space_advance) + tracking) * scale
    end
    return w
end

function Font:word_width(scale, tracking)
    scale, tracking = scale or 1, tracking or 1
    local w = 0
    for _, idx in ipairs(self.sequence) do
        w = w + (self.glyphs[idx].advance + tracking) * scale
    end
    return w
end

-- Draws a word font's whole glyph sequence left to right (gov -> GAMEOVER,
-- overkill -> OVERKILL). opts: { scale, color, tracking }.
function Font:print_word(x, y, opts)
    opts = opts or {}
    local scale    = opts.scale or 1
    local tracking = opts.tracking or 1
    set_tint(opts.color, self.truecolor)
    local pen = x
    for _, idx in ipairs(self.sequence) do
        local gl = self.glyphs[idx]
        love.graphics.draw(self.image, gl.quad, pen, y + gl.oy * scale, 0, scale, scale)
        pen = pen + (gl.advance + tracking) * scale
    end
    love.graphics.setColor(1, 1, 1, 1)
    return pen - x
end

return Font
