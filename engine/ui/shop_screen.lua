-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local json    = require "lib.json"
local Config  = require "engine.core.config"
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
--
-- EXTRA (shop_fx): the purse animates. Medals fly into place on open while the
-- count rolls up, the medals a selected level would cost pulse (the row dims
-- when it is unaffordable), a purchase shakes and shrinks the spent medals
-- away (a broken ten pops back in as singles), the count rolls down and LOADED
-- stamps onto the bought icon; a refused purchase shakes the purse. Levels the
-- purse cannot pay for are drawn greyed and darker, except the selected one,
-- whose COST then reads red. The focus frame slides to a new selection, the
-- box under the mouse gets a faint one, and LOADED dims while a higher level of
-- its weapon is selected. Timings are data/shop.json "fx".
local ShopScreen = Class()

local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local LAYOUT_PATH  = "data/shop.json"
local CONFIRM_TIME = 0.3

-- POWGADS frame per button state; ring is the gold rim the original draws over
-- a pressed button.
local BUTTON_FRAMES = {
    purchase = { normal = 0,  disabled = 1, ring = 3 },
    done     = { normal = 4,  disabled = 5, ring = 7 },
    chop     = { normal = 8,  disabled = 9 },
    tank     = { normal = 10, disabled = 11 },
}

local LOADED_IMG  = "assets/pow/powarmed_f00.png"
local FOCUS_IMG   = "assets/pow/powfocus_f00.png"
local MEDAL_LARGE = "assets/pow/powmedal_f00.png"
local MEDAL_SMALL = "assets/pow/powmedal_f01.png"

-- EXTRA (shop_fx): redraws the backdrop under an unaffordable level greyed and
-- darkened.
local UNAFFORDABLE_SRC = [[
uniform float desaturate;
uniform float brightness;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen)
{
    vec4 c  = Texel(tex, uv);
    float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    return vec4(mix(c.rgb, vec3(l), desaturate) * brightness, c.a) * color;
}
]]

local function clamp01(v) return math.max(0, math.min(1, v)) end

local function ease_out(p) return 1 - (1 - p) * (1 - p) end

-- Overshoots past 1 before settling, for things landing in place.
local function ease_out_back(p)
    local c = 1.70158
    return 1 + (c + 1) * (p - 1) ^ 3 + c * (p - 1) ^ 2
end

-- Number of leading purse medals two rows share (drawn unchanged by both).
local function common_prefix(a, b)
    local n = 0
    while n < #a and n < #b and a[n + 1].large == b[n + 1].large do n = n + 1 end
    return n
end

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
    self.active              = false
    self._cache              = {}
    self.font                = Font.get("charspow")
    self.unaffordable_shader = nil
    local raw                = love.filesystem.read(LAYOUT_PATH)
    self.layout              = json.decode(raw)
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
    opts             = opts or {}
    self.loadout     = loadout
    self.weapons     = weapons or {}
    self.lock        = opts.lock_vehicle or false
    self.vehicle     = loadout.vehicle
    self.pressed     = nil
    self.confirming  = nil
    self.confirm_t   = 0
    self.clock       = 0
    self.spend       = nil
    self.stamp       = nil
    self.deny_t0     = nil
    self.focus_t0    = 0
    self.count_shown = self:_fx() and 0 or loadout.medals
    self:_build()
    self.active = true
    return true
end

-- The fx timings when EXTRA (shop_fx) is on, else nil.
function ShopScreen:_fx()
    return Config.shop_fx and self.layout.fx or nil
end

-- Zones for the current vehicle: one per level box (also indexed by grid row /
-- column for keyboard navigation), PURCHASE, DONE and, unless locked, the
-- vehicle toggle. Selects the first selectable box.
function ShopScreen:_build()
    local L = self.layout
    self.backdrop = self:_img(L.backdrop[self.vehicle])

    self.zones, self.grid = {}, {}
    local bw, bh = 1, 1
    if self.backdrop then bw, bh = self.backdrop:getDimensions() end
    for _, cat in ipairs(L.categories[self.vehicle]) do
        local xs     = L.columns[cat.column]
        local offset = (cat.column == "right") and #L.columns.left or 0
        self.grid[cat.row] = self.grid[cat.row] or {}
        for level = 1, #xs do
            local z = {
                kind = "box", weapon = cat.weapon, level = level,
                row = cat.row, col = offset + level, darkened = cat.darkened[level],
                x = xs[level], y = L.rows[cat.row], w = L.box.w, h = L.box.h,
            }
            z.quad = love.graphics.newQuad(z.x + 1, z.y + 1, z.w - 2, z.h - 2, bw, bh)
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
    self.focus_zone = self.selected
    self.focus_from = nil
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

-- A level above the owned one whose price is more than the purse holds.
function ShopScreen:unaffordable(weapon, level)
    local price = self.loadout:price(self.vehicle, weapon, level)
    return price ~= nil and price > self.loadout.medals
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
    if not z then return end
    if not self:can_purchase() then
        if self.loadout:price(self.vehicle, z.weapon, z.level) then self.deny_t0 = self.clock end
        return
    end
    local before = self:_medal_tokens(self.loadout.medals)
    self.loadout:buy(self.vehicle, z.weapon, z.level)
    local keep = common_prefix(before, self:_medal_tokens(self.loadout.medals))
    self.spend = { t0 = self.clock, old = before, keep = keep }
    self.stamp = { zone = z, t0 = self.clock }
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
-- gold ring while held and fire on release over the same button.
function ShopScreen:press(x, y)
    if not self.active or self.confirming then return end
    local z = self:_zone_at(Pointer.to_design(x, y, DW, DH))
    if not z then return end
    if z.kind == "box" then
        if self:selectable(z.weapon, z.level) then self.selected = z end
    elseif self:_enabled(z.id) then
        self.pressed = z
    elseif z.id == "purchase" then
        self:_purchase()
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
    self.clock = self.clock + dt
    self:_roll_count(dt)
    self:_expire_fx()
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
        if not self:_draw_stamp(g, z) then
            local alpha = select(4, g.getColor())
            local tint  = self:_loaded_tint(z)
            g.setColor(tint, tint, tint, alpha)
            self:_draw_at(g, self:_img(LOADED_IMG), z.x, z.y, L.loaded_offset)
            g.setColor(1, 1, 1, alpha)
        end
    elseif state == "below" then
        local tile = string.format(L.darkened_tiles[self.vehicle], z.darkened)
        self:_draw_at(g, self:_img(tile), z.x, z.y)
    elseif z ~= self.selected and self:unaffordable(z.weapon, z.level) then
        self:_draw_unaffordable(g, z)
    end
end

-- EXTRA (shop_fx): LOADED dims while a higher level of its weapon is selected.
function ShopScreen:_loaded_tint(z)
    local fx  = self:_fx()
    local sel = self.selected
    if fx and sel and sel.weapon == z.weapon and sel.level > z.level then return fx.loaded_dim end
    return 1
end

-- Design-space top-left of the focus frame. EXTRA (shop_fx): a new selection
-- slides the frame over from where it was in slide_time; a rebuild (vehicle
-- switch) places it without sliding.
function ShopScreen:_focus_pos()
    local z = self.selected
    if z ~= self.focus_zone then
        if self.focus_zone then
            local x, y = self:_focus_pos_of(self.focus_zone)
            self.focus_from = { x = x, y = y }
        end
        self.focus_zone = z
        self.focus_t0   = self.clock
    end
    return self:_focus_pos_of(z)
end

function ShopScreen:_focus_pos_of(z)
    local fx   = self:_fx()
    local from = self.focus_from
    if not fx or not from or z ~= self.focus_zone then return z.x, z.y end
    local p = ease_out(clamp01((self.clock - self.focus_t0) / fx.slide_time))
    return from.x + (z.x - from.x) * p, from.y + (z.y - from.y) * p
end

-- EXTRA (shop_fx): the selectable box under the mouse, when it is not the
-- selected one; it gets a faint focus frame.
function ShopScreen:_hovered()
    if not self:_fx() or not Pointer.seen or Pointer.touch or self.confirming then return nil end
    local z = self:_zone_at(Pointer.design(DW, DH))
    if z and z.kind == "box" and z ~= self.selected and self:selectable(z.weapon, z.level) then
        return z
    end
    return nil
end

function ShopScreen:_draw_focus(g)
    local L     = self.layout
    local image = self:_img(FOCUS_IMG)
    local alpha = select(4, g.getColor())
    local hover = self:_hovered()
    if hover then
        g.setColor(1, 1, 1, alpha * L.fx.hover_alpha)
        self:_draw_at(g, image, hover.x, hover.y, L.focus_offset)
        g.setColor(1, 1, 1, alpha)
    end
    if self.selected then
        local x, y = self:_focus_pos()
        self:_draw_at(g, image, math.floor(x + 0.5), math.floor(y + 0.5), L.focus_offset)
    end
end

-- EXTRA (shop_fx): the icon of a level the purse cannot pay for, greyed and
-- darkened over the backdrop's own.
function ShopScreen:_draw_unaffordable(g, z)
    local fx = self:_fx()
    if not fx or not self.backdrop then return end
    self.unaffordable_shader = self.unaffordable_shader or g.newShader(UNAFFORDABLE_SRC)
    local shader = self.unaffordable_shader
    shader:send("desaturate", fx.unaffordable.desaturate)
    shader:send("brightness", fx.unaffordable.brightness)
    g.setShader(shader)
    g.draw(self.backdrop, z.quad, z.x + 1, z.y + 1)
    g.setShader()
end

-- EXTRA (shop_fx): LOADED dropping onto a just-bought icon from stamp_scale
-- over a fading white flash. Returns false when no stamp is playing on z.
function ShopScreen:_draw_stamp(g, z)
    local fx    = self:_fx()
    local stamp = self.stamp
    if not fx or not stamp or stamp.zone ~= z then return false end
    local age   = self.clock - stamp.t0
    local alpha = select(4, g.getColor())
    local flash = (1 - clamp01(age / fx.flash_time)) * fx.flash_alpha
    g.setBlendMode("add")
    g.setColor(flash, flash, flash, alpha)
    g.rectangle("fill", z.x + 1, z.y + 1, z.w - 2, z.h - 2)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, alpha)

    local image = self:_img(LOADED_IMG)
    if image then
        local offset = self.layout.loaded_offset
        local w, h   = image:getWidth(), image:getHeight()
        local scale  = 1 + (fx.stamp_scale - 1) * (1 - ease_out(clamp01(age / fx.stamp_time)))
        g.draw(image, z.x + offset[1] + w / 2, z.y + offset[2] + h / 2, 0, scale, scale, w / 2, h / 2)
    end
    return true
end

function ShopScreen:_draw_button(g, z)
    local frames = (z.id == "toggle") and self:_toggle_frames() or BUTTON_FRAMES[z.id]
    local frame  = self:_enabled(z.id) and frames.normal or frames.disabled
    self:_draw_at(g, self:_gads(frame), z.x, z.y)
    if frames.ring and self:_pressed(z.id) then
        self:_draw_at(g, self:_gads(frames.ring), z.x, z.y)
    end
end

-- Moves the shown medal count one medal per count_step toward the purse, faster
-- when the gap would take longer than count_max_time.
function ShopScreen:_roll_count(dt)
    local fx     = self:_fx()
    local target = self.loadout and self.loadout.medals or 0
    if not fx then
        self.count_shown = target
        return
    end
    local gap  = target - self.count_shown
    local rate = math.max(1 / fx.count_step, math.abs(gap) / fx.count_max_time)
    local step = rate * dt
    if math.abs(gap) <= step then
        self.count_shown = target
    else
        self.count_shown = self.count_shown + (gap > 0 and step or -step)
    end
end

-- Drops the purchase animations once they have played out.
function ShopScreen:_expire_fx()
    local fx = self:_fx()
    if not fx then return end
    if self.spend and self.clock - self.spend.t0 >= fx.vanish_time + fx.appear_time then
        self.spend = nil
    end
    if self.stamp and self.clock - self.stamp.t0 >= math.max(fx.stamp_time, fx.flash_time) then
        self.stamp = nil
    end
    if self.deny_t0 and self.clock - self.deny_t0 >= fx.deny_time then
        self.deny_t0 = nil
    end
end

-- Horizontal offset of the refused-purchase shake (0 when idle).
function ShopScreen:_deny_offset()
    local fx = self:_fx()
    if not fx or not self.deny_t0 then return 0 end
    local age   = self.clock - self.deny_t0
    local decay = 1 - clamp01(age / fx.deny_time)
    return math.floor(math.sin(age * fx.deny_hz * 2 * math.pi) * fx.deny_px * decay + 0.5)
end

-- Zero-padded to spec.digits (more when the value needs them), in POWNUMS.
function ShopScreen:_draw_number(g, value, spec, dx)
    local text = string.format("%0" .. spec.digits .. "d", value)
    for i = 1, #text do
        local image = self:_digit(tonumber(text:sub(i, i)))
        self:_draw_at(g, image, spec.x + (i - 1) * spec.pitch + (dx or 0), spec.y)
    end
end

-- The purse row for a medal count: a large medal per ten, then the singles.
function ShopScreen:_medal_tokens(medals)
    local spec   = self.layout.medals
    local tokens = {}
    local x      = spec.x
    for _ = 1, math.floor(medals / spec.per_large) do
        tokens[#tokens + 1] = { large = true, x = x }
        x = x + spec.large_pitch
    end
    for _ = 1, medals % spec.per_large do
        tokens[#tokens + 1] = { large = false, x = x }
        x = x + spec.small_pitch
    end
    return tokens
end

-- Draws one purse medal scaled about its centre; glow adds a white pulse.
function ShopScreen:_draw_token(g, token, dx, dy, scale, tint, glow)
    local image = self:_img(token.large and MEDAL_LARGE or MEDAL_SMALL)
    if not image or scale <= 0 then return end
    local w, h = image:getWidth(), image:getHeight()
    local x, y = token.x + w / 2 + dx, self.layout.medals.y + h / 2 + dy
    local alpha = select(4, g.getColor())
    g.setColor(tint, tint, tint, alpha)
    g.draw(image, x, y, 0, scale, scale, w / 2, h / 2)
    if glow and glow > 0 then
        g.setBlendMode("add")
        g.setColor(glow, glow, glow, alpha)
        g.draw(image, x, y, 0, scale, scale, w / 2, h / 2)
        g.setBlendMode("alpha")
    end
    g.setColor(1, 1, 1, alpha)
end

-- EXTRA (shop_fx): the preview of the selected level on the purse. Returns the
-- index from which medals would be spent (nil when there is no price) and the
-- row tint (dimmed when the price is out of reach).
function ShopScreen:_preview(tokens)
    local z     = self.selected
    local price = z and self.loadout:price(self.vehicle, z.weapon, z.level)
    if not price or price == 0 then return nil, 1 end
    if price > self.loadout.medals then return nil, self.layout.fx.dim end
    return common_prefix(tokens, self:_medal_tokens(self.loadout.medals - price)) + 1, 1
end

function ShopScreen:_draw_medals(g)
    local fx     = self:_fx()
    local tokens = self:_medal_tokens(self.loadout.medals)
    if not fx then
        for _, token in ipairs(tokens) do self:_draw_token(g, token, 0, 0, 1, 1) end
        return
    end

    local dx    = self:_deny_offset()
    local spend = self.spend
    if spend then
        local age = self.clock - spend.t0
        for i = spend.keep + 1, #spend.old do
            local p     = clamp01(age / fx.vanish_time)
            local shake = math.sin(age * fx.shake_hz * 2 * math.pi) * fx.shake_px
            self:_draw_token(g, spend.old[i], dx + shake, 0, 1 - ease_out(clamp01(p * 2 - 1)), 1)
        end
        for i, token in ipairs(tokens) do
            local scale = 1
            if i > spend.keep then
                scale = ease_out_back(clamp01((age - fx.vanish_time) / fx.appear_time))
            end
            self:_draw_token(g, token, dx, 0, scale, 1)
        end
        return
    end

    local first, tint = self:_preview(tokens)
    local glow = (0.5 - 0.5 * math.cos(self.clock * fx.pulse_hz * 2 * math.pi)) * fx.pulse_alpha
    for i, token in ipairs(tokens) do
        local p    = clamp01((self.clock - (i - 1) * fx.fly_stagger) / fx.fly_time)
        local land = 1 - ease_out_back(p)
        self:_draw_token(g, token, dx + fx.fly_from[1] * land, fx.fly_from[2] * land, 1, tint,
            (first and i >= first) and glow or nil)
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
    self:_draw_focus(g)
    local fx = self:_fx()
    if fx and self.selected and self:unaffordable(self.selected.weapon, self.selected.level) then
        local red = fx.cost_unaffordable   -- EXTRA (shop_fx)
        g.setColor(red[1], red[2], red[3], fade)
    end
    self:_draw_number(g, self:cost(), self.layout.cost)
    g.setColor(1, 1, 1, fade)
    self:_draw_number(g, math.floor(self.count_shown + 0.5), self.layout.count, self:_deny_offset())
    self:_draw_medals(g)
    self:_draw_description(fade)

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return ShopScreen
