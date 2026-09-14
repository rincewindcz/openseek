local Class   = require "engine.core.class"
local Font    = require "engine.core.font"
local Pointer = require "engine.ui.pointer"
local Layout  = require "engine.ui.layout"

-- Weapon shop, styled after the original's POWUP (chopper) / POWUPT (tank)
-- screens: the backdrop bakes the "COST:" bar and one labelled row per weapon
-- category, each with three level icons. The three icon boxes act as the level
-- buttons: an owned level wears a gold ring, an affordable level is left bright,
-- and a level costing more medals than the purse holds is dimmed. Any level can
-- be bought directly (no need to own the lower ones) for PRICES[level] medals.
--
-- The medal purse is drawn top-left and every purchase spends from it. A DONE
-- button (the POWGADS shop button) and a CHOP / TANK toggle close the screen /
-- flip the shopped vehicle. All positions are design-space (320x240) pixels
-- measured from the backdrops; the box grid is identical on both.
local ShopScreen = Class()

local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local BOX_W, BOX_H = 39, 39
local COL_L        = { 8, 53, 98 }    -- left category's three box x's
local COL_R        = { 181, 226, 271 }-- right category's three box x's
local ROW1, ROW2, ROW3 = 65, 119, 173 -- category row y's

-- Weapon categories per vehicle: the box column set (left / right) and the row
-- y, matching the labels baked into each backdrop. Order is the click / nav
-- order. air_strike has no combat def yet but is still purchasable.
local CATEGORIES = {
    chopper = {
        { weapon = "chaingun",      cols = COL_L, y = ROW1 },
        { weapon = "rockets",       cols = COL_L, y = ROW2 },
        { weapon = "air_to_ground", cols = COL_L, y = ROW3 },
        { weapon = "air_to_air",    cols = COL_R, y = ROW1 },
        { weapon = "napalm",        cols = COL_R, y = ROW2 },
        { weapon = "air_strike",    cols = COL_R, y = ROW3 },
    },
    tank = {
        { weapon = "chaingun",   cols = COL_L, y = ROW1 },
        { weapon = "napalm",     cols = COL_L, y = ROW2 },
        { weapon = "shells",     cols = COL_R, y = ROW1 },
        { weapon = "air_strike", cols = COL_R, y = ROW2 },
    },
}

local BACKDROP  = { chopper = "assets/fullscreen/POWUP.png", tank = "assets/fullscreen/POWUPT.png" }
local DONE_XY    = { x = 250, y = 223 }   -- DONE button (POWGADS), bottom-right
local TOGGLE_XY  = { x = 244, y = 6 }     -- CHOP / TANK toggle, top-right of the COST bar
local MEDAL_XY   = { x = 10,  y = 6 }     -- medal icon, top-left
local COST_XY    = { x = 48,  y = 39 }    -- cost value, right of the baked "COST:"

-- POWGADS button frames: [normal, disabled, gold-pressed] per button.
local DONE_UP, DONE_DOWN = "assets/pow/powgads_f04.png", "assets/pow/powgads_f06.png"

local OWNED_RING  = { 1, 0.82, 0.15 }
local FOCUS_RING  = { 1, 1, 1 }
local LOCK_ALPHA  = 0.6                    -- dark wash over a not-yet-buyable level
local CONFIRM_TIME = 0.3

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
end

function ShopScreen:is_active() return self.active end
function ShopScreen:close() self.active = false end

function ShopScreen:_img(path)
    if self._cache[path] == nil then
        self._cache[path] = img(path) or false
    end
    return self._cache[path] or nil
end

-- loadout: the shared Loadout (its medals are the purse); weapons: combat.weapons
-- (unused for gating, kept for parity with the equip screen); opts.lock_vehicle
-- pins the screen to the current vehicle (a forced-vehicle phase hides the toggle).
function ShopScreen:open(loadout, weapons, opts)
    opts            = opts or {}
    self.loadout    = loadout
    self.weapons    = weapons or {}
    self.lock       = opts.lock_vehicle or false
    self.vehicle    = loadout.vehicle
    self.focus      = nil
    self.pressed    = nil
    self.confirming = nil
    self.confirm_t  = 0
    self:_build()
    self.active = true
    return true
end

-- Clickable zones for the current vehicle: one per level box, the DONE button,
-- and (unless locked) the vehicle toggle.
function ShopScreen:_build()
    self.backdrop = self:_img(BACKDROP[self.vehicle])
    self.medal    = self:_img("assets/pow/powmedal_f00.png")

    self.zones = {}
    for _, cat in ipairs(CATEGORIES[self.vehicle]) do
        for level = 1, 3 do
            self.zones[#self.zones + 1] = {
                kind = "box", weapon = cat.weapon, level = level,
                x = cat.cols[level], y = cat.y, w = BOX_W, h = BOX_H,
            }
        end
    end
    local done = self:_img(DONE_UP)
    if done then
        self.zones[#self.zones + 1] = {
            kind = "button", id = "done",
            x = DONE_XY.x, y = DONE_XY.y, w = done:getWidth(), h = done:getHeight(),
        }
    end
    if not self.lock then
        local toggle = self:_toggle_img(false)
        if toggle then
            self.zones[#self.zones + 1] = {
                kind = "button", id = "toggle",
                x = TOGGLE_XY.x, y = TOGGLE_XY.y, w = toggle:getWidth(), h = toggle:getHeight(),
            }
        end
    end
end

-- The vehicle toggle shows the vehicle it switches TO (TANK while on the chopper,
-- CHOP while on the tank); pressed = its held-down frame.
function ShopScreen:_toggle_img(pressed)
    local to = (self.vehicle == "chopper") and "tank" or "chop"
    local frame = (to == "chop") and (pressed and "09" or "08") or (pressed and "11" or "10")
    return self:_img("assets/pow/powgads_f" .. frame .. ".png")
end

function ShopScreen:_level(weapon) return self.loadout:level(self.vehicle, weapon) end

-- Draw state of a level box: "owned" when bought, "buyable" when affordable
-- (any higher level can be bought directly), "locked" when it costs more medals
-- than the purse holds.
function ShopScreen:box_state(weapon, level)
    if level <= self:_level(weapon) then return "owned" end
    if self.loadout.PRICES[level] <= self.loadout.medals then return "buyable" end
    return "locked"
end

function ShopScreen:_zone_at(dx, dy)
    for _, z in ipairs(self.zones) do
        if dx >= z.x and dx < z.x + z.w and dy >= z.y and dy < z.y + z.h then
            return z
        end
    end
    return nil
end

function ShopScreen:_confirm(id)
    self.confirming = id
    self.confirm_t  = 0
end

function ShopScreen:_activate(z)
    if z.kind == "box" then
        self.loadout:buy(self.vehicle, z.weapon, z.level)
    elseif z.id == "toggle" then
        self.vehicle = (self.vehicle == "chopper") and "tank" or "chopper"
        self.loadout.vehicle = self.vehicle
        self:_build()
    else
        self:_confirm(z.id)
    end
end

-- Mouse/touch, window coords. Boxes buy on press; the buttons show their down
-- frame while held and fire on release over the same button.
function ShopScreen:hover(x, y)
    if not self.active or self.confirming then return end
    self.focus = self:_zone_at(Pointer.to_design(x, y, DW, DH))
end

function ShopScreen:press(x, y)
    if not self.active or self.confirming then return end
    local z = self:_zone_at(Pointer.to_design(x, y, DW, DH))
    self.focus = z
    if not z then return end
    if z.kind == "button" then
        self.pressed = z
    else
        self:_activate(z)
    end
end

function ShopScreen:release(x, y)
    if not self.active or self.confirming then return end
    local z   = self:_zone_at(Pointer.to_design(x, y, DW, DH))
    local was = self.pressed
    self.pressed = nil
    if was and z == was then
        self:_activate(z)
    end
end

function ShopScreen:keypressed(key)
    if not self.active or self.confirming then return end
    if key == "return" or key == "kpenter" or key == "escape" then
        self:_confirm("done")
    elseif (key == "left" or key == "right" or key == "tab") and not self.lock then
        self.vehicle = (self.vehicle == "chopper") and "tank" or "chopper"
        self.loadout.vehicle = self.vehicle
        self:_build()
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

function ShopScreen:_fade()
    if self.confirming then
        return math.max(0, 1 - self.confirm_t / CONFIRM_TIME)
    end
    return 1
end

-- Per-box overlay: a gold ring on owned levels, a dark wash on unaffordable
-- ones. A buyable box is left untouched so it reads as clickable.
function ShopScreen:_draw_box(g, z, fade)
    local state = self:box_state(z.weapon, z.level)
    if state == "owned" then
        g.setColor(OWNED_RING[1], OWNED_RING[2], OWNED_RING[3], fade)
        g.setLineWidth(2)
        g.rectangle("line", z.x + 1, z.y + 1, z.w - 2, z.h - 2)
    elseif state == "locked" then
        g.setColor(0, 0, 0, LOCK_ALPHA * fade)
        g.rectangle("fill", z.x, z.y, z.w, z.h)
    end
end

function ShopScreen:draw()
    if not self.active then return end
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local scale, ox, oy      = Layout.fit(screen_w, screen_h)
    local fade               = self:_fade()

    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)
    g.setColor(1, 1, 1, fade)
    if self.backdrop then g.draw(self.backdrop, 0, 0) end

    for _, z in ipairs(self.zones) do
        if z.kind == "box" then self:_draw_box(g, z, fade) end
    end

    -- Medal purse, top-left.
    if self.medal then
        g.setColor(1, 1, 1, fade)
        g.draw(self.medal, MEDAL_XY.x, MEDAL_XY.y)
    end
    self.font:print("x" .. self.loadout.medals,
        MEDAL_XY.x + (self.medal and self.medal:getWidth() or 8) + 3, MEDAL_XY.y + 5,
        { color = { 1, 1, 1, fade } })

    -- Cost of the focused box (unowned levels), in the baked "COST:" bar.
    local z = self.focus
    if z and z.kind == "box" and self:box_state(z.weapon, z.level) ~= "owned" then
        local price = self.loadout.PRICES[z.level]
        self.font:print(tostring(price), COST_XY.x, COST_XY.y, { color = { 1, 1, 1, fade } })
    end

    -- DONE button and the vehicle toggle.
    local done = self:_img(self:_pressed("done") and DONE_DOWN or DONE_UP)
    if done then g.setColor(1, 1, 1, fade); g.draw(done, DONE_XY.x, DONE_XY.y) end
    if not self.lock then
        local toggle = self:_toggle_img(self:_pressed("toggle"))
        if toggle then g.setColor(1, 1, 1, fade); g.draw(toggle, TOGGLE_XY.x, TOGGLE_XY.y) end
    end

    -- Focus ring around the hovered box or button.
    if z then
        local ring = (z.kind == "box") and OWNED_RING or FOCUS_RING
        g.setColor(ring[1], ring[2], ring[3], fade)
        g.setLineWidth(1)
        g.rectangle("line", z.x - 1.5, z.y - 1.5, z.w + 3, z.h + 3)
    end

    g.pop()
    g.setColor(1, 1, 1, 1)
end

-- True while button id is held down or its confirm fade is playing.
function ShopScreen:_pressed(id)
    if self.confirming == id then return true end
    return self.pressed ~= nil and self.pressed.id == id
end

return ShopScreen
