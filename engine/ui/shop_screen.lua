-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local json    = require "lib.json"
local Font    = require "engine.core.font"
local Pointer = require "engine.ui.pointer"
local Layout  = require "engine.ui.layout"
local Loadout = require "engine.game.loadout"

-- Weapon shop, after the original's POWUP (chopper) / POWUPT (tank) screens:
-- the backdrop bakes the "COST:" panel and one labelled row of three level
-- icons per weapon category. Clicking an icon selects it: the panel shows its
-- description and trade-in cost, and PURCHASE (greyed when the level is owned
-- or unaffordable) buys it. The owned level wears LOADED, lower levels are
-- darkened and cannot be selected, and any higher level can be bought directly.
-- The medal purse is drawn bottom-left as digits plus a large medal per ten
-- and a small one per single medal. DONE closes the screen; CHOP / TANK flips
-- the shopped vehicle.
--
-- Layout (design-space pixels measured from the original) is data/shop.json;
-- prices and descriptions come from Loadout.info.
local ShopScreen = Class()

local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local LAYOUT_PATH  = "data/shop.json"
local CONFIRM_TIME = 0.3

-- POWGADS frame per button state.
local BUTTON_FRAMES = {
    purchase = { normal = 0,  disabled = 1, pressed = 2 },
    done     = { normal = 4,  disabled = 5, pressed = 6 },
    chop     = { normal = 8,  disabled = 9 },
    tank     = { normal = 10, disabled = 11 },
}

local LOADED_IMG  = "assets/pow/powarmed_f00.png"
local FOCUS_IMG   = "assets/pow/powfocus_f00.png"
local DARKEN_IMG  = "assets/pow/powfocus_f03.png"
local MEDAL_LARGE = "assets/pow/powmedal_f00.png"
local MEDAL_SMALL = "assets/pow/powmedal_f01.png"

local NAV_STEP = {
    left  = { 0, -1 },
    right = { 0, 1 },
    up    = { -1, 0 },
    down  = { 1, 0 },
}

local function img(path)
    if not love.filesystem.getInfo(path) then return nil end
    local ok, i = pcall(love.graphics.newImage, path)
    if ok then
        i:setFilter("nearest", "nearest")
        return i
    end
    return nil
end

function ShopScreen:init()
    self.active = false
    self._cache = {}
    self.font   = Font.get("charspow")
    local raw   = love.filesystem.read(LAYOUT_PATH)
    self.layout = json.decode(raw)
end

function ShopScreen:is_active() return self.active end
function ShopScreen:close() self.active = false end

function ShopScreen:_img(path)
    if self._cache[path] == nil then
        self._cache[path] = img(path) or false
    end
    return self._cache[path] or nil
end

function ShopScreen:_gads(frame)
    return self:_img(string.format("assets/pow/powgads_f%02d.png", frame))
end

function ShopScreen:_digit(d)
    return self:_img(string.format("assets/pow/pownums_f%02d.png", d))
end

-- loadout: the run's Loadout (its medals are the purse); weapons: combat.weapons
-- (unused, kept for parity with the equip screen); opts.lock_vehicle pins the
-- screen to the current vehicle (a forced-vehicle phase hides the toggle).
function ShopScreen:open(loadout, weapons, opts)
    opts            = opts or {}
    self.loadout    = loadout
    self.weapons    = weapons or {}
    self.lock       = opts.lock_vehicle or false
    self.vehicle    = loadout.vehicle
    self.pressed    = nil
    self.confirming = nil
    self.confirm_t  = 0
    self:_build()
    self.active = true
    return true
end

-- Zones for the current vehicle: one per level box (also indexed by grid row /
-- column for keyboard navigation), PURCHASE, DONE and, unless locked, the
-- vehicle toggle. Selects the first selectable box.
function ShopScreen:_build()
    local L = self.layout
    self.backdrop = self:_img(L.backdrop[self.vehicle])

    self.zones, self.grid = {}, {}
    for _, cat in ipairs(L.categories[self.vehicle]) do
        local xs     = L.columns[cat.column]
        local offset = (cat.column == "right") and #L.columns.left or 0
        self.grid[cat.row] = self.grid[cat.row] or {}
        for level = 1, #xs do
            local z = {
                kind = "box", weapon = cat.weapon, level = level,
                row = cat.row, col = offset + level,
                x = xs[level], y = L.rows[cat.row], w = L.box.w, h = L.box.h,
            }
            self.zones[#self.zones + 1] = z
            self.grid[z.row][z.col] = z
        end
    end
    self.grid_cols = #L.columns.left + #L.columns.right

    self:_add_button("purchase", L.purchase, self:_gads(BUTTON_FRAMES.purchase.normal))
    self:_add_button("done", L.done, self:_gads(BUTTON_FRAMES.done.normal))
    if not self.lock then
        self:_add_button("toggle", L.toggle, self:_gads(self:_toggle_frames().normal))
    end

    self.selected = nil
    for _, z in ipairs(self.zones) do
        if z.kind == "box" and self:selectable(z.weapon, z.level) then
            self.selected = z
            break
        end
    end
end

function ShopScreen:_add_button(id, pos, image)
    if not image then return end
    self.zones[#self.zones + 1] = {
        kind = "button", id = id,
        x = pos[1], y = pos[2], w = image:getWidth(), h = image:getHeight(),
    }
end

-- The toggle names the vehicle it switches to.
function ShopScreen:_toggle_frames()
    return (self.vehicle == "chopper") and BUTTON_FRAMES.tank or BUTTON_FRAMES.chop
end

function ShopScreen:_level(weapon) return self.loadout:level(self.vehicle, weapon) end

-- "loaded" for the owned level, "below" for the darkened levels under it,
-- "available" for the levels above.
function ShopScreen:box_state(weapon, level)
    local owned = self:_level(weapon)
    if level == owned then return "loaded" end
    if level < owned then return "below" end
    return "available"
end

function ShopScreen:selectable(weapon, level)
    return self:box_state(weapon, level) ~= "below"
end

-- Medal cost of the selected level now (0 when it is owned).
function ShopScreen:cost()
    local z = self.selected
    if not z then return 0 end
    return self.loadout:price(self.vehicle, z.weapon, z.level) or 0
end

function ShopScreen:can_purchase()
    local z = self.selected
    if not z then return false end
    local price = self.loadout:price(self.vehicle, z.weapon, z.level)
    return price ~= nil and price <= self.loadout.medals
end

function ShopScreen:_enabled(id)
    if id == "purchase" then return self:can_purchase() end
    return true
end

function ShopScreen:_zone_at(dx, dy)
    for _, z in ipairs(self.zones) do
        if dx >= z.x and dx < z.x + z.w and dy >= z.y and dy < z.y + z.h then
            return z
        end
    end
    return nil
end

function ShopScreen:_purchase()
    local z = self.selected
    if z and self:can_purchase() then
        self.loadout:buy(self.vehicle, z.weapon, z.level)
    end
end

function ShopScreen:_toggle_vehicle()
    if self.lock then return end
    self.vehicle = (self.vehicle == "chopper") and "tank" or "chopper"
    self.loadout.vehicle = self.vehicle
    self:_build()
end

function ShopScreen:_activate(id)
    if id == "purchase" then
        self:_purchase()
    elseif id == "toggle" then
        self:_toggle_vehicle()
    else
        self.confirming = id
        self.confirm_t  = 0
    end
end

-- Moves the selection one grid step, skipping gaps and darkened levels.
function ShopScreen:_navigate(key)
    local step = NAV_STEP[key]
    local z    = self.selected
    if not step or not z then return end
    local row, col = z.row, z.col
    local rows = #self.layout.rows
    while true do
        row, col = row + step[1], col + step[2]
        if row < 1 or row > rows or col < 1 or col > self.grid_cols then return end
        local target = self.grid[row] and self.grid[row][col]
        if target and self:selectable(target.weapon, target.level) then
            self.selected = target
            return
        end
    end
end

-- Mouse/touch, window coords. A box selects on press; buttons show their
-- pressed frame while held and fire on release over the same button.
function ShopScreen:press(x, y)
    if not self.active or self.confirming then return end
    local z = self:_zone_at(Pointer.to_design(x, y, DW, DH))
    if not z then return end
    if z.kind == "box" then
        if self:selectable(z.weapon, z.level) then self.selected = z end
    elseif self:_enabled(z.id) then
        self.pressed = z
    end
end

function ShopScreen:release(x, y)
    if not self.active or self.confirming then return end
    local z   = self:_zone_at(Pointer.to_design(x, y, DW, DH))
    local was = self.pressed
    self.pressed = nil
    if was and z == was and self:_enabled(z.id) then
        self:_activate(z.id)
    end
end

function ShopScreen:keypressed(key)
    if not self.active or self.confirming then return end
    if key == "return" or key == "kpenter" or key == "space" then
        self:_purchase()
    elseif key == "escape" then
        self:_activate("done")
    elseif key == "tab" then
        self:_toggle_vehicle()
    else
        self:_navigate(key)
    end
end

function ShopScreen:update(dt)
    if not self.confirming then return end
    self.confirm_t = self.confirm_t + dt
    if self.confirm_t >= CONFIRM_TIME then
        local id = self.confirming
        self.confirming = nil
        if self.on_select then self.on_select(id) end
    end
end

function ShopScreen:fade()
    if self.confirming then
        return math.max(0, 1 - self.confirm_t / CONFIRM_TIME)
    end
    return 1
end

-- True while button id is held down or its confirm fade is playing.
function ShopScreen:_pressed(id)
    if self.confirming == id then return true end
    return self.pressed ~= nil and self.pressed.id == id
end

function ShopScreen:_draw_at(g, image, x, y, offset)
    if not image then return end
    g.draw(image, x + (offset and offset[1] or 0), y + (offset and offset[2] or 0))
end

function ShopScreen:_draw_box(g, z)
    local L     = self.layout
    local state = self:box_state(z.weapon, z.level)
    if state == "loaded" then
        self:_draw_at(g, self:_img(LOADED_IMG), z.x, z.y, L.loaded_offset)
    elseif state == "below" then
        self:_draw_at(g, self:_img(DARKEN_IMG), z.x, z.y, L.darken_offset)
    end
    if z == self.selected then
        self:_draw_at(g, self:_img(FOCUS_IMG), z.x, z.y, L.focus_offset)
    end
end

function ShopScreen:_draw_button(g, z)
    local frames = (z.id == "toggle") and self:_toggle_frames() or BUTTON_FRAMES[z.id]
    local frame  = frames.normal
    if not self:_enabled(z.id) then
        frame = frames.disabled
    elseif frames.pressed and self:_pressed(z.id) then
        frame = frames.pressed
    end
    self:_draw_at(g, self:_gads(frame), z.x, z.y)
end

-- Zero-padded to spec.digits (more when the value needs them), in POWNUMS.
function ShopScreen:_draw_number(g, value, spec)
    local text = string.format("%0" .. spec.digits .. "d", value)
    for i = 1, #text do
        local image = self:_digit(tonumber(text:sub(i, i)))
        self:_draw_at(g, image, spec.x + (i - 1) * spec.pitch, spec.y)
    end
end

function ShopScreen:_draw_medals(g)
    local spec   = self.layout.medals
    local medals = self.loadout.medals
    local large  = self:_img(MEDAL_LARGE)
    local small  = self:_img(MEDAL_SMALL)
    local x      = spec.x
    for _ = 1, math.floor(medals / spec.per_large) do
        self:_draw_at(g, large, x, spec.y)
        x = x + spec.large_pitch
    end
    for _ = 1, medals % spec.per_large do
        self:_draw_at(g, small, x, spec.y)
        x = x + spec.small_pitch
    end
end

function ShopScreen:_draw_description(fade)
    local z = self.selected
    local entry = z and Loadout.info(self.vehicle, z.weapon, z.level)
    if not entry then return end
    local spec = self.layout.description
    for i, line in ipairs(entry.lines) do
        self.font:print(line, spec.x, spec.y + (i - 1) * spec.line_pitch,
            { cell = spec.cell, color = { 1, 1, 1, fade } })
    end
end

function ShopScreen:draw()
    if not self.active then return end
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local scale, ox, oy      = Layout.fit(screen_w, screen_h)
    local fade               = self:fade()

    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)
    g.setColor(1, 1, 1, fade)
    self:_draw_at(g, self.backdrop, 0, 0)

    for _, z in ipairs(self.zones) do
        if z.kind == "box" then self:_draw_box(g, z) else self:_draw_button(g, z) end
    end
    self:_draw_number(g, self:cost(), self.layout.cost)
    self:_draw_number(g, self.loadout.medals, self.layout.count)
    self:_draw_medals(g)
    self:_draw_description(fade)

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return ShopScreen
