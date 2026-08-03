local Class    = require "engine.core.class"
local Font     = require "engine.core.font"
local Layout   = require "engine.ui.layout"
local Pointer  = require "engine.ui.pointer"
local Audio    = require "engine.core.audio"

-- Main menu, styled after the original MAINP.BIN screen (NEW GAME / RESUME /
-- OPTIONS / CREDITS / HIGH SCORES / LOAD / SAVE / ORDER INFO / EXIT over the
-- MAINP backdrop, with a triangular cursor next to the highlighted entry).
-- Purely presentational: confirming an entry plays a short flash/fade-out and
-- then calls self.on_select(id); the caller (main.lua) sets that callback and
-- decides what each id means.
--
-- Entry labels are drawn from the `mainmen` bitmap font: the original MAINMEN
-- word art sliced per letter and packed into a standard font atlas
-- (assets/fonts/mainmen.{png,json}, see tools/export_mainmen.py), truecolor
-- through the captured runtime menu palette so glyphs match the original screen
-- pixel for pixel. The selection arrow is the gold triangle cropped from
-- MAINMENU.BMP (assets/mainmen/arrow.png).
local Menu = Class()

-- Design canvas (the original screen is 320x240); every offset below is in
-- these coordinates, scaled to fit the window like Screen / EndStats. Only
-- the foreground (labels + arrow) uses this letterboxed space -- the
-- backdrop is stretched to fully cover the real window instead (see draw()).
local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

local ROW_X   = 60      -- label left edge
local ROW_Y0  = 38      -- first row top
local ROW_DY  = 20      -- row pitch
local DIM_ALPHA = 0.35  -- disabled-entry alpha

local ARROW_GAP = 8     -- gap between the arrow tip and the label
local ARROW_SPEED = 12  -- higher = snappier tween between rows

-- Highlight animation for the selected row: a single soft blink each time the
-- selection changes, plus the arrow slowly lunging toward the label.
local SEL_BLINK_TIME  = 0.14 -- length of the one-shot blink on selection change
local SEL_BLINK_DEPTH = 0.40 -- how far its alpha dips (0 = none, 1 = to black)
local LUNGE_SPEED = 2.2  -- rad/s of the arrow bob/zoom (slow, non-distracting)
local LUNGE_BOB   = 3    -- px the arrow slides toward the label at full lunge
local LUNGE_ZOOM  = 0.15 -- extra arrow scale at full lunge

-- Open fade-in and confirm fade-out (whole menu fades through black), and the
-- heavy fast flash on the confirmed row.
local OPEN_TIME    = 0.25
local CONFIRM_TIME = 0.30
local CONFIRM_FLASH = 100  -- rad/s of the confirmed row's fast on/off flash
local CONFIRM_FLASH_LOW = 0.0

local Menu_DEFAULT_ENTRIES = {
    { id = "new_game",   label = "NEW GAME" },
    { id = "resume",     label = "RESUME",     enabled = false },
    { id = "options",    label = "OPTIONS" },
    { id = "credits",    label = "CREDITS" },
    { id = "hiscores",   label = "HIGH SCORES" },
    { id = "load",       label = "LOAD",       enabled = false },
    { id = "mission",    label = "MISSION" },
    { id = "editor",     label = "EDITOR",     gap_after = 8 },
    { id = "exit",       label = "EXIT" },
}

function Menu:init(entries)
    -- Copy so each instance owns its entries (enabled/y are mutated in place)
    -- rather than sharing / clobbering the module-level defaults.
    self.entries = {}
    for i, e in ipairs(entries or Menu_DEFAULT_ENTRIES) do
        self.entries[i] = { id = e.id, label = e.label, enabled = e.enabled, gap_after = e.gap_after }
    end
    self.cursor  = 1
    self.t       = 0
    self.active  = false

    -- The original main-menu word art, packed per letter into a standard font
    -- atlas; every entry is composed from it (uppercase only).
    self.font = Font.get("mainmen")

    local y = ROW_Y0
    for _, e in ipairs(self.entries) do
        e.y = y
        e.w = self.font:width(e.label)   -- hit rect
        e.h = self.font.line_height
        e.mid_y = y + e.h / 2
        y = y + ROW_DY + (e.gap_after or 0)
    end
    self.arrow_y = self.entries[1] and self.entries[1].mid_y or ROW_Y0

    -- Bottom-right build tag, drawn in the in-game CHARS font (truecolor gold).
    self.version_font = Font.get("chars")
    self.version_text = "OPENSEEK 0.9"

    local ok, img = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then
        -- Linear (not nearest): the backdrop is continuously sub-pixel scaled by
        -- the breathing zoom, and nearest sampling makes the seams between source
        -- texels crawl/shimmer as the scale drifts. Only the backdrop needs this;
        -- the crisp pixel-art labels and arrow stay nearest.
        img:setFilter("linear", "linear")
        self.bg = img
    else
        print("menu: missing assets/fullscreen/MAINP.png")
        self.bg = nil
    end

    local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
    if aok then
        arrow:setFilter("nearest", "nearest")
        self.arrow = arrow
    else
        print("menu: missing assets/mainmen/arrow.png")
        self.arrow = nil
    end
end

function Menu:is_active() return self.active end

-- Opens on whatever entry is currently under the cursor, sliding onto the
-- nearest enabled one if it isn't selectable any more (e.g. RESUME just got
-- disabled because the game the menu was opened over no longer exists).
function Menu:open()
    self.active = true
    self.t = 0
    self.open_t = 0         -- drives the fade-in (see _fade())
    self.held = false       -- true while an info screen is up over the menu
    self.confirming = nil   -- pending confirmed id during the fade-out
    self.confirm_t = 0
    self.pressed = nil      -- entry armed by mouse/touch down, fires on release
    self.sel_blink_t = SEL_BLINK_TIME  -- start with no blink in progress
    if self.entries[self.cursor] and self.entries[self.cursor].enabled == false then
        self:_move(1, true)
    end
    local e = self.entries[self.cursor]
    self.arrow_y = e and e.mid_y or ROW_Y0  -- snap on open, tween on navigation
end

function Menu:close()
    self.active = false
end

-- Keeps the menu active but fully faded to black behind a fullscreen screen
-- launched from it, so the game underneath never shows through. Cleared by the
-- next open() when the screen is dismissed.
function Menu:hold()
    self.held = true
end

function Menu:set_enabled(id, enabled)
    for _, e in ipairs(self.entries) do
        if e.id == id then e.enabled = enabled end
    end
    if not self.active then return end
    if self.entries[self.cursor] and self.entries[self.cursor].enabled == false then
        self:_move(1, true)
    end
end

-- quiet: land on the entry without the navigation click, for the corrective
-- moves open() and set_enabled() make when the cursor sits on a disabled entry.
function Menu:_move(dir, quiet)
    local n = #self.entries
    local i = self.cursor
    for _ = 1, n do
        i = ((i - 1 + dir) % n) + 1
        if self.entries[i].enabled ~= false then
            if i ~= self.cursor then
                self.sel_blink_t = 0   -- one-shot blink
                if not quiet then Audio.play_event("ui.move") end
            end
            self.cursor = i
            return
        end
    end
end

-- Index of the enabled entry under a design-space point, or nil.
function Menu:_entry_at(dx, dy)
    for i, e in ipairs(self.entries) do
        if e.enabled ~= false and dx >= ROW_X and dx <= ROW_X + e.w
           and dy >= e.y and dy <= e.y + e.h then
            return i
        end
    end
    return nil
end

-- Mouse/touch, window coords. Hover moves focus (with the one-shot blink); press
-- arms an entry; release over the same entry confirms it (same fade-out path as
-- the keyboard). Ignored mid-confirm or while an info screen is held over us.
function Menu:hover(x, y)
    if not self.active or self.confirming or self.held then return end
    local i = self:_entry_at(Pointer.to_design(x, y, DESIGN_W, DESIGN_H))
    if i and i ~= self.cursor then
        self.sel_blink_t = 0
        self.cursor = i
        Audio.play_event("ui.move")
    end
end

function Menu:press(x, y)
    if not self.active or self.confirming or self.held then return end
    local i = self:_entry_at(Pointer.to_design(x, y, DESIGN_W, DESIGN_H))
    if i then
        if i ~= self.cursor then self.sel_blink_t = 0; self.cursor = i end
        self.pressed = i
    end
end

function Menu:release(x, y)
    if not self.active or self.confirming or self.held then return end
    local i   = self:_entry_at(Pointer.to_design(x, y, DESIGN_W, DESIGN_H))
    local was = self.pressed
    self.pressed = nil
    if was and i == was then
        local e = self.entries[was]
        if e and e.enabled ~= false then
            self.confirming = e.id
            self.confirm_t = 0
            Audio.play_event("ui.confirm")
        end
    end
end

-- Confirming an entry starts a short fade-out; the choice is delivered to
-- self.on_select(id) when it finishes (see update()), not returned here, so
-- the flash/fade plays before the caller acts. Input is ignored mid-confirm.
function Menu:keypressed(key)
    if not self.active or self.confirming then return end
    if key == "up" then
        self:_move(-1)
    elseif key == "down" then
        self:_move(1)
    elseif key == "return" or key == "space" or key == "kpenter" then
        local e = self.entries[self.cursor]
        if e and e.enabled ~= false then
            self.confirming = e.id
            self.confirm_t = 0
            Audio.play_event("ui.confirm")
        end
    end
end

function Menu:update(dt)
    if not self.active or self.held then return end
    self.t = self.t + dt
    if self.open_t < OPEN_TIME then self.open_t = self.open_t + dt end

    if self.confirming then
        self.confirm_t = self.confirm_t + dt
        if self.confirm_t >= CONFIRM_TIME then
            local id = self.confirming
            self.confirming = nil
            if self.on_select then self.on_select(id) end  -- may close/hold self
        end
        return  -- freeze the arrow tween while the choice resolves
    end

    if self.sel_blink_t < SEL_BLINK_TIME then self.sel_blink_t = self.sel_blink_t + dt end

    local e = self.entries[self.cursor]
    if e then
        -- Exponential ease toward the selected row instead of an instant jump.
        local k = 1 - math.exp(-ARROW_SPEED * dt)
        self.arrow_y = self.arrow_y + (e.mid_y - self.arrow_y) * k
    end
end

-- Whole-menu opacity: black while held, fades in on open, out on confirm.
function Menu:_fade()
    if self.held then return 0 end
    if self.confirming then
        return math.max(0, 1 - self.confirm_t / CONFIRM_TIME)
    end
    if self.open_t and self.open_t < OPEN_TIME then
        return self.open_t / OPEN_TIME
    end
    return 1
end

-- Original gold arrow sprite, right edge ARROW_GAP left of the label column,
-- tweened to self.arrow_y and lunging toward the label (bob + zoom) on the
-- shared highlight phase; scaled about its own center so the zoom stays put.
function Menu:_draw_arrow(g, alpha)
    if not self.arrow then return end
    local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
    local phase  = 0.5 + 0.5 * math.sin(self.t * LUNGE_SPEED)
    local s      = 1 + LUNGE_ZOOM * phase
    local cx     = ROW_X - ARROW_GAP - aw / 2 + LUNGE_BOB * phase
    g.setColor(1, 1, 1, alpha)
    g.draw(self.arrow, cx, self.arrow_y, 0, s, s, aw / 2, ah / 2)
end

-- Alpha for the highlighted row: a heavy fast on/off flash while confirming,
-- otherwise a single soft blink that decays after each selection change.
function Menu:_highlight_alpha()
    if self.confirming then
        return (math.sin(self.confirm_t * CONFIRM_FLASH) > 0) and 1 or CONFIRM_FLASH_LOW
    end
    if self.sel_blink_t and self.sel_blink_t < SEL_BLINK_TIME then
        return 1 - SEL_BLINK_DEPTH * math.sin(self.sel_blink_t / SEL_BLINK_TIME * math.pi)
    end
    return 1
end

function Menu:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade               = self:_fade()

    -- Backdrop: always stretched to fully cover the window (no letterbox bars),
    -- plus a slow breathing zoom that only ever zooms in so it can never expose
    -- an edge. Fades with the menu (open/confirm) through black.
    if self.bg then
        local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
        local bw, bh  = screen_w * breathe, screen_h * breathe
        g.setColor(fade, fade, fade, 1)
        g.draw(self.bg, (screen_w - bw) / 2, (screen_h - bh) / 2, 0,
            bw / self.bg:getWidth(), bh / self.bg:getHeight())
    else
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", 0, 0, screen_w, screen_h)
    end

    -- Foreground (labels + cursor) stays in the fixed 320x240 design space so
    -- proportions don't skew with the window's aspect ratio.
    local scale, offset_x, offset_y = Layout.fit(screen_w, screen_h)
    g.push()
    g.translate(offset_x, offset_y)
    g.scale(scale, scale)

    local hl = self:_highlight_alpha()
    for i, e in ipairs(self.entries) do
        local selected = (i == self.cursor)
        local a = (e.enabled == false) and DIM_ALPHA or (selected and hl or 1)
        self.font:print(e.label, ROW_X, e.y, { color = { 1, 1, 1, a * fade } })
        if selected then
            self:_draw_arrow(g, hl * fade)
        end
    end

    g.pop()

    -- Build tag, bottom-right. Drawn in raw window pixels (outside the design
    -- scale) so it stays a small crisp 8px tag instead of being blown up with
    -- the menu. CHARS is truecolor (no alpha tint), so only show it once the
    -- menu is fully up rather than leaving gold text over the fade-to-black.
    if fade >= 1 then
        local vw = self.version_font:width(self.version_text)
        self.version_font:print(self.version_text, screen_w - vw - 4, screen_h - self.version_font.line_height - 3)
    end

    g.setColor(1, 1, 1, 1)
end

return Menu
