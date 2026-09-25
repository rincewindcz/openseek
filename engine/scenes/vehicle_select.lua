-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local Scene     = require "engine.core.scene"
local Font      = require "engine.core.font"
local Animation = require "engine.core.animation"
local Audio     = require "engine.core.audio"
local Config    = require "engine.core.config"
local Log       = require "engine.core.log"
local Layout    = require "engine.ui.layout"
local Pointer   = require "engine.ui.pointer"
local Hint      = require "engine.ui.hint"
local PlayerTag = require "engine.ui.player_tag"
local Vehicles  = require "engine.game.vehicles"
local Mission   = require "engine.game.mission"
local Campaign  = require "engine.game.campaign"
local Player    = require "engine.game.player"

-- Vehicle select screen, dressed in the original's unused VSELECT art (its
-- bevelled preview boxes, camo strips and OK / EXIT plates). Each player gets a
-- CHOPPER and a TANK card: a turntable preview of the variant in the preview
-- box, and the variant name over the camo strip that matches it.
--
-- enter() takes { players = 1 | 2, free = bool, return_to = <scene> }:
--   * campaign (NEW GAME): each player picks a chopper and a tank variant; the
--     equip screen still picks the vehicle per phase. START begins the run.
--   * free (overview F7, two players): the focused card is the vehicle the
--     player drives, and G / F toggle god mode and friendly fire. START drops
--     into split-screen co-op on the current stage.
-- Two players drive their own card column with their own keys (P1 W/S/A/D, P2
-- arrows); a single player uses either set. Enter starts, Esc goes back.
local VehicleSelect = Class(Scene)

VehicleSelect.ui_pointer = true

local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

-- VSELECT pieces, in its 320x240 space: the preview box of each camo row, a
-- clean stretch of each row's camo strip (clear of its OK plate, screws and
-- the EXIT plate), and the OK / EXIT plates reused as START / EXIT.
local VSELECT    = "assets/fullscreen/VSELECT.png"
local BOX_ROWS   = { { 0, 0, 61, 60 }, { 0, 60, 61, 60 }, { 0, 120, 61, 60 }, { 0, 180, 61, 60 } }
local CAMO_ROWS  = { { 106, 11, 194, 52 }, { 106, 71, 194, 51 }, { 106, 131, 194, 54 }, { 106, 192, 160, 42 } }
local OK_PLATE   = { 77, 49, 29, 14 }
local EXIT_PLATE = { 273, 222, 34, 15 }

local COLUMNS = {
    [1] = { { x = 42, w = 236 } },
    [2] = { { x = 4, w = 152 }, { x = 164, w = 152 } },
}
local TITLE_Y   = 6
local HEADER_Y  = 29
local CARD_Y    = { chopper = 44, tank = 110 }
local CARD_H    = 60
local BOX_W     = 61
local BODY_PAD  = 4
local ARROW_W   = 12
local INFO_Y    = 178
local HINT_Y    = { 212, 224 }
local START_XY  = { x = 234, y = 223 }
local EXIT_XY   = { x = 273, y = 222 }
local FADE_IN   = 0.25

local TURN_SPEED          = 0.6   -- rad/s of the turntable
local TURRET_SWING        = 0.7   -- rad the turret sweeps either side of the hull
local ROTOR_FPS           = 50
local PITCH_NEUTRAL_FRAME = 8     -- choppit frame with no pitch (1-based)

local GOLD  = { 1, 0.8, 0.2 }
local KINDS = Vehicles.KINDS

-- Card keys per player; a lone player answers to both sets.
local KEYS = {
    { up = "w",  down = "s",    left = "a",    right = "d" },
    { up = "up", down = "down", left = "left", right = "right" },
}

function VehicleSelect:init(app)
    Scene.init(self, app)
    self.title_font = Font.get("mainmen")
    self.name_font  = Font.get("hichars")
    self.small_font = Font.get("endchars")
    self.hint_font  = Font.get("keysfont")

    local ok, bg = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then bg:setFilter("linear", "linear"); self.bg = bg end
    if love.filesystem.getInfo(VSELECT) then
        local art = love.graphics.newImage(VSELECT)
        art:setFilter("nearest", "nearest")
        local w, h = art:getDimensions()
        local function quads(rects)
            local out = {}
            for i, r in ipairs(rects) do out[i] = love.graphics.newQuad(r[1], r[2], r[3], r[4], w, h) end
            return out
        end
        self.art         = art
        self.box_quads   = quads(BOX_ROWS)
        self.camo_quads  = quads(CAMO_ROWS)
        self.plate_quads = quads({ OK_PLATE, EXIT_PLATE })
    else
        Log.warn("vselect", "missing %s", VSELECT)
    end
end

function VehicleSelect:enter(opts)
    opts = opts or {}
    local app = self.app
    self.players   = (opts.players == 2) and 2 or 1
    self.free      = opts.free or false
    self.return_to = opts.return_to or "new_game"
    self.t         = 0
    self.pressed   = nil
    self.hover     = nil
    self.forced    = self.free and Mission.required_vehicle(app.world.stage_name) or nil

    local coop = app.settings.coop
    self.sel = {}
    for i = 1, self.players do
        local chopper, tank, focus
        if self.players == 1 then
            chopper, tank, focus = Config.chopper_skin, Config.tank_skin, "chopper"
        else
            chopper, tank, focus = coop.chopper_skin[i], coop.tank_skin[i], coop.vehicle[i]
        end
        self.sel[i] = {
            chopper = Vehicles.clamp_skin("chopper", chopper),
            tank    = Vehicles.clamp_skin("tank", tank),
            focus   = self.forced or focus or "chopper",
        }
    end
end

-- selection

function VehicleSelect:_set_focus(i, kind)
    local sel = self.sel[i]
    if sel.focus == kind or (self.forced and kind ~= self.forced) then return end
    sel.focus = kind
    Audio.play_event("ui.move")
end

function VehicleSelect:_step(i, kind, dir)
    if self.forced and kind ~= self.forced then return end
    local sel = self.sel[i]
    sel.focus = kind
    sel[kind] = Vehicles.step_skin(kind, sel[kind], dir)
    Audio.play_event("ui.move")
end

function VehicleSelect:_back()
    Audio.play_event("ui.back")
    if self.free then
        self.app.scenes:switch(self.return_to)
    else
        self.app.scenes:replace(self.return_to)
    end
end

function VehicleSelect:_start()
    local app  = self.app
    local coop = app.settings.coop
    Audio.play_event("ui.confirm")
    if self.players == 1 then
        Config.chopper_skin = self.sel[1].chopper
        Config.tank_skin    = self.sel[1].tank
        Config.save()
    else
        for i, sel in ipairs(self.sel) do
            coop.chopper_skin[i] = sel.chopper
            coop.tank_skin[i]    = sel.tank
            coop.vehicle[i]      = sel.focus
        end
    end

    if self.free then
        -- Starting a co-op phase turns on the lives + game-over flow, exactly as
        -- the briefing's PLAY does for single player; god mode still opts out.
        app.campaign               = false
        app.settings.death_enabled = true
        app.scenes:switch("coop_gameplay")
        return
    end

    -- A fresh campaign run at the first stage: every phase and mission in order,
    -- one running score per player across the run.
    local first = app.world.stages[1]
    Campaign.start(app, self.players)
    coop.loadout = {}
    app.world:load(first)
    app.after_stage_load()
    app.scenes:switch("mission_briefing", first)
    app.screen:show_mission(tonumber(first:match("^stage(%d)")))
end

-- layout: every clickable card part, button and toggle in design space

function VehicleSelect:_card(i, kind)
    local col = COLUMNS[self.players][i]
    local y   = CARD_Y[kind]
    local bx  = col.x + BOX_W + 1
    local bw  = col.w - BOX_W - 1
    local by  = y + BODY_PAD
    local bh  = CARD_H - 2 * BODY_PAD
    return {
        player = i, kind = kind,
        x = col.x, y = y, w = col.w, h = CARD_H,
        body  = { x = bx, y = by, w = bw, h = bh },
        left  = { x = bx, y = by, w = ARROW_W, h = bh },
        right = { x = bx + bw - ARROW_W, y = by, w = ARROW_W, h = bh },
    }
end

function VehicleSelect:_info_text()
    if self.free then
        return string.format("G  GOD MODE %s      F  FRIENDLY FIRE %s",
            self.app.settings.coop.god and "ON" or "OFF", self.app.settings.coop.ff and "ON" or "OFF")
    elseif self.players == 2 then
        return "COOP LIVES: " .. (Config.coop_lives == "shared" and "SHARED POOL" or "SEPARATE")
            .. "  (SET IN OPTIONS)"
    end
    return nil
end

-- The G / F toggles share one centered info line; each half is one toggle.
function VehicleSelect:_toggle_zones()
    if not self.free then return {} end
    return {
        { id = "god", x = 0,             y = INFO_Y - 2, w = DESIGN_W / 2, h = 12 },
        { id = "ff",  x = DESIGN_W / 2,  y = INFO_Y - 2, w = DESIGN_W / 2, h = 12 },
    }
end

local function inside(r, x, y)
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- What sits under a design-space point: { kind = "arrow" | "card" | "button" |
-- "toggle", ... } or nil.
function VehicleSelect:_hit(x, y)
    if inside({ x = START_XY.x, y = START_XY.y, w = OK_PLATE[3], h = OK_PLATE[4] }, x, y) then
        return { kind = "button", id = "start" }
    end
    if inside({ x = EXIT_XY.x, y = EXIT_XY.y, w = EXIT_PLATE[3], h = EXIT_PLATE[4] }, x, y) then
        return { kind = "button", id = "exit" }
    end
    for _, z in ipairs(self:_toggle_zones()) do
        if inside(z, x, y) then return { kind = "toggle", id = z.id } end
    end
    for i = 1, self.players do
        for _, kind in ipairs(KINDS) do
            local c = self:_card(i, kind)
            if inside(c.left, x, y)  then return { kind = "arrow", player = i, card = kind, dir = -1 } end
            if inside(c.right, x, y) then return { kind = "arrow", player = i, card = kind, dir = 1 } end
            if inside(c, x, y)       then return { kind = "card", player = i, card = kind } end
        end
    end
    return nil
end

local function same_hit(a, b)
    return a and b and a.kind == b.kind and a.id == b.id and a.player == b.player
        and a.card == b.card and a.dir == b.dir
end

function VehicleSelect:_activate(hit)
    if hit.kind == "button" then
        if hit.id == "start" then self:_start() else self:_back() end
    elseif hit.kind == "toggle" then
        self:_toggle(hit.id)
    elseif hit.kind == "arrow" then
        self:_step(hit.player, hit.card, hit.dir)
    elseif hit.kind == "card" then
        self:_set_focus(hit.player, hit.card)
    end
end

function VehicleSelect:_toggle(id)
    local coop = self.app.settings.coop
    if id == "god" then coop.god = not coop.god else coop.ff = not coop.ff end
    Audio.play_event("ui.move")
end

-- input

function VehicleSelect:keypressed(key)
    if key == "escape" then self:_back(); return end
    if key == "return" or key == "kpenter" or key == "space" then self:_start(); return end
    if self.free and (key == "g" or key == "f") then self:_toggle(key == "g" and "god" or "ff"); return end
    for k, keys in ipairs(KEYS) do
        local i = (self.players == 1) and 1 or k
        local sel = self.sel[i]
        if key == keys.up or key == keys.down then
            self:_set_focus(i, (sel.focus == "chopper") and "tank" or "chopper")
            return
        elseif key == keys.left or key == keys.right then
            self:_step(i, sel.focus, key == keys.left and -1 or 1)
            return
        end
    end
end

function VehicleSelect:mousemoved(x, y)
    local hit = self:_hit(Pointer.to_design(x, y, DESIGN_W, DESIGN_H))
    self.hover = hit
    -- In free play the focused card is the vehicle, so only a click moves it.
    if not self.free and hit and (hit.kind == "card" or hit.kind == "arrow") then
        self:_set_focus(hit.player, hit.card)
    end
end

function VehicleSelect:mousepressed(x, y)
    self.pressed = self:_hit(Pointer.to_design(x, y, DESIGN_W, DESIGN_H))
end

function VehicleSelect:mousereleased(x, y)
    local hit, was = self:_hit(Pointer.to_design(x, y, DESIGN_W, DESIGN_H)), self.pressed
    self.pressed = nil
    if same_hit(hit, was) then self:_activate(hit) end
end

function VehicleSelect:update(dt)
    self.t = self.t + dt
end

-- draw

local function shadow_print(font, text, x, y, color)
    font:print(text, x + 1, y + 1, { color = { 0, 0, 0, 0.8 * (color[4] or 1) } })
    font:print(text, x, y, { color = color })
end

-- The turntable preview, centered in a preview box: the chopper's level-flight
-- frame under its spinning rotor, or the tank variant with its turret sweeping.
function VehicleSelect:_draw_preview(kind, skin, cx, cy, alpha)
    local g = love.graphics
    local a = self.t * TURN_SPEED
    g.setColor(1, 1, 1, alpha)
    if kind == "tank" then
        Player.draw_tank_variant(g, Vehicles.variant("tank", skin), cx, cy, 1, a,
            a + math.sin(self.t * 0.9) * TURRET_SWING, { frame = math.floor(self.t * 8) % 3 + 1 })
        return
    end
    local body = Animation.clip("choppit" .. skin)
    local img  = body and (body.frames[PITCH_NEUTRAL_FRAME] or body.frames[1])
    if img then
        local w, h = img:getDimensions()
        g.draw(img, cx, cy, a, 1, 1, w / 2, h / 2)
    end
    local rotor = Animation.clip("bladep")
    if rotor and not rotor:is_empty() then
        local groups = math.max(1, math.floor(rotor:frame_count() / 8))
        local group  = math.floor((groups - 1) * 0.5 + 0.5)
        local idx    = group * 8 + math.floor(self.t * ROTOR_FPS) % 8
        local r      = rotor.frames[(idx % rotor:frame_count()) + 1]
        local def    = self.app.vehicle_defs.chopper or {}
        local oy     = (def.rotor_y_offset or 0) / (def.sprite_scale or 3)
        local rw, rh = r:getDimensions()
        g.draw(r, cx - math.sin(a) * oy, cy + math.cos(a) * oy, a, 1, 1, rw / 2, rh / 2)
    end
end

function VehicleSelect:_draw_arrow(r, dir, alpha)
    local g  = love.graphics
    local cx = r.x + r.w / 2
    local cy = r.y + r.h / 2
    local bob = (math.sin(self.t * 5) > 0) and 1 or 0
    cx = cx + dir * bob
    g.setColor(0, 0, 0, 0.8 * alpha)
    g.polygon("fill", cx - 3 * dir + 1, cy - 5 + 1, cx - 3 * dir + 1, cy + 5 + 1, cx + 3 * dir + 1, cy + 1)
    g.setColor(GOLD[1], GOLD[2], GOLD[3], alpha)
    g.polygon("fill", cx - 3 * dir, cy - 5, cx - 3 * dir, cy + 5, cx + 3 * dir, cy)
end

function VehicleSelect:_draw_card(c, fade, scale, ox, oy)
    local g       = love.graphics
    local sel     = self.sel[c.player]
    local skin    = sel[c.kind]
    local v       = Vehicles.variant(c.kind, skin)
    local row     = math.max(1, math.min(#CAMO_ROWS, v.camo or 1))
    local tint    = v.camo_tint or { 1, 1, 1 }
    local focused = sel.focus == c.kind
    local locked  = self.forced and self.forced ~= c.kind
    -- In free play only the focused card is the vehicle being picked.
    local active  = not locked and (focused or not self.free)
    local shade   = active and 1 or 0.45
    local b       = c.body

    if self.art then
        local q = CAMO_ROWS[row]
        g.setColor(tint[1] * shade, tint[2] * shade, tint[3] * shade, fade)
        g.draw(self.art, self.camo_quads[row], b.x, b.y, 0, b.w / q[3], b.h / q[4])
        g.draw(self.art, self.box_quads[row], c.x, c.y)
    else
        g.setColor(0.2 * shade, 0.2 * shade, 0.2 * shade, fade)
        g.rectangle("fill", b.x, b.y, b.w, b.h)
        g.setColor(0, 0, 0, fade)
        g.rectangle("fill", c.x + 3, c.y + 3, BOX_W - 6, CARD_H - 6)
    end
    g.setColor(0, 0, 0, 0.6 * fade)
    g.setLineWidth(1)
    g.rectangle("line", b.x + 0.5, b.y + 0.5, b.w - 1, b.h - 1)

    -- The preview is clipped to the box's black well.
    g.setScissor(math.floor(ox + (c.x + 3) * scale), math.floor(oy + (c.y + 3) * scale),
        math.ceil((BOX_W - 6) * scale), math.ceil((CARD_H - 6) * scale))
    self:_draw_preview(c.kind, skin, c.x + BOX_W / 2, c.y + CARD_H / 2, fade * (active and 1 or 0.5))
    g.setScissor()

    local white = { 1, 1, 1, (active and 0.85 or 0.5) * fade }
    shadow_print(self.hint_font, (c.kind == "tank") and "TANK" or "CHOPPER", b.x + ARROW_W + 2, b.y + 4, white)
    if locked then
        shadow_print(self.hint_font, "LOCKED", b.x + b.w - ARROW_W - 2 - self.hint_font:width("LOCKED"),
            b.y + 4, white)
    elseif self.free and focused then
        local tag = "SELECTED"
        shadow_print(self.hint_font, tag, b.x + b.w - ARROW_W - 2 - self.hint_font:width(tag), b.y + 4,
            { GOLD[1], GOLD[2], GOLD[3], fade })
    end

    local font = self.name_font
    if font:width(v.name) > b.w - 2 * ARROW_W - 4 then font = self.small_font end
    local name_col = active and { GOLD[1], GOLD[2], GOLD[3], fade } or { 1, 1, 1, 0.5 * fade }
    shadow_print(font, v.name, math.floor(b.x + (b.w - font:width(v.name)) / 2), b.y + 18, name_col)

    -- One pip per variant, the current one lit.
    local n     = Vehicles.variant_count(c.kind)
    local pitch = 6
    local px    = math.floor(b.x + (b.w - (n * pitch - 2)) / 2)
    for k = 1, n do
        g.setColor(0, 0, 0, 0.8 * fade)
        g.rectangle("fill", px + (k - 1) * pitch, b.y + b.h - 9, 4, 4)
        if k == skin then g.setColor(GOLD[1], GOLD[2], GOLD[3], fade) else g.setColor(1, 1, 1, 0.35 * fade) end
        g.rectangle("fill", px + (k - 1) * pitch + 1, b.y + b.h - 8, 2, 2)
    end

    if focused and not locked then
        self:_draw_arrow(c.left, -1, fade)
        self:_draw_arrow(c.right, 1, fade)
        local pulse = 0.65 + 0.35 * math.sin(self.t * 4)
        g.setColor(GOLD[1], GOLD[2], GOLD[3], pulse * fade)
        g.rectangle("line", c.x - 1.5, c.y - 1.5, c.w + 3, c.h + 3)
    end
    g.setColor(1, 1, 1, 1)
end

function VehicleSelect:_draw_plate(which, xy, fade)
    if not self.art then return end
    local g    = love.graphics
    local id   = (which == 1) and "start" or "exit"
    local down = self.pressed and self.pressed.kind == "button" and self.pressed.id == id
    local lit  = self.hover and self.hover.kind == "button" and self.hover.id == id
    local k    = lit and 1 or 0.85
    g.setColor(k, k, k, fade)
    g.draw(self.art, self.plate_quads[which], xy.x + (down and 1 or 0), xy.y + (down and 1 or 0))
end

function VehicleSelect:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade               = math.min(1, self.t / FADE_IN)

    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    if self.bg then
        local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
        local bw, bh  = screen_w * breathe, screen_h * breathe
        g.setColor(0.45 * fade, 0.42 * fade, 0.32 * fade, 1)
        g.draw(self.bg, (screen_w - bw) / 2, (screen_h - bh) / 2, 0,
            bw / self.bg:getWidth(), bh / self.bg:getHeight())
    end

    local scale, ox, oy = Layout.fit(screen_w, screen_h)
    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    local title = "SELECT VEHICLE"
    self.title_font:print(title, math.floor((DESIGN_W - self.title_font:width(title)) / 2), TITLE_Y,
        { color = { 1, 1, 1, fade } })

    for i = 1, self.players do
        if self.players > 1 then
            PlayerTag.draw(i, COLUMNS[self.players][i].x, HEADER_Y, fade)
        end
        for _, kind in ipairs(KINDS) do
            self:_draw_card(self:_card(i, kind), fade, scale, ox, oy)
        end
    end

    local info = self:_info_text()
    if self.forced then
        info = "THIS PHASE IS " .. self.forced:upper() .. " ONLY"
            .. (info and ("   " .. info) or "")
    end
    if info then
        local lit = self.hover and self.hover.kind == "toggle"
        local col = lit and { GOLD[1], GOLD[2], GOLD[3], fade } or { 1, 1, 1, 0.8 * fade }
        shadow_print(self.hint_font, info, math.floor((DESIGN_W - self.hint_font:width(info)) / 2), INFO_Y, col)
    end

    local hints
    if self.players == 2 then
        hints = { "P1  {W S} CARD   {A D} VARIANT", "P2  {ARROWS}     {ENTER} START   {ESC} BACK" }
    else
        hints = { "{UP DOWN} CARD   {LEFT RIGHT} VARIANT", "{ENTER} START   {ESC} BACK" }
    end
    for k, h in ipairs(hints) do
        Hint.print(self.hint_font, h, 8, HINT_Y[k], { alpha = fade, shadow = true })
    end
    self:_draw_plate(1, START_XY, fade)
    self:_draw_plate(2, EXIT_XY, fade)

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return VehicleSelect
