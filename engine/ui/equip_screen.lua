-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local json    = require "lib.json"
local Pointer = require "engine.ui.pointer"
local Layout  = require "engine.ui.layout"

-- Vehicle equip screen, styled after the original's EQUIP CHOPPER / EQUIP
-- TANK screens: the re-rendered backdrop with every weapon-bay row overdrawn
-- in its live state (darkened = not owned or not implemented, gold-selected =
-- loaded in that bay, normal = owned), the level pips beside each row, the
-- SPECIAL WEAPONS bank (one loadable at a time), and the OK / EXIT and
-- TANK / CHOP buttons. Bay 1 always carries the chain gun; its baked row is
-- left untouched and only its pips are drawn.
--
-- All art and widget positions come from assets/equip/ (tools/export_equip.py,
-- layout.json). Clicking a row loads that bay; OK / EXIT confirm through the
-- shared fade and call self.on_select(id); the TANK / CHOP button flips the
-- edited vehicle in place. The caller passes the campaign Loadout and the
-- combat weapon table (a weapon without a def is not implemented yet and
-- shows permanently darkened).
local EquipScreen = Class()

local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local PIP_PITCH    = 5     -- pip box pitch (4 px box + 1 px shadow)
local PIP_SLOTS    = 3
local FOCUS_COLOR  = { 1, 0.85, 0.2 }
local CONFIRM_TIME = 0.3   -- fade-through-black before OK / EXIT fires
local KNOB_W       = 3     -- slider knob (EQPTNKF f3) width

local LAYOUT_PATH = "assets/equip/layout.json"

local function img(path)
    if not love.filesystem.getInfo(path) then return nil end
    local ok, i = pcall(love.graphics.newImage, path)
    if ok then
        i:setFilter("nearest", "nearest")
        return i
    end
    return nil
end

-- True when the equip art is exported; callers skip the screen without it.
function EquipScreen.available()
    return love.filesystem.getInfo(LAYOUT_PATH) ~= nil
end

function EquipScreen:init()
    self.active = false
    local raw   = love.filesystem.read(LAYOUT_PATH)
    self.layout = raw and json.decode(raw) or nil
    self._cache = {}
end

function EquipScreen:is_active() return self.active end
function EquipScreen:close() self.active = false end

function EquipScreen:_img(path)
    if self._cache[path] == nil then
        self._cache[path] = img(path) or false
    end
    return self._cache[path] or nil
end

-- loadout: the campaign Loadout; weapons: combat.weapons (implemented check);
-- opts.lock_vehicle pins the screen to loadout.vehicle (tank-only phases show
-- no switch button, like the original).
function EquipScreen:open(loadout, weapons, opts)
    if not self.layout then return false end
    opts            = opts or {}
    self.loadout    = loadout
    self.weapons    = weapons or {}
    self.lock       = opts.lock_vehicle or false
    self.vehicle    = loadout.vehicle
    self.focus      = nil
    self.pressed    = nil
    self.dragging   = nil
    self.confirming = nil
    self.confirm_t  = 0
    self:_build()
    self.active = true
    return true
end

-- Clickable zones for the current vehicle, from the exported layout.
function EquipScreen:_build()
    self.dragging = nil
    local L = self.layout[self.vehicle]
    self.screen_layout = L
    -- Backdrop is the correctly-decoded full-screen art (assets/fullscreen/); the
    -- widget overlays in assets/equip/ draw on top of its baked GUI.
    self.backdrop = self:_img("assets/fullscreen/" .. L.backdrop)
    self.pip_lit   = self:_img("assets/equip/pip_lit.png")
    self.pip_empty = self:_img("assets/equip/pip_empty.png")
    self.knob      = self:_img("assets/equip/slider_knob.png")
    self.track     = self:_img("assets/equip/slider_track.png")

    self.zones = {}
    for bi, bay in ipairs(L.bays) do
        for _, row in ipairs(bay.rows or {}) do
            local sprite = self:_row_img(row.weapon, "normal")
            if sprite then
                self.zones[#self.zones + 1] = {
                    kind = "row", bay = bi, weapon = row.weapon, row = row,
                    x = row.x, y = row.y,
                    w = sprite:getWidth(), h = sprite:getHeight(),
                }
            end
        end
    end
    for _, sp in ipairs(L.specials) do
        local sprite = self:_row_img(sp.weapon, "normal")
        if sprite then
            self.zones[#self.zones + 1] = {
                kind = "special", weapon = sp.weapon, row = sp,
                x = sp.x, y = sp.y,
                w = sprite:getWidth(), h = sprite:getHeight(),
            }
        end
    end
    for _, id in ipairs({ "ok", "exit", "switch" }) do
        local b = L.buttons[id]
        if b and not (id == "switch" and self.lock) then
            local sprite = self:_img("assets/equip/" .. self.vehicle .. "_btn_" .. id .. "_up.png")
            if sprite then
                self.zones[#self.zones + 1] = {
                    kind = "button", id = id,
                    x = b.x, y = b.y,
                    w = sprite:getWidth(), h = sprite:getHeight(),
                }
            end
        end
    end
    for _, s in ipairs(L.characteristics or {}) do
        self.zones[#self.zones + 1] = {
            kind = "slider", char = s.char, readonly = s.readonly or false,
            x = s.x, y = s.y, w = s.w, h = s.h,
        }
    end
end

function EquipScreen:_row_img(weapon, state)
    return self:_img("assets/equip/" .. self.vehicle .. "_row_" .. weapon .. "_" .. state .. ".png")
end

-- Owned level; a weapon with no combat def is not implemented and reads 0.
function EquipScreen:_level(weapon)
    if not self.weapons[weapon] then return 0 end
    return self.loadout:level(self.vehicle, weapon)
end

-- Draw state of a bay row: darkened when not owned (or not implemented),
-- selected when loaded in that bay, normal otherwise.
function EquipScreen:row_state(bay_index, weapon)
    if self:_level(weapon) < 1 then return "dark" end
    if self.loadout.vehicles[self.vehicle].bays[bay_index] == weapon then
        return "sel"
    end
    return "normal"
end

-- All three specials are always selectable (only one loads at a time); one that
-- has no combat def yet (super napalm) still selects and simply does nothing in
-- game until implemented.
function EquipScreen:special_state(weapon)
    if self.loadout.vehicles[self.vehicle].special == weapon then return "sel" end
    return "normal"
end

-- Knob-travel x bounds (design px) for a slider track.
function EquipScreen:_slider_bounds(s)
    return s.x + 1, s.x + s.w - 1 - KNOB_W
end

-- Set a slider's characteristic from a design-space mouse x.
function EquipScreen:_set_slider(z, dx)
    local x_min, x_max = self:_slider_bounds(z)
    self.loadout:set_char(self.vehicle, z.char, (dx - x_min) / (x_max - x_min))
end

function EquipScreen:_zone_at(dx, dy)
    for _, z in ipairs(self.zones) do
        if dx >= z.x and dx < z.x + z.w and dy >= z.y and dy < z.y + z.h then
            return z
        end
    end
    return nil
end

function EquipScreen:_confirm(id)
    self.confirming = id
    self.confirm_t  = 0
end

function EquipScreen:_activate(z)
    if z.kind == "row" then
        if self:_level(z.weapon) >= 1 then
            self.loadout:set_bay(self.vehicle, z.bay, z.weapon)
        end
    elseif z.kind == "special" then
        self.loadout:set_special(self.vehicle, z.weapon)
    elseif z.kind == "button" then
        if z.id == "switch" then
            self.vehicle = (self.vehicle == "chopper") and "tank" or "chopper"
            self.loadout.vehicle = self.vehicle
            self:_build()
            self.focus = nil
            for _, nz in ipairs(self.zones) do
                if nz.kind == "button" and nz.id == "switch" then self.focus = nz break end
            end
        else
            self:_confirm(z.id)
        end
    end
end

-- Mouse/touch, window coords. Rows and specials load on press; the buttons
-- show their down frame while held and fire on release over the same button.
function EquipScreen:hover(x, y)
    if not self.active or self.confirming then return end
    local dx, dy = Pointer.to_design(x, y, DW, DH)
    if self.dragging then
        self:_set_slider(self.dragging, dx)
        return
    end
    self.focus = self:_zone_at(dx, dy)
end

function EquipScreen:press(x, y)
    if not self.active or self.confirming then return end
    local dx, dy = Pointer.to_design(x, y, DW, DH)
    local z = self:_zone_at(dx, dy)
    self.focus = z
    if not z then return end
    if z.kind == "button" then
        self.pressed = z
    elseif z.kind == "slider" then
        if not z.readonly then
            self.dragging = z
            self:_set_slider(z, dx)
        end
    else
        self:_activate(z)
    end
end

function EquipScreen:release(x, y)
    if not self.active or self.confirming then return end
    self.dragging = nil
    local z   = self:_zone_at(Pointer.to_design(x, y, DW, DH))
    local was = self.pressed
    self.pressed = nil
    if was and z == was then
        self:_activate(z)
    end
end

-- Move keyboard focus through the button menu (PLAY / TANK|CHOP / EXIT), top to
-- bottom, wrapping. The first press lands on the top or bottom button.
function EquipScreen:_focus_step(dir)
    local btns = {}
    for _, z in ipairs(self.zones) do
        if z.kind == "button" then btns[#btns + 1] = z end
    end
    if #btns == 0 then return end
    table.sort(btns, function(a, b) return a.y < b.y end)
    local idx
    for i, z in ipairs(btns) do
        if z == self.focus then idx = i break end
    end
    if not idx then
        self.focus = btns[dir > 0 and 1 or #btns]
        return
    end
    self.focus = btns[((idx - 1 + dir) % #btns) + 1]
end

function EquipScreen:keypressed(key)
    if not self.active or self.confirming then return end
    if key == "return" or key == "kpenter" then
        local z = self.focus
        if z and z.kind == "button" then
            self:_activate(z)
        else
            self:_confirm("ok")
        end
    elseif key == "escape" then
        self:_confirm("exit")
    elseif key == "up" or key == "left" then
        self:_focus_step(-1)
    elseif key == "down" or key == "right" or key == "tab" then
        self:_focus_step(1)
    end
end

function EquipScreen:update(dt)
    if not self.confirming then return end
    self.confirm_t = self.confirm_t + dt
    if self.confirm_t >= CONFIRM_TIME then
        local id = self.confirming
        self.confirming = nil
        if self.on_select then self.on_select(id) end
    end
end

function EquipScreen:_fade()
    if self.confirming then
        return math.max(0, 1 - self.confirm_t / CONFIRM_TIME)
    end
    return 1
end

function EquipScreen:_draw_pips(row, level)
    if not (row.pips_x and self.pip_lit and self.pip_empty) then return end
    local g = love.graphics
    for i = 1, PIP_SLOTS do
        local sprite = (i <= level) and self.pip_lit or self.pip_empty
        g.draw(sprite, row.pips_x + (i - 1) * PIP_PITCH, row.pips_y)
    end
end

function EquipScreen:draw()
    if not self.active then return end
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local scale, ox, oy      = Layout.fit(screen_w, screen_h)
    local fade               = self:_fade()
    local L                  = self.screen_layout

    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)
    g.setColor(1, 1, 1, fade)

    if self.backdrop then g.draw(self.backdrop, 0, 0) end

    -- The backdrop bakes every row/special in its normal state, so only the
    -- darkened (not owned) and gold-selected overlays are drawn on top.
    for bi, bay in ipairs(L.bays) do
        if bay.fixed then
            self:_draw_pips(bay, self:_level(bay.fixed))
        end
        for _, row in ipairs(bay.rows or {}) do
            local state = self:row_state(bi, row.weapon)
            if state ~= "normal" then
                local sprite = self:_row_img(row.weapon, state)
                if sprite then g.draw(sprite, row.x, row.y) end
            end
            self:_draw_pips(row, self:_level(row.weapon))
        end
    end

    for _, sp in ipairs(L.specials) do
        local state = self:special_state(sp.weapon)
        if state ~= "normal" then
            local sprite = self:_row_img(sp.weapon, state)
            if sprite then g.draw(sprite, sp.x, sp.y) end
        end
    end

    -- Characteristics sliders: the colored track (EQPTNKG f21) over the baked
    -- track and its captured knob, then the live knob at fuel/armor/speed.
    for _, s in ipairs(L.characteristics or {}) do
        local frac = self.loadout:char(self.vehicle, s.char)
        local cy   = s.y + s.h / 2
        if self.track then
            g.setColor(1, 1, 1, fade)
            g.draw(self.track, s.x, math.floor(cy - self.track:getHeight() / 2 + 0.5))
        end
        if self.knob then
            local x_min, x_max = self:_slider_bounds(s)
            g.setColor(1, 1, 1, fade)
            g.draw(self.knob, math.floor(x_min + frac * (x_max - x_min) + 0.5),
                              math.floor(cy - self.knob:getHeight() / 2 + 0.5))
        end
    end

    -- Buttons are baked into the backdrop in their idle state; only the pressed
    -- (down) frame is overdrawn, and the switch is plated over on a locked phase.
    for _, id in ipairs({ "ok", "exit", "switch" }) do
        local b = L.buttons[id]
        if b then
            local suffix = nil
            if id == "switch" and self.lock then
                local plate = self:_img("assets/equip/" .. self.vehicle .. "_btn_plate.png")
                if plate then g.draw(plate, b.x, b.y) end
            elseif (self.pressed and self.pressed.kind == "button" and self.pressed.id == id)
                or self.confirming == id then
                suffix = "_down.png"
            end
            if suffix then
                local sprite = self:_img("assets/equip/" .. self.vehicle .. "_btn_" .. id .. suffix)
                if sprite then g.draw(sprite, b.x, b.y) end
            end
        end
    end

    -- Focus outline around the hovered widget (the selected states carry their
    -- own art, so hover feedback is a thin ring).
    local z = self.focus
    if z then
        g.setColor(FOCUS_COLOR[1], FOCUS_COLOR[2], FOCUS_COLOR[3], fade)
        g.setLineWidth(1)
        g.rectangle("line", z.x - 1.5, z.y - 1.5, z.w + 3, z.h + 3)
    end

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return EquipScreen
