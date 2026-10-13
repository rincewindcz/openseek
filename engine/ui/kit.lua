-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local json  = require "lib.json"

-- Widget kit of the map editor: panels, buttons, fields, lists, menus and
-- dialogs in one dense tool look (the shipped "Loaded" font, tinted icon
-- masks from content/editor/icons/, colours and sizes from data/editor.json
-- "theme").
--
-- Immediate mode: a widget is a call made while drawing, which draws it and
-- reports what the pointer did to it since the last frame. The scene feeds the
-- input callbacks in (mousepressed, keypressed, textinput, ...), brackets its
-- draw with begin() / finish(), and keeps no widget objects. Popups, menus and
-- the dialog are deferred to finish() so they draw above everything, and own
-- the input while open: a widget reacts only on the layer that had the topmost
-- popup or dialog at the end of the last frame.
--
-- All positions are UI units: window pixels divided by the kit's scale.
local Kit = Class()

local FONT_PATH  = "content/fonts/loaded/loaded.ttf"
local ICON_DIR   = "content/editor/icons/"
local ICON_SIZES = { 16, 20, 32, 40 }
local THEME_PATH = "data/editor.json"

local MODAL_LAYER = 100
local TIP_DELAY   = 0.55
local CARET_BLINK = 0.5
local WHEEL_ROWS  = 3

local DEFAULT_THEME = {
    panel       = { 0.082, 0.090, 0.110, 0.97 },
    panel_head  = { 0.118, 0.130, 0.160, 1 },
    border      = { 0.190, 0.210, 0.250, 1 },
    widget      = { 0.140, 0.156, 0.192, 1 },
    widget_hot  = { 0.190, 0.212, 0.262, 1 },
    widget_down = { 0.250, 0.280, 0.340, 1 },
    field       = { 0.055, 0.060, 0.075, 1 },
    accent      = { 1.000, 0.800, 0.200, 1 },
    accent_dim  = { 0.420, 0.340, 0.100, 1 },
    text        = { 0.860, 0.880, 0.920, 1 },
    text_dim    = { 0.520, 0.550, 0.610, 1 },
    text_dark   = { 0.070, 0.070, 0.080, 1 },
    danger      = { 0.950, 0.360, 0.300, 1 },
    warn        = { 1.000, 0.680, 0.240, 1 },
    ok          = { 0.400, 0.840, 0.500, 1 },
    shade       = { 0, 0, 0, 0.55 },
    row         = 22,
    pad         = 6,
    gap         = 4,
    font        = 13,
    font_small  = 11,
    font_title  = 15,
    text_dy     = 0,
    icon        = 16,
}

local function load_theme()
    local theme = {}
    for k, v in pairs(DEFAULT_THEME) do theme[k] = v end
    local raw  = love.filesystem.getInfo(THEME_PATH) and love.filesystem.read(THEME_PATH)
    local data = raw and json.decode(raw)
    for k, v in pairs(data and data.theme or {}) do theme[k] = v end
    return theme
end

function Kit:init()
    self.theme    = load_theme()
    self.scale    = 1
    self.fonts    = {}    -- "px" -> love Font
    self.icons    = {}    -- "name_px" -> Image, or false when missing
    self.mx       = 0
    self.my       = 0
    self.down     = {}    -- mouse button -> held
    self.pressed  = {}    -- mouse button -> went down since the last frame
    self.released = {}
    self.wheel    = 0
    self.input    = {}    -- keys and typed text queued for the focused field, in order
    self.hot      = nil   -- widget under the pointer this frame
    self.active   = nil   -- widget the left button went down on
    self.edit     = nil   -- { id, text, caret, original } of the focused field
    self.refocus  = nil   -- { id, frames }: the text box that takes the keyboard next frame
    self.layer       = 0
    self.input_layer = 0
    self.regions      = {}   -- pointer-opaque rects of this frame
    self.last_regions = {}
    self.popups   = {}    -- open popups, bottom first
    self.modal    = nil   -- the dialog asked for this frame
    self.had_modal = false
    self.results  = {}    -- widget id -> value picked in its popup
    self.scrolls  = {}    -- scroll area id -> offset
    self.clips    = {}    -- clip rect stack
    self.areas    = {}    -- open scroll areas
    self.tip      = nil   -- { id, text, since }
    self.tip_seen = nil
    self.time     = 0
end

-- UI scale for a window height: 1 on a small window, 1.25 from about full HD
-- (the font is wide and reads better a size up), then 1.5 and 2.
Kit.SCALES = { 1, 1.25, 1.5, 2 }

function Kit.scale_for(height)
    if height >= 1900 then return 2 end
    if height >= 1300 then return 1.5 end
    if height >= 1000 then return 1.25 end
    return 1
end

function Kit:size()
    local w, h = love.graphics.getDimensions()
    return w / self.scale, h / self.scale
end

-- input callbacks

function Kit:mousepressed(_x, _y, button)
    button = button or 1
    self.pressed[button] = true
    self.down[button]    = true
end

function Kit:mousereleased(_x, _y, button)
    button = button or 1
    self.released[button] = true
    self.down[button]     = false
end

function Kit:wheelmoved(dy)
    self.wheel = self.wheel + dy
end

-- True when the key went to a text field or closed a popup.
function Kit:keypressed(key)
    if self.edit then
        self.input[#self.input + 1] = { key = key }
        return true
    end
    if key == "escape" and #self.popups > 0 then
        table.remove(self.popups)
        return true
    end
    return false
end

function Kit:textinput(text)
    if self.edit then self.input[#self.input + 1] = { text = text } end
end

-- A text field has the keyboard.
function Kit:wants_keys()
    return self.edit ~= nil
end

function Kit:blur()
    self.edit    = nil
    self.refocus = nil
    self.input   = {}
end

-- Window position over a panel, a popup or under the dialog.
function Kit:over(x, y)
    if self.had_modal or #self.popups > 0 then return true end
    x, y = x / self.scale, y / self.scale
    for _, r in ipairs(self.last_regions) do
        if x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] then return true end
    end
    return false
end

function Kit:busy()
    return self.had_modal or #self.popups > 0
end

-- frame

function Kit:update(dt)
    self.time = self.time + dt
end

function Kit:begin()
    local g = love.graphics
    local x, y = love.mouse.getPosition()
    self.mx, self.my = x / self.scale, y / self.scale
    self.hot      = nil
    self.regions  = {}
    self.layer    = 0
    self.modal    = nil
    self.tip_seen = nil
    self.clips    = {}
    self.areas    = {}
    g.push("all")
    g.scale(self.scale)
    g.setLineWidth(1)
    g.setLineStyle("rough")
end

function Kit:finish()
    local g = love.graphics
    local modal = self.modal
    if modal then
        self.layer = MODAL_LAYER
        self:_draw_modal(modal)
    end
    -- A popup may open another while it draws, so the list is walked by index.
    local i = 1
    while i <= #self.popups do
        local popup = self.popups[i]
        self.layer = popup.layer
        self:_draw_popup(popup)
        i = i + 1
    end
    -- A press outside every popup closes them all; the widget under it still
    -- sees nothing, because it sat on a lower layer this frame.
    if (self.pressed[1] or self.pressed[2]) and #self.popups > 0 then
        local inside = false
        for _, popup in ipairs(self.popups) do
            if popup.fresh or self:_in_rect(popup.x, popup.y, popup.w, popup.h) then inside = true end
        end
        if not inside then self.popups = {} end
    end
    for _, popup in ipairs(self.popups) do popup.fresh = nil end
    self:_draw_tip()
    g.pop()

    local top = self.popups[#self.popups]
    self.input_layer  = top and top.layer or (modal and MODAL_LAYER or 0)
    self.had_modal    = modal ~= nil
    self.last_regions = self.regions
    if self.released[1] then self.active = nil end
    if self.refocus then
        self.refocus.frames = self.refocus.frames - 1
        if self.refocus.frames <= 0 then self.refocus = nil end
    end
    self.pressed, self.released = {}, {}
    self.wheel = 0
    if not self.edit then self.input = {} end
end

-- drawing helpers

function Kit:font(size)
    size = size or self.theme.font
    local px   = math.floor(size * self.scale + 0.5)
    local font = self.fonts[px]
    if not font then
        font = love.graphics.newFont(FONT_PATH, px)
        font:setFilter("linear", "linear")
        self.fonts[px] = font
    end
    return font
end

function Kit:text_width(text, size)
    return self:font(size):getWidth(text) / self.scale
end

function Kit:text_height(size)
    return self:font(size):getHeight() / self.scale
end

local function set_color(c, alpha)
    love.graphics.setColor(c[1], c[2], c[3], (c[4] or 1) * (alpha or 1))
end

function Kit:rect(x, y, w, h, color, radius)
    set_color(color)
    love.graphics.rectangle("fill", x, y, w, h, radius or 0)
end

function Kit:frame(x, y, w, h, color, radius)
    set_color(color)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, radius or 0)
end

-- Text at (x, y), top left. opts: color, size, alpha.
function Kit:print(text, x, y, opts)
    opts = opts or {}
    local g = love.graphics
    local s = self.scale
    g.setFont(self:font(opts.size))
    set_color(opts.color or self.theme.text, opts.alpha)
    g.print(text, math.floor(x * s + 0.5) / s, math.floor((y + self.theme.text_dy) * s + 0.5) / s, 0, 1 / s, 1 / s)
end

-- text cut to fit w, closed with ".." when it does not.
function Kit:fit(text, w, size)
    if self:text_width(text, size) <= w then return text end
    local n = #text
    while n > 1 and self:text_width(text:sub(1, n) .. "..", size) > w do n = n - 1 end
    return text:sub(1, n) .. ".."
end

-- Text set in a box. opts: color, size, align ("left", "center", "right"), pad.
function Kit:label(text, x, y, w, h, opts)
    opts = opts or {}
    local size = opts.size
    local pad  = opts.pad or 0
    text = self:fit(tostring(text), w - pad * 2, size)
    local tw = self:text_width(text, size)
    local tx = x + pad
    if opts.align == "center" then tx = x + (w - tw) / 2
    elseif opts.align == "right" then tx = x + w - pad - tw end
    self:print(text, tx, y + (h - self:text_height(size)) / 2, opts)
end

-- Text wrapped to w; returns the height it took. opts as print, plus dry (only measure).
function Kit:paragraph(text, x, y, w, opts)
    opts = opts or {}
    local font = self:font(opts.size)
    local _, lines = font:getWrap(text, w * self.scale)
    local line_h   = self:text_height(opts.size) + 2
    if not opts.dry then
        for i, line in ipairs(lines) do self:print(line, x, y + (i - 1) * line_h, opts) end
    end
    return #lines * line_h
end

function Kit:icon_image(name, size)
    local want = size * self.scale
    local px   = ICON_SIZES[#ICON_SIZES]
    for _, s in ipairs(ICON_SIZES) do
        if s >= want - 0.01 then px = s; break end
    end
    local key = name .. "_" .. px
    local img = self.icons[key]
    if img == nil then
        local path = ICON_DIR .. key .. ".png"
        img = love.filesystem.getInfo(path) and love.graphics.newImage(path) or false
        if img then img:setFilter("linear", "linear") end
        self.icons[key] = img
    end
    return img or nil, px
end

function Kit:icon(name, x, y, size, color, alpha)
    size = size or self.theme.icon
    local img, px = self:icon_image(name, size)
    if not img then return end
    set_color(color or self.theme.text, alpha)
    local s = self.scale
    love.graphics.draw(img, math.floor(x * s + 0.5) / s, math.floor(y * s + 0.5) / s, 0, size / px, size / px)
end

-- An image scaled down (never up past `max_scale`) to sit centered in a box.
function Kit:image(img, x, y, w, h, quad, max_scale)
    local iw, ih = img:getDimensions()
    if quad then
        local _, _, qw, qh = quad:getViewport()
        iw, ih = qw, qh
    end
    local k  = math.min(w / iw, h / ih, max_scale or 2)
    local dx = x + (w - iw * k) / 2
    local dy = y + (h - ih * k) / 2
    if quad then
        love.graphics.draw(img, quad, dx, dy, 0, k, k)
    else
        love.graphics.draw(img, dx, dy, 0, k, k)
    end
end

-- hit testing

function Kit:_in_rect(x, y, w, h)
    return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h
end

function Kit:_in_clip()
    local clip = self.clips[#self.clips]
    return not clip or self:_in_rect(clip[1], clip[2], clip[3], clip[4])
end

function Kit:_live()
    return self.layer == self.input_layer
end

-- The pointer is on this widget and the widget may react to it.
function Kit:hover(id, x, y, w, h)
    if not self:_live() or not self:_in_rect(x, y, w, h) or not self:_in_clip() then return false end
    if self.active and self.active ~= id then return false end
    self.hot = id
    return true
end

-- Hover plus the click protocol: pressed on it, released on it.
function Kit:click(id, x, y, w, h)
    local hover = self:hover(id, x, y, w, h)
    if hover and self.pressed[1] then self.active = id end
    local clicked = hover and self.released[1] and self.active == id
    return clicked, hover, self.active == id
end

-- Mark a rect as covered by the UI: a press there never reaches the viewport.
function Kit:region(x, y, w, h)
    self.regions[#self.regions + 1] = { x, y, w, h }
end

function Kit:set_tip(id, text)
    if not text then return end
    self.tip_seen = id
    if not self.tip or self.tip.id ~= id then
        self.tip = { id = id, text = text, since = self.time }
    end
end

function Kit:_draw_tip()
    local tip = self.tip
    if not tip then return end
    if self.tip_seen ~= tip.id then self.tip = nil; return end
    if self.time - tip.since < TIP_DELAY then return end
    local theme = self.theme
    local w     = self:text_width(tip.text, theme.font_small) + theme.pad * 2
    local h     = self:text_height(theme.font_small) + theme.pad
    local sw, sh = self:size()
    local x  = math.min(self.mx + 14, sw - w - 2)
    local y  = math.min(self.my + 18, sh - h - 2)
    self:rect(x, y, w, h, theme.field, 3)
    self:frame(x, y, w, h, theme.accent_dim, 3)
    self:label(tip.text, x, y, w, h, { size = theme.font_small, pad = theme.pad })
end

-- containers

function Kit:panel(x, y, w, h, opts)
    opts = opts or {}
    self:region(x, y, w, h)
    self:rect(x, y, w, h, opts.color or self.theme.panel)
    if opts.border ~= false then self:frame(x, y, w, h, self.theme.border) end
end

-- A section strip; returns the y below it.
function Kit:header(text, x, y, w, opts)
    local theme = self.theme
    self:rect(x, y, w, theme.row, theme.panel_head)
    self:label(text, x, y, w, theme.row, { pad = theme.pad, color = (opts and opts.color) or theme.accent, size = theme.font_small })
    return y + theme.row
end

function Kit:separator(x, y, w)
    self:rect(x, y, w, 1, self.theme.border)
end

-- Clip drawing and pointer hits to a rect until the matching unclip().
function Kit:clip(x, y, w, h)
    local s = self.scale
    local prev = { love.graphics.getScissor() }
    love.graphics.intersectScissor(math.floor(x * s), math.floor(y * s), math.ceil(w * s), math.ceil(h * s))
    self.clips[#self.clips + 1] = { x, y, w, h, prev }
end

function Kit:unclip()
    local clip = table.remove(self.clips)
    local prev = clip[5]
    if prev[1] then love.graphics.setScissor(prev[1], prev[2], prev[3], prev[4]) else love.graphics.setScissor() end
end

-- A scrolling area: draw the content at y - offset between the two calls.
-- Returns the offset.
function Kit:scroll_begin(id, x, y, w, h, content_h)
    local theme  = self.theme
    local limit  = math.max(0, content_h - h)
    local offset = math.max(0, math.min(limit, self.scrolls[id] or 0))
    if self.wheel ~= 0 and self:_live() and self:_in_rect(x, y, w, h) and self:_in_clip() then
        offset = math.max(0, math.min(limit, offset - self.wheel * theme.row * WHEEL_ROWS))
        self.wheel = 0
    end
    self.scrolls[id] = offset
    self.areas[#self.areas + 1] = { id = id, x = x, y = y, w = w, h = h, content_h = content_h, limit = limit }
    self:clip(x, y, w, h)
    return offset
end

function Kit:scroll_end()
    self:unclip()
    local area = table.remove(self.areas)
    if area.limit <= 0 then return end
    local theme  = self.theme
    local bar_w  = 4
    local bx     = area.x + area.w - bar_w
    local thumb  = math.max(16, area.h * area.h / area.content_h)
    local travel = area.h - thumb
    local id     = area.id .. "#bar"
    local _, hover, held = self:click(id, bx - 4, area.y, bar_w + 4, area.h)
    if held then
        local k = math.max(0, math.min(1, (self.my - area.y - thumb / 2) / travel))
        self.scrolls[area.id] = k * area.limit
    end
    local ty = area.y + travel * (self.scrolls[area.id] / area.limit)
    self:rect(bx, ty, bar_w, thumb, (hover or held) and theme.accent or theme.border, 2)
end

-- Scroll an area so the span [y0, y1] of its content is in view.
function Kit:scroll_to(id, y0, y1, h)
    local offset = self.scrolls[id] or 0
    if y0 < offset then offset = y0 elseif y1 > offset + h then offset = y1 - h end
    self.scrolls[id] = offset
end

-- widgets

-- opts: text, icon, tip, on (drawn as switched on), disabled, flat (no body
-- until hovered), primary (accent body), danger, align, size.
function Kit:button(id, x, y, w, h, opts)
    opts = opts or {}
    local theme = self.theme
    local clicked, hover, held = false, false, false
    if not opts.disabled then clicked, hover, held = self:click(id, x, y, w, h) end
    if hover then self:set_tip(id, opts.tip) end

    local body
    if opts.primary then body = held and theme.accent_dim or theme.accent
    elseif held then body = theme.widget_down
    elseif hover then body = theme.widget_hot
    elseif opts.on then body = theme.accent_dim
    elseif not opts.flat then body = theme.widget end
    if body then self:rect(x, y, w, h, body, 3) end
    if opts.on and not opts.primary then self:frame(x, y, w, h, theme.accent, 3) end

    local color = theme.text
    if opts.disabled then color = theme.text_dim
    elseif opts.primary then color = theme.text_dark
    elseif opts.danger then color = theme.danger
    elseif opts.on then color = theme.accent end
    local alpha = opts.disabled and 0.5 or 1
    local isz   = opts.icon_size or theme.icon
    if opts.icon and not opts.text then
        self:icon(opts.icon, x + (w - isz) / 2, y + (h - isz) / 2, isz, color, alpha)
    elseif opts.icon then
        local tw    = self:text_width(self:fit(opts.text, w - isz - theme.pad * 3, opts.size), opts.size)
        local start = opts.align == "left" and x + theme.pad or x + (w - isz - theme.gap - tw) / 2
        self:icon(opts.icon, start, y + (h - isz) / 2, isz, color, alpha)
        self:label(opts.text, start + isz + theme.gap, y, x + w - start - isz - theme.gap - theme.pad, h,
            { color = color, alpha = alpha, size = opts.size })
    elseif opts.text then
        self:label(opts.text, x, y, w, h, { align = opts.align or "center", pad = theme.pad, color = color,
            alpha = alpha, size = opts.size })
    end
    return clicked, hover
end

-- A check box with its label; returns the value and whether it changed.
function Kit:check(id, x, y, w, text, value, opts)
    opts = opts or {}
    local theme = self.theme
    local h     = theme.row
    local clicked, hover = false, false
    if not opts.disabled then clicked, hover = self:click(id, x, y, w, h) end
    if hover then self:set_tip(id, opts.tip) end
    local box = 14
    local by  = y + (h - box) / 2
    self:rect(x, by, box, box, hover and theme.widget_hot or theme.field, 3)
    self:frame(x, by, box, box, value and theme.accent or theme.border, 3)
    if value then self:icon("check", x - 1, by - 1, 16, theme.accent) end
    self:label(text, x + box + theme.pad, y, w - box - theme.pad, h, { color = opts.disabled and theme.text_dim or theme.text })
    if clicked then return not value, true end
    return value, false
end

-- Whether a text box takes the keyboard now. A press on it while another box
-- is being edited first ends that edit, which reports its text when that box
-- is drawn; this one takes over on the next frame.
function Kit:_takes_focus(id, hover)
    if self.refocus and self.refocus.id == id and not self.edit then
        self.refocus = nil
        return true
    end
    if not (hover and self.pressed[1]) then return false end
    if self.edit then
        self.refocus = { id = id, frames = 2 }
        return false
    end
    return true
end

-- A single-line text field. opts: max (characters), hint (shown when empty),
-- commit (report the text only on Enter or on losing focus), filter (pattern
-- one typed character must match). Returns text, changed, committed.
function Kit:field(id, x, y, w, text, opts)
    opts = opts or {}
    local theme = self.theme
    local h     = opts.h or theme.row
    text = tostring(text or "")
    local hover = self:hover(id, x, y, w, h)
    local edit  = self.edit and self.edit.id == id and self.edit or nil
    local changed, committed = false, false

    if not edit and self:_takes_focus(id, hover) then
        self.edit = { id = id, text = text, caret = #text, original = text }
        edit = self.edit
        self.input = {}
    elseif edit and self.pressed[1] and not hover then
        committed = true
    end

    if edit then
        local before = edit.text
        local limit  = opts.max or 200
        for _, event in ipairs(self.input) do
            local key = event.key
            for ch in (event.text or ""):gmatch(".") do
                if ch:byte() >= 32 and ch:byte() < 127 and #edit.text < limit
                and (not opts.filter or ch:match(opts.filter)) then
                    edit.text  = edit.text:sub(1, edit.caret) .. ch .. edit.text:sub(edit.caret + 1)
                    edit.caret = edit.caret + 1
                end
            end
            if key == "backspace" and edit.caret > 0 then
                edit.text  = edit.text:sub(1, edit.caret - 1) .. edit.text:sub(edit.caret + 1)
                edit.caret = edit.caret - 1
            elseif key == "delete" then
                edit.text = edit.text:sub(1, edit.caret) .. edit.text:sub(edit.caret + 2)
            elseif key == "left" then edit.caret = math.max(0, edit.caret - 1)
            elseif key == "right" then edit.caret = math.min(#edit.text, edit.caret + 1)
            elseif key == "home" then edit.caret = 0
            elseif key == "end" then edit.caret = #edit.text
            elseif key == "v" and love.keyboard.isDown("lctrl", "rctrl") then
                local clip = (love.system.getClipboardText() or ""):gsub("[^\32-\126]", " ")
                clip       = clip:sub(1, math.max(0, limit - #edit.text))
                edit.text  = edit.text:sub(1, edit.caret) .. clip .. edit.text:sub(edit.caret + 1)
                edit.caret = edit.caret + #clip
            elseif key == "return" or key == "kpenter" or key == "tab" then
                committed = true
            elseif key == "escape" then
                edit.text = edit.original
                committed = true
            end
        end
        self.input = {}
        changed = edit.text ~= before
        if opts.commit then
            changed = committed and edit.text ~= edit.original
            if committed then text = edit.text end
        else
            text = edit.text
        end
        if committed then self.edit = nil end
    end

    self:rect(x, y, w, h, theme.field, 3)
    self:frame(x, y, w, h, edit and theme.accent or (hover and theme.widget_down or theme.border), 3)
    local shown = (edit and not committed) and edit.text or text
    local inner = w - theme.pad * 2
    self:clip(x + 2, y, w - 4, h)
    local ty = y + (h - self:text_height()) / 2
    if shown == "" and opts.hint and not edit then
        self:print(opts.hint, x + theme.pad, ty, { color = theme.text_dim })
    else
        -- Keep the caret in view when the text is wider than the field.
        local caret_x = edit and self:text_width(shown:sub(1, edit.caret)) or 0
        local shift   = math.max(0, caret_x - inner + 2)
        self:print(shown, x + theme.pad - shift, ty, { color = opts.color })
        if edit and not committed and (self.time % (CARET_BLINK * 2)) < CARET_BLINK then
            self:rect(x + theme.pad - shift + caret_x, y + 4, 1, h - 8, theme.accent)
        end
    end
    self:unclip()
    return text, changed, committed
end

-- The lines a text takes in a box `width` wide: each { first, last } (byte
-- positions; an empty line has last = first - 1). A line break in the text
-- ends a line and belongs to none; a line too long is broken after its last
-- space that fits, which stays at the end of the line it closes.
function Kit:_wrap(text, width, size)
    local lines = {}
    local n     = #text
    local start = 1
    while start <= n + 1 do
        local stop = (text:find("\n", start, true) or (n + 1)) - 1
        local from = start
        repeat
            local to = stop
            if self:text_width(text:sub(from, to), size) > width then
                local space
                to = from
                for i = from, stop do
                    if i > from and self:text_width(text:sub(from, i), size) > width then break end
                    if text:sub(i, i) == " " then space = i end
                    to = i
                end
                if to < stop and space then to = space end
            end
            lines[#lines + 1] = { from, to }
            from = to + 1
        until from > stop
        start = stop + 2
    end
    return lines
end

-- The line the caret is on: the last one it touches, so a caret where a long
-- line was broken stands at the start of the next.
local function caret_line(lines, caret)
    local found = 1
    for i, line in ipairs(lines) do
        if caret >= line[1] - 1 and caret <= line[2] then found = i end
    end
    return found
end

-- A text box of several lines: the text wraps, Enter starts a new line, the
-- arrows move the caret through the lines as they are shown. It reports the
-- text once, on Tab or on losing focus; Esc puts the text back. opts: max
-- (characters), hint (shown when empty). Returns text, changed, committed.
function Kit:area(id, x, y, w, h, text, opts)
    opts = opts or {}
    local theme  = self.theme
    local size   = opts.size
    local line_h = self:text_height(size) + 2
    local inner  = w - theme.pad * 2 - 4
    text = tostring(text or "")
    local hover = self:hover(id, x, y, w, h)
    local edit  = self.edit and self.edit.id == id and self.edit or nil
    local changed, committed = false, false

    -- The caret nearest to the pointer, among the lines as shown.
    local function caret_at(lines, top)
        local row  = math.floor((self.my - y - 3) / line_h) + 1 + top
        local line = lines[math.max(1, math.min(#lines, row))]
        local best, best_d = line[1] - 1, math.huge
        for caret = line[1] - 1, line[2] do
            local d = math.abs(self:text_width(edit.text:sub(line[1], caret), size) - (self.mx - x - theme.pad))
            if d < best_d then best, best_d = caret, d end
        end
        return best
    end

    if not edit and self:_takes_focus(id, hover) then
        self.edit = { id = id, text = text, caret = #text, original = text, top = 0 }
        edit = self.edit
        self.input = {}
        if hover then edit.caret = caret_at(self:_wrap(text, inner, size), 0) end
    elseif edit and self.pressed[1] and hover then
        edit.caret = caret_at(self:_wrap(edit.text, inner, size), edit.top)
    elseif edit and self.pressed[1] then
        committed = true
    end

    if edit then
        local limit = opts.max or 1000
        local function insert(piece)
            piece      = piece:sub(1, math.max(0, limit - #edit.text))
            edit.text  = edit.text:sub(1, edit.caret) .. piece .. edit.text:sub(edit.caret + 1)
            edit.caret = edit.caret + #piece
        end
        -- Up or down a line, staying as near to the caret's column as the line allows.
        local function step(dir)
            local lines = self:_wrap(edit.text, inner, size)
            local at    = caret_line(lines, edit.caret)
            local line  = lines[at + dir]
            if not line then return end
            local column = self:text_width(edit.text:sub(lines[at][1], edit.caret), size)
            local best, best_d = line[1] - 1, math.huge
            for caret = line[1] - 1, line[2] do
                local d = math.abs(self:text_width(edit.text:sub(line[1], caret), size) - column)
                if d < best_d then best, best_d = caret, d end
            end
            edit.caret = best
        end
        for _, event in ipairs(self.input) do
            local key = event.key
            for ch in (event.text or ""):gmatch(".") do
                if ch:byte() >= 32 and ch:byte() < 127 then insert(ch) end
            end
            if key == "backspace" and edit.caret > 0 then
                edit.text  = edit.text:sub(1, edit.caret - 1) .. edit.text:sub(edit.caret + 1)
                edit.caret = edit.caret - 1
            elseif key == "delete" then
                edit.text = edit.text:sub(1, edit.caret) .. edit.text:sub(edit.caret + 2)
            elseif key == "left" then edit.caret = math.max(0, edit.caret - 1)
            elseif key == "right" then edit.caret = math.min(#edit.text, edit.caret + 1)
            elseif key == "up" then step(-1)
            elseif key == "down" then step(1)
            elseif key == "home" or key == "end" then
                local lines = self:_wrap(edit.text, inner, size)
                local line  = lines[caret_line(lines, edit.caret)]
                edit.caret  = key == "home" and line[1] - 1 or line[2]
            elseif key == "return" or key == "kpenter" then insert("\n")
            elseif key == "v" and love.keyboard.isDown("lctrl", "rctrl") then
                insert(((love.system.getClipboardText() or ""):gsub("\r\n", "\n"):gsub("[^\n\32-\126]", " ")))
            elseif key == "tab" then
                committed = true
            elseif key == "escape" then
                edit.text = edit.original
                committed = true
            end
        end
        self.input = {}
        changed = committed and edit.text ~= edit.original
        if committed then
            text      = edit.text
            self.edit = nil
        end
    end

    self:rect(x, y, w, h, theme.field, 3)
    self:frame(x, y, w, h, (edit and not committed) and theme.accent or (hover and theme.widget_down or theme.border), 3)
    local shown = (edit and not committed) and edit.text or text
    self:clip(x + 2, y + 2, w - 4, h - 4)
    if shown == "" and opts.hint and not edit then
        self:print(opts.hint, x + theme.pad, y + 3, { color = theme.text_dim, size = size })
    else
        local lines = self:_wrap(shown, inner, size)
        local rows  = math.max(1, math.floor((h - 6) / line_h))
        local top   = 0
        local at    = edit and not committed and caret_line(lines, edit.caret) or nil
        if at then
            -- Keep the caret's line in view.
            top      = math.max(at - rows, math.min(edit.top, at - 1))
            top      = math.max(0, math.min(top, #lines - rows))
            edit.top = top
        end
        for i = top + 1, math.min(#lines, top + rows + 1) do
            local line = lines[i]
            self:print(shown:sub(line[1], line[2]), x + theme.pad, y + 3 + (i - top - 1) * line_h,
                { color = opts.color, size = size })
        end
        if at and (self.time % (CARET_BLINK * 2)) < CARET_BLINK then
            local cx = self:text_width(shown:sub(lines[at][1], edit.caret), size)
            self:rect(x + theme.pad + cx, y + 3 + (at - top - 1) * line_h, 1, line_h - 2, theme.accent)
        end
    end
    self:unclip()
    return text, changed, committed
end

-- A number with step buttons; the value can be typed. opts: min, max, step,
-- big (Shift step), suffix. Returns the value and whether it changed.
function Kit:number(id, x, y, w, value, opts)
    opts = opts or {}
    local theme = self.theme
    local h     = theme.row
    local step  = opts.step or 1
    if love.keyboard.isDown("lshift", "rshift") then step = opts.big or step * 10 end
    local bw   = 18
    local new  = value
    if self:button(id .. "#dec", x, y, bw, h, { icon = "minus", disabled = opts.disabled }) then new = value - step end
    if self:button(id .. "#inc", x + w - bw, y, bw, h, { icon = "plus", disabled = opts.disabled }) then
        new = value + step
    end
    local shown = tostring(value) .. (opts.suffix or "")
    if self.edit and self.edit.id == id then shown = nil end
    local text, _, committed = self:field(id, x + bw + 2, y, w - bw * 2 - 4, shown or tostring(value),
        { commit = true, max = 12, filter = "[%d%.%-]" })
    if committed then new = tonumber(text) or value end
    if opts.integer ~= false then new = math.floor(new + 0.5) end
    if opts.min then new = math.max(opts.min, new) end
    if opts.max then new = math.min(opts.max, new) end
    return new, new ~= value
end

-- popups

function Kit:open_popup(id, x, y, w, h, draw)
    local sw, sh = self:size()
    if x + w > sw - 2 then x = math.max(2, sw - w - 2) end
    if y + h > sh - 2 then y = math.max(2, sh - h - 2) end
    local below = self.popups[#self.popups]
    local layer = math.max(self.layer, below and below.layer or 0) + 1
    self.popups[#self.popups + 1] = { id = id, x = x, y = y, w = w, h = h, draw = draw, layer = layer, fresh = true }
end

function Kit:popup_open(id)
    for _, popup in ipairs(self.popups) do
        if popup.id == id then return true end
    end
    return false
end

function Kit:close_popups()
    self.popups = {}
end

function Kit:_draw_popup(popup)
    local theme = self.theme
    self:region(popup.x, popup.y, popup.w, popup.h)
    self:rect(popup.x + 2, popup.y + 3, popup.w, popup.h, theme.shade, 3)
    self:rect(popup.x, popup.y, popup.w, popup.h, theme.panel_head, 3)
    self:frame(popup.x, popup.y, popup.w, popup.h, theme.border, 3)
    popup.draw(self, popup)
end

-- A value picked from a drop-down list. choices: { { label, value, icon }, ... }.
-- Returns the value and whether it changed.
function Kit:choice(id, x, y, w, choices, value, opts)
    opts = opts or {}
    local theme = self.theme
    local h     = theme.row
    local current
    for _, c in ipairs(choices) do
        if c.value == value then current = c end
    end
    local picked = self.results[id]
    if picked ~= nil then
        self.results[id] = nil
        if picked.value ~= value then return picked.value, true end
    end
    local open = self:popup_open(id)
    local clicked, hover = false, false
    if not opts.disabled then clicked, hover = self:click(id, x, y, w, h) end
    if hover then self:set_tip(id, opts.tip) end
    self:rect(x, y, w, h, (hover or open) and theme.widget_hot or theme.widget, 3)
    local label_x = x
    if current and current.icon then
        self:icon(current.icon, x + theme.pad, y + (h - theme.icon) / 2, theme.icon)
        label_x = x + theme.icon + theme.gap
    end
    self:label(current and current.label or (opts.empty or "-"), label_x, y, x + w - label_x - 16, h,
        { pad = theme.pad, color = opts.disabled and theme.text_dim or theme.text })
    self:icon("chevron_down", x + w - 18, y + (h - 16) / 2, 16, theme.text_dim)
    if clicked and not open then
        local rows   = math.min(#choices, opts.rows or 12)
        local list_h = rows * theme.row + 4
        self:open_popup(id, x, y + h + 1, math.max(w, opts.list_w or 0), list_h, function(kit, popup)
            local offset = kit:scroll_begin(id .. "#list", popup.x, popup.y + 2, popup.w, popup.h - 4, #choices * theme.row)
            for i, c in ipairs(choices) do
                local ry = popup.y + 2 + (i - 1) * theme.row - offset
                if kit:button(id .. "#" .. i, popup.x + 2, ry, popup.w - 4, theme.row,
                    { text = c.label, icon = c.icon, flat = true, align = "left", on = c.value == value }) then
                    kit.results[id] = { value = c.value }
                    kit:close_popups()
                end
            end
            kit:scroll_end()
        end)
    end
    return value, false
end

-- A row of exclusive tabs. tabs: { { label, value, icon, tip, badge }, ... }.
function Kit:tabs(id, x, y, w, tabs, value)
    local theme = self.theme
    local h     = theme.row + 4
    local tw    = w / #tabs
    self:rect(x, y, w, h, theme.panel_head)
    for i, tab in ipairs(tabs) do
        local tx = x + (i - 1) * tw
        local on = tab.value == value
        local clicked, hover = self:click(id .. "#" .. i, tx, y, tw, h)
        if hover then self:set_tip(id .. "#" .. i, tab.tip) end
        if on then
            self:rect(tx, y, tw, h, theme.panel)
            self:rect(tx, y, tw, 2, theme.accent)
        elseif hover then
            self:rect(tx, y, tw, h, theme.widget_hot)
        end
        local color = on and theme.accent or (hover and theme.text or theme.text_dim)
        if tab.icon and not tab.label then
            self:icon(tab.icon, tx + (tw - theme.icon) / 2, y + (h - theme.icon) / 2, theme.icon, color)
        else
            self:label(tab.label, tx, y + 1, tw, h, { align = "center", color = color, size = theme.font_small })
        end
        if tab.badge then
            local bw = self:text_width(tab.badge, theme.font_small) + 8
            self:rect(tx + tw - bw - 3, y + 4, bw, h - 9, tab.badge_color or theme.danger, 6)
            self:label(tab.badge, tx + tw - bw - 3, y + 4, bw, h - 9,
                { align = "center", size = theme.font_small, color = theme.text_dark })
        end
        if clicked then value = tab.value end
    end
    return value
end

-- A menu: a flat button that opens a list of actions. items: { { label, key,
-- icon, action, disabled, on }, ... }; an item without a label is a separator.
function Kit:menu(id, x, y, w, h, opts, items)
    local open = self:popup_open(id)
    opts.flat  = true
    opts.on    = open
    if self:button(id, x, y, w, h, opts) and not open then
        self:close_popups()
        self:open_menu(id, x, y + h, items)
    end
end

function Kit:open_menu(id, x, y, items)
    local theme = self.theme
    local width, height = 120, 6
    for _, item in ipairs(items) do
        if item.label then
            local w = self:text_width(item.label) + theme.icon + theme.pad * 4
            if item.key then w = w + self:text_width(item.key, theme.font_small) + theme.pad * 3 end
            width  = math.max(width, w)
            height = height + theme.row
        else
            height = height + 7
        end
    end
    self:open_popup(id, x, y, width, height, function(kit, popup)
        local ry = popup.y + 3
        for i, item in ipairs(items) do
            if item.label then
                local clicked = kit:button(id .. "#" .. i, popup.x + 2, ry, popup.w - 4, theme.row,
                    { text = item.label, icon = item.icon or (item.on and "check") or "blank", flat = true,
                      align = "left", disabled = item.disabled, danger = item.danger })
                if item.key then
                    kit:label(item.key, popup.x, ry, popup.w, theme.row,
                        { align = "right", pad = theme.pad + 2, size = theme.font_small, color = theme.text_dim })
                end
                if clicked then
                    kit:close_popups()
                    if item.action then item.action() end
                end
                ry = ry + theme.row
            else
                kit:separator(popup.x + 4, ry + 3, popup.w - 8)
                ry = ry + 7
            end
        end
    end)
end

-- dialog

-- Ask for the dialog this frame: a titled box in the middle of the window,
-- drawn above everything by finish(). draw(kit, x, y, w, h) fills its body.
function Kit:dialog(title, w, h, draw)
    self.modal = { title = title, w = w, h = h, draw = draw }
end

function Kit:_draw_modal(modal)
    local theme  = self.theme
    local sw, sh = self:size()
    self:region(0, 0, sw, sh)
    self:rect(0, 0, sw, sh, theme.shade)
    local w = math.min(modal.w, sw - 16)
    local h = math.min(modal.h, sh - 16)
    local x = math.floor((sw - w) / 2)
    local y = math.floor((sh - h) / 2)
    self:rect(x + 3, y + 4, w, h, theme.shade, 4)
    self:rect(x, y, w, h, theme.panel, 4)
    self:frame(x, y, w, h, theme.border, 4)
    self:rect(x + 1, y + 1, w - 2, theme.row + 4, theme.panel_head, 3)
    self:label(modal.title, x, y + 1, w, theme.row + 4, { pad = theme.pad + 2, color = theme.accent, size = theme.font_title })
    modal.draw(self, x + theme.pad + 2, y + theme.row + 5 + theme.pad, w - (theme.pad + 2) * 2, h - theme.row - 5 - theme.pad * 2)
end

return Kit
