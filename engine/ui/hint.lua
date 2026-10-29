-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- Footer key hints for the menu screens, drawn in two tones so the key names
-- read apart from what they do: "{UP/DOWN} SELECT   {ENTER} LOAD". A braced
-- span is a key name (bright gold), everything else is action text (dimmed
-- white). Unbraced text draws entirely as action text, so a plain sentence
-- ("PRESS DEL AGAIN TO ERASE THIS SLOT") still works.
--
-- While a gamepad is the device last used in the menus (Hint.use, fed by
-- main.lua), the key names are given as the pad buttons Gamepad.MENU_KEYS
-- binds to them; a key no button stands for is dropped with its action text.
local Hint = {}

Hint.KEY    = { 1, 0.8, 0.2 }
Hint.ACTION = { 1, 1, 1 }

Hint.device = "keys"

-- Pad names of the key names the footers use. Directions read the same on the
-- d-pad; the co-op key sets name the d-pad of the player's own pad.
local PAD_NAMES = {
    ENTER = "A", ESC = "B", ARROWS = "D-PAD",
    ["W S"] = "UP DOWN", ["A D"] = "LEFT RIGHT",
    ["UP/DOWN"] = "UP/DOWN", ["LEFT/RIGHT"] = "LEFT/RIGHT",
    ["UP DOWN"] = "UP DOWN", ["LEFT RIGHT"] = "LEFT RIGHT",
}

local KEY_ALPHA    = 0.95
local ACTION_ALPHA = 0.6
local SHADOW_ALPHA = 0.8

-- device -> text -> ordered { text, key } spans. Cached: the hint strings are
-- a handful of literals redrawn every frame.
local cache = { keys = {}, pad = {} }

-- The device whose names the hints give: "keys" or "pad".
function Hint.use(device)
    Hint.device = device
end

-- Keyboard spans as the pad names them: a key without a button is dropped
-- with the action text after it, and the line loses its trailing blanks.
local function pad_spans(list)
    local out, skip = {}, false
    for _, span in ipairs(list) do
        if span.key then
            local name = PAD_NAMES[span.text]
            skip = name == nil
            if name then out[#out + 1] = { text = name, key = true } end
        elseif not skip then
            out[#out + 1] = span
        end
    end
    local last = out[#out]
    if last and not last.key then
        out[#out] = { text = last.text:gsub("%s+$", ""), key = false }
    end
    return out
end

local function spans(text, raw)
    local device = raw and "keys" or Hint.device
    local out    = cache[device][text]
    if out then return out end
    if device == "pad" then
        out = pad_spans(spans(text, true))
        cache.pad[text] = out
        return out
    end
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
    cache.keys[text] = out
    return out
end

-- opts as for Hint.print (scale, raw).
function Hint.width(font, text, opts)
    opts = opts or {}
    local w = 0
    for _, span in ipairs(spans(text, opts.raw)) do
        w = w + font:width(span.text, opts.scale)
    end
    return w
end

-- opts: { scale, alpha, shadow, raw }. shadow casts the down-right black copy
-- the hints over the vehicle previews need to stay readable; raw prints the
-- braced names as given, whatever the device.
function Hint.print(font, text, x, y, opts)
    opts = opts or {}
    local scale = opts.scale
    local alpha = opts.alpha or 1
    local pen   = x
    for _, span in ipairs(spans(text, opts.raw)) do
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
    local w = Hint.width(font, text, opts)
    return Hint.print(font, text, math.floor((width - w) / 2), y, opts)
end

return Hint
