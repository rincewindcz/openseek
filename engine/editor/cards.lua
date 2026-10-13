-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Font = require "engine.core.font"
local View = require "engine.editor.view"

-- The pictures beside a map's briefing paragraphs (the "briefing_cards" of
-- engine/game/map_file.lua), composed in the shape of the original's cards: a
-- slot number, a framed square, a caption. A map never stores pixels: a card
-- is either a square of the map itself, drawn from the map when it is shown,
-- or a reference to a card of a pack stage's briefing.
local Cards = {}

local SLOT_PITCH = 54    -- vertical stride of the slots in a pack card strip
local SLOT_H     = 47    -- height of one slot's art
local SLOTS      = 3
local NUMBER_W   = 17    -- the slot number sits left of the frame
local NUMBER_H   = 9
local FRAME_X    = 17    -- the frame's outer square, as on the original cards
local FRAME_W    = 46
local FRAME_H    = 45
local SHADOW     = 2
local LABEL_Y    = 34
local LABEL_PAD  = 3

local FRAME_COLOR  = { 252 / 255, 252 / 255, 252 / 255 }
local SHADOW_COLOR = { 80 / 255, 80 / 255, 96 / 255 }
local LABEL_FONT   = "chars"

Cards.W     = FRAME_X + FRAME_W + SHADOW
Cards.H     = SLOT_H
Cards.SLOTS = SLOTS
Cards.SIZES = { 44, 88, 176 }   -- world pixels a map square may take in; 44 is the cards' own scale

local strips    = {}   -- path -> { image, data } or false
local originals

local function strip(path)
    local hit = strips[path]
    if hit == nil then
        hit = false
        if love.filesystem.getInfo(path) then
            local ok, data = pcall(love.image.newImageData, path)
            if ok then
                local image = love.graphics.newImage(data)
                image:setFilter("nearest", "nearest")
                hit = { image = image, data = data }
            end
        end
        strips[path] = hit
    end
    return hit or nil
end

local function strip_path(mission, phase)
    return string.format("assets/phase/stage%d_phase%d_f00.png", mission, phase)
end

-- Rightmost opaque pixel of a slot's art, or -1 when the slot is empty.
local function slot_edge(data, slot)
    local w, h  = data:getDimensions()
    local right = -1
    for y = slot * SLOT_PITCH, math.min(slot * SLOT_PITCH + SLOT_H, h) - 1 do
        for x = w - 1, right + 1, -1 do
            local _, _, _, a = data:getPixel(x, y)
            if a > 0.06 then right = x; break end
        end
    end
    return right
end

-- Every card of the pack's briefings: { stage, slot, image, quad, w }.
function Cards.originals()
    if originals then return originals end
    originals = {}
    for mission = 0, 4 do
        for phase = 1, 4 do
            local hit = strip(strip_path(mission, phase))
            if hit then
                local w, h = hit.image:getDimensions()
                for slot = 0, SLOTS - 1 do
                    local edge = slot_edge(hit.data, slot)
                    if edge >= FRAME_X then
                        originals[#originals + 1] = {
                            stage = string.format("stage%d%d", mission, phase - 1), slot = slot,
                            image = hit.image, w = edge + 1,
                            quad  = love.graphics.newQuad(0, slot * SLOT_PITCH, edge + 1,
                                math.min(SLOT_H, h - slot * SLOT_PITCH), w, h),
                        }
                    end
                end
            end
        end
    end
    return originals
end

local function original(stage, slot)
    for _, card in ipairs(Cards.originals()) do
        if card.stage == stage and card.slot == slot then return card end
    end
    return nil
end

-- The number of a slot as the art set's own cards draw it, from the first of
-- its strips that reaches that slot (else from any art set's).
local function number_art(art, slot)
    local missions = { tonumber(art) or 0, 0, 1, 2, 3, 4 }
    for _, mission in ipairs(missions) do
        for phase = 1, 4 do
            local hit = strip(strip_path(mission, phase))
            if hit and slot_edge(hit.data, slot) >= FRAME_X then
                local w, h = hit.image:getDimensions()
                return hit.image, love.graphics.newQuad(0, slot * SLOT_PITCH, NUMBER_W, NUMBER_H, w, h)
            end
        end
    end
    return nil
end

-- A caption as a card shows it: upper case, cut to what fits across the frame
-- (four or five letters of the card font).
function Cards.caption(text)
    local label = tostring(text or ""):upper()
    local font  = Font.get(LABEL_FONT)
    local room  = FRAME_W - 2 - LABEL_PAD * 2
    while #label > 0 and font:width(label) > room do label = label:sub(1, -2) end
    return label
end

-- A card as a canvas (nearest filtered, one pixel per briefing design pixel),
-- or nil for no card. slot (0-2) picks the number drawn beside it.
function Cards.compose(doc, card, slot)
    if type(card) ~= "table" then return nil end
    local source = card.kind == "card" and original(card.stage, card.slot)
    if card.kind ~= "view" and not source then return nil end
    local g      = love.graphics
    local width  = source and math.max(Cards.W, source.w) or Cards.W
    local canvas = g.newCanvas(width, Cards.H)
    canvas:setFilter("nearest", "nearest")
    g.push("all")
    g.setCanvas(canvas)
    g.origin()
    g.setScissor()
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    if source then
        -- The pack card without its own number, which belongs to its own slot.
        g.setScissor(NUMBER_W, 0, width - NUMBER_W, Cards.H)
        g.draw(source.image, source.quad, 0, 0)
        g.setScissor()
    else
        g.setColor(SHADOW_COLOR)
        g.rectangle("fill", FRAME_X + 1, SHADOW - 1, FRAME_W + 1, FRAME_H + 1)
        g.setColor(FRAME_COLOR)
        g.rectangle("fill", FRAME_X, 0, FRAME_W, FRAME_H)
        View.draw_region(doc, card.x or 0, card.y or 0, card.size or Cards.SIZES[1],
            FRAME_X + 1, 1, FRAME_W - 2, FRAME_H - 2)
        local label = Cards.caption(card.label)
        if label ~= "" then
            local font = Font.get(LABEL_FONT)
            g.setScissor(FRAME_X + 1, 1, FRAME_W - 2, FRAME_H - 2)
            for _, offset in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 } }) do
                font:print(label, FRAME_X + 1 + LABEL_PAD + offset[1], LABEL_Y + offset[2], { color = { 0, 0, 0, 1 } })
            end
            font:print(label, FRAME_X + 1 + LABEL_PAD, LABEL_Y)
            g.setScissor()
        end
    end
    local image, quad = number_art(doc:art(), slot)
    if image then
        g.setColor(1, 1, 1, 1)
        g.draw(image, quad, 0, 0)
    end
    g.pop()
    return canvas
end

-- The cards of a map for its briefing: { [slot] = { image, w } }, slots 0-2.
function Cards.for_map(doc)
    local out = {}
    for slot = 0, SLOTS - 1 do
        local canvas = Cards.compose(doc, doc.map.briefing_cards[slot + 1], slot)
        if canvas then out[slot] = { image = canvas, w = canvas:getWidth() } end
    end
    return out
end

return Cards
