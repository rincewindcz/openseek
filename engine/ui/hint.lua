-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Footer key hints for the menu screens, drawn in two tones so the key names
-- read apart from what they do: "{UP/DOWN} SELECT   {ENTER} LOAD". A braced
-- span is a key name (bright gold), everything else is action text (dimmed
-- white). Unbraced text draws entirely as action text, so a plain sentence
-- ("PRESS DEL AGAIN TO ERASE THIS SLOT") still works.
local Hint = {}

Hint.KEY    = { 1, 0.8, 0.2 }
Hint.ACTION = { 1, 1, 1 }

local KEY_ALPHA    = 0.95
local ACTION_ALPHA = 0.6
local SHADOW_ALPHA = 0.8

-- text -> ordered { text, key } spans. Cached: the hint strings are a handful
-- of literals redrawn every frame.
local cache = {}

local function spans(text)
    local out = cache[text]
    if out then return out end
    out = {}
    local i = 1
    while i <= #text do
        local s, e = text:find("{.-}", i)
        if not s then
            out[#out + 1] = { text = text:sub(i), key = false }
            break
        end
        if s > i then out[#out + 1] = { text = text:sub(i, s - 1), key = false } end
        out[#out + 1] = { text = text:sub(s + 1, e - 1), key = true }
        i = e + 1
    end
    cache[text] = out
    return out
end

function Hint.width(font, text, scale)
    local w = 0
    for _, span in ipairs(spans(text)) do
        w = w + font:width(span.text, scale)
    end
    return w
end

-- opts: { scale, alpha, shadow }. shadow casts the down-right black copy the
-- hints over the vehicle previews need to stay readable.
function Hint.print(font, text, x, y, opts)
    opts = opts or {}
    local scale = opts.scale
    local alpha = opts.alpha or 1
    local pen   = x
    for _, span in ipairs(spans(text)) do
        local hue = span.key and Hint.KEY or Hint.ACTION
        local a   = (span.key and KEY_ALPHA or ACTION_ALPHA) * alpha
        if opts.shadow then
            font:print(span.text, pen + 1, y + 1,
                { color = { 0, 0, 0, SHADOW_ALPHA * a }, scale = scale })
        end
        pen = pen + font:print(span.text, pen, y,
            { color = { hue[1], hue[2], hue[3], a }, scale = scale })
    end
    return pen - x
end

-- Centered in the design canvas (or any width), the common footer placement.
function Hint.print_centered(font, text, width, y, opts)
    local w = Hint.width(font, text, opts and opts.scale)
    return Hint.print(font, text, math.floor((width - w) / 2), y, opts)
end

return Hint
