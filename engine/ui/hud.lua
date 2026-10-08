-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local json    = require "lib.json"
local Assets  = require "engine.core.assets"
local Config  = require "engine.core.config"
local Display = require "engine.core.display"
local Font    = require "engine.core.font"
local Log     = require "engine.core.log"

local Hud = Class()

local ANCHOR = {
    top_left      = function(_w, _h) return 0,   0   end,
    top_right     = function(w, _h)  return w,   0   end,
    top_center    = function(w, _h)  return w/2, 0   end,
    bottom_left   = function(_w, h)  return 0,   h   end,
    bottom_right  = function(w, h) return w,   h   end,
    bottom_center = function(w, h) return w/2, h   end,
    center        = function(w, h) return w/2, h/2 end,
}

local RADAR_ENEMY = {
    flak_turret        = true,
    tank               = true,
    enemy_helicopter   = true,
    truck              = true,
    soldier            = true,
    soldier_aggressive = true,
}
local RADAR_BUILDING = {
    structure = true,
    radar     = true,
}
-- Blip colors: the classic set for the see-through radar, and a brighter set
-- the EXTRA (radar_backdrop) blends toward as its dark backdrop fades in. The
-- player's base is black in the original, lifted toward a pale blue.
local RADAR_COLORS = {
    base      = { classic = { 0.0, 0.0, 0.0 },    bright = { 0.6, 0.8, 1.0 } },
    building  = { classic = { 0.33, 0.18, 0.07 }, bright = { 0.5, 0.32, 0.16 } },
    enemy     = { classic = { 1.0, 0.15, 0.15 },  bright = { 1.0, 0.2, 0.15 } },
    air       = { classic = { 1.0, 0.4, 0.8 },    bright = { 1.0, 0.45, 0.9 } },   -- enemy helicopters
    pickup    = { classic = { 1.0, 0.9, 0.1 },    bright = { 1.0, 0.95, 0.15 } },
    strike    = { classic = { 1.0, 0.55, 0.15 },  bright = { 1.0, 0.6, 0.2 } },    -- pending air strike
    objective = { classic = { 1.0, 1.0, 1.0 },    bright = { 1.0, 1.0, 1.0 } },
}

-- Flat-color redraw of a sprite's opaque pixels (the recolored radar ring).
local TINT_SRC = [[
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen)
{
    return vec4(color.rgb, Texel(tex, uv).a * color.a);
}
]]

-- Blink rate (on/off cycles per second) of a pickup blip about to expire, and
-- of a pending air strike's target.
local RADAR_PICKUP_BLINK = 8
local RADAR_STRIKE_BLINK = 2

-- Score count-up: exponential approach rate (per second) and the floor speed
-- (points per second) that keeps the last few digits from crawling.
local ROLL_RATE     = 9
local ROLL_MIN_RATE = 60

function Hud:init()
    self.player = nil
    self.world  = nil
    self.items  = {}
    self._cache = {}
    -- Rolling score readouts, one entry per player seen (weak keys: a player from
    -- a finished phase drops out on its own). Presentation only.
    self._score_roll = setmetatable({}, { __mode = "k" })
    self._radar_source = nil   -- world entity list the radar list was built from
    self._radar_list   = {}
    -- Radar auto zoom per player (weak keys, like the score roll): the toggle and
    -- its 0..1 animation progress. A new phase's players start zoomed out.
    self._radar_zoom = setmetatable({}, { __mode = "k" })
end

-- Flip a player's radar auto zoom (the original's Autozoom key). Presentation
-- only: the state lives here, never in the simulation or the input frame.
function Hud:toggle_radar_zoom(p)
    if not p then return end
    local zoom = self._radar_zoom[p]
    if not zoom then
        zoom = { on = false, t = 0 }
        self._radar_zoom[p] = zoom
    end
    zoom.on = not zoom.on
end

-- Animate the radar zoom and ease the score readouts toward their players' real
-- scores. Driven from love.update on frame time, not on simulation ticks: this
-- is presentation and must never feed back into the run.
function Hud:update(dt)
    self:_update_radar_zoom(dt)
    if not Config.score_count_up then return end
    for p, roll in pairs(self._score_roll) do
        local target = p.score or 0
        local diff   = target - roll.shown
        if diff < 1 then
            roll.shown = target   -- the last digit, or a reset: land at once
        else
            -- Exponential approach: a big jump moves fast at first and eases into
            -- the final digits, with a floor so the tail still arrives promptly.
            local step = math.max(diff * (1 - math.exp(-ROLL_RATE * dt)), ROLL_MIN_RATE * dt)
            roll.shown = math.min(target, roll.shown + step)
        end
    end
end

-- Move each player's radar zoom progress toward its toggle at a constant rate,
-- so a toggle mid-animation reverses smoothly from where it is.
function Hud:_update_radar_zoom(dt)
    local item = self._by_id and self._by_id.radar
    local step = dt / math.max(0.01, item and item.zoom_time or 0.3)
    for _, zoom in pairs(self._radar_zoom) do
        if zoom.on then
            zoom.t = math.min(1, zoom.t + step)
        else
            zoom.t = math.max(0, zoom.t - step)
        end
    end
end

-- The eased 0..1 radar zoom of the HUD's current player.
function Hud:_radar_zoom_amount()
    local zoom = self._radar_zoom[self.player]
    if not zoom then return 0 end
    local t = zoom.t
    return t * t * (3 - 2 * t)
end

-- The score to draw for a player: the rolling readout when the count-up is on,
-- the real score otherwise. Seeing a player for the first time starts its
-- readout at the current score, so a carried campaign total does not roll up
-- from zero when a phase opens.
function Hud:_score_readout(p)
    local score = p.score or 0
    if not Config.score_count_up then
        self._score_roll[p] = nil
        return score
    end
    local roll = self._score_roll[p]
    if not roll then
        roll = { shown = score }
        self._score_roll[p] = roll
    end
    return math.floor(roll.shown)
end

function Hud:load(path)
    local raw = love.filesystem.read(path)
    if not raw then error("hud: missing " .. path) end
    local def  = json.decode(raw)
    self.items = def.items or {}
    self._by_id = {}
    for _, item in ipairs(self.items) do
        if item.id then self._by_id[item.id] = item end
        self:_preload_item(item)
    end
end

-- An item's anchor and (design-space) offset, resolving relative_to so an item
-- can be pinned to another's position (e.g. the ammo count rides the weapon
-- sprite, moving with it when the weapon offset changes).
function Hud:_anchor_offset(item)
    local anchor = item.anchor or "top_left"
    local ox = item.offset and item.offset[1] or 0
    local oy = item.offset and item.offset[2] or 0
    local ref = item.relative_to and self._by_id and self._by_id[item.relative_to]
    if ref then
        anchor = ref.anchor or anchor
        ox = ox + (ref.offset and ref.offset[1] or 0)
        oy = oy + (ref.offset and ref.offset[2] or 0)
    end
    return anchor, ox, oy
end

-- Load an item's frames/background, optionally from a per-mission override dir
-- (prefix, e.g. "hud/stage3/"). An item draws entirely from one source: if the
-- override has it (frame 0 / the background exists) every frame comes from there,
-- otherwise the shared "hud/" set. Frames are counted until the first gap, so an
-- override with a different frame count (mission 3 weapons has 19 vs 14) works.
function Hud:_preload_item(item, prefix)
    local function over(path)
        if not prefix then return path end
        local o = path:gsub("^hud/", prefix)
        return Assets.exists(o) and o or path
    end

    if item.sprite_pattern then
        item._frames = {}
        local override = over(string.format(item.sprite_pattern, 0)) ~= string.format(item.sprite_pattern, 0)
        local i = 0
        while true do
            local p = string.format(item.sprite_pattern, i)
            if override then p = p:gsub("^hud/", prefix) end
            if not Assets.exists(p) then break end
            item._frames[i + 1] = self:_img(p)
            i = i + 1
        end
    end
    -- One marker sprite per player slot (the co-op P1..P4 labels). Shipped art,
    -- so no per-mission override pass over it.
    if item.icon_pattern then
        item._icons = {}
        local i = 0
        while true do
            local p = string.format(item.icon_pattern, i)
            if not Assets.exists(p) then break end
            item._icons[i + 1] = self:_img(p)
            i = i + 1
        end
    end
    if item.background then
        item._bg = self:_img(over(item.background))
    end
end

-- Switch HUD art to mission m's overrides (assets/hud/stage{m}/) where present,
-- per item, falling back to the shared set. Called on each stage load.
function Hud:set_mission(m)
    self.mission   = m
    local overkill = "overkill" .. tostring(m)
    self.overkill_font = love.filesystem.getInfo("assets/fonts/" .. overkill .. ".json")
        and overkill or "overkill0"
    local prefix = "hud/stage" .. tostring(m) .. "/"
    for _, item in ipairs(self.items) do
        self:_preload_item(item, prefix)
    end
end

-- An in-game text font in the active mission's cut: the original swaps CHARS
-- for the night mission's green one along with that mission's HUD art.
function Hud:font(name)
    return Font.for_mission(name or "chars", self.mission)
end

function Hud:_img(path)
    if self._cache[path] == nil then
        local full    = Assets.path(path)
        local ok, img = false, nil
        if love.filesystem.getInfo(full) then ok, img = pcall(love.graphics.newImage, full) end
        if ok then
            img:setFilter("nearest", "nearest")
            self._cache[path] = img
        else
            Log.warn("hud", "missing asset %s", path)
            self._cache[path] = false
        end
    end
    return self._cache[path] or nil
end

-- draw

function Hud:draw()
    if not self.player then return end
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    if self.view_w then screen_w, screen_h = self.view_w, self.view_h end
    -- The global HUD scale grows each element and its inset from the anchored edge
    -- together, so a corner-anchored item stays in its corner as it gets bigger.
    local hud_scale = (Config.hud_scale or 1) * Display.view_scale()
    for _, item in ipairs(self.items) do
        local anchor, offx, offy = self:_anchor_offset(item)
        local fn     = ANCHOR[anchor]
        local ax, ay = fn(screen_w, screen_h)
        local ox     = offx * hud_scale
        local oy     = offy * hud_scale
        local x, y   = ax + ox, ay + oy
        local s      = (item.scale or 1) * hud_scale
        local t      = item.type
        if     t == "gauge"  then self:_draw_gauge(g, item, x, y, s)
        elseif t == "weapon" then self:_draw_weapon(g, item, x, y, s)
        elseif t == "cursor" then self:_draw_cursor(g, item, x, y, s)
        elseif t == "radar"  then self:_draw_radar(g, item, x, y, s)
        elseif t == "number" then self:_draw_number(g, item, x, y, s)
        elseif t == "sight"  then self:_draw_sight(g, item, s)
        elseif t == "notice" then self:_draw_notice(item, x, y, s)
        end
    end
    self:_draw_overkill(g, screen_w, screen_h, hud_scale)
    g.setColor(1, 1, 1)
end

-- numbers (score / lives / pows / ammo)
-- A bitmap-font counter (CHARS body font, as the original HUD), optionally with a
-- marker sprite (icon) and/or a literal prefix string ("x" for the ammo count).
-- value -> player field; ammo reads the current weapon's count (nil = infinite,
-- hidden). hide_when_zero hides the whole item at 0 (POW count). align="right"
-- pins the readout's right edge to the anchor so corner counters never drift or
-- spill off-screen as the digit count changes.

function Hud:_number_value(item)
    local p = self.player
    local v = item.value
    if     v == "score" then return self:_score_readout(p)
    elseif v == "lives" then return p.lives or 0
    elseif v == "pows"  then return p.pows  or 0
    elseif v == "ammo"  then return p.ammo[p.weapon_name]   -- nil => infinite
    end
    return nil
end

-- The marker sprite left of the readout: a fixed icon, or one frame per player
-- slot from icon_pattern (the P1..P4 score labels), clamped to the last frame.
function Hud:_number_icon(item)
    if item._icons and #item._icons > 0 then
        local i = math.max(1, math.min(#item._icons, self.player.index or 1))
        return item._icons[i]
    end
    return item.icon and self:_img(item.icon)
end

function Hud:_draw_number(g, item, x, y, s)
    local val = self:_number_value(item)
    if val == nil then return end
    if item.hide_when_zero and val <= 0 then return end
    local digits = item.digits or 1
    local cap    = 10 ^ digits - 1
    local str    = string.format("%0" .. digits .. "d", math.max(0, math.min(val, cap)))
    if item.prefix then str = item.prefix .. str end

    local font  = self:font(item.font)
    local icon  = self:_number_icon(item)
    local iconw = icon and (icon:getWidth() * s + (item.gap or 2) * s) or 0
    local left  = x
    if item.align == "right" then left = x - iconw - font:width(str, s) end

    if icon then
        local iy = y + (item.icon_dy or 0) * s
        -- icon_color marks a mask sprite (white on alpha): tint it and cast the
        -- same down-right black shadow the mask fonts get. Sprites decoded from
        -- the original art carry their own palette and baked shadow. A mission
        -- whose HUD has its own palette names its tint in icon_color_mission.
        if item.icon_color then
            local own = item.icon_color_mission and item.icon_color_mission[tostring(self.mission)]
            g.setColor(0, 0, 0)
            g.draw(icon, left + s, iy + s, 0, s, s)
            g.setColor(own or item.icon_color)
        else
            g.setColor(1, 1, 1)
        end
        g.draw(icon, left, iy, 0, s, s)
    end
    -- text_on_icon: the count sits in a slot inside the marker sprite (e.g. the
    -- POWCOUNT "POW =" plate), placed by text_dx/text_dy in sprite pixels from the
    -- icon's top-left. Otherwise it follows the icon, offset only vertically.
    local px, ty
    if item.text_on_icon then
        px = left + (item.text_dx or 0) * s
        ty = y    + (item.text_dy or 0) * s
    else
        px = icon and (left + iconw) or left
        ty = y + (item.text_dy or 0) * s
    end
    -- CHARS bakes its own black outline (truecolor); tinted mask fonts get a hard
    -- black drop shadow (down-right) drawn first for legibility over terrain.
    if not font.truecolor then
        font:print(str, px + s, ty + s, { scale = s, color = { 0, 0, 0 } })
    end
    font:print(str, px, ty, { scale = s, color = item.color or { 1, 1, 1 } })
end

-- Blinking OVERKILL banner during a kill streak (Player:register_kill).
function Hud:_draw_overkill(_g, screen_w, screen_h, hud_scale)
    local p = self.player
    if not (p.overkill_active and p:overkill_active()) then return end
    if math.floor(love.timer.getTime() * 12) % 2 ~= 0 then return end
    local font = Font.get(self.overkill_font or "overkill0")
    local s    = 4 * hud_scale
    local w    = font:word_width(s)
    font:print_word((screen_w - w) / 2, screen_h * 0.28, { scale = s })
end

-- EXTRA (weapon_finds): names the weapon a player just found (Powerups:_grant
-- stamps found_weapon / found_time), centred on the item's anchor and faded in
-- and out over the item's time.
function Hud:_draw_notice(item, x, y, s)
    local p = self.player
    if not (p.found_weapon and self.world) then return end
    local age  = self.world.time - p.found_time
    local time = item.time or 2
    if age < 0 or age >= time then return end
    local def   = self.combat and self.combat.weapons[p.found_weapon]
    local name  = def and def.name or p.found_weapon:upper():gsub("_", " ")
    local text  = string.format(item.text or "%s", name)
    local font  = self:font(item.font)
    local alpha = math.min(1, age / (item.fade_in or 0.1), (time - age) / (item.fade_out or 0.5))
    font:print(text, math.floor(x - font:width(text, s) / 2), y, { scale = s, color = { 1, 1, 1, alpha } })
end

-- gauge

function Hud:_gauge_frame_index(item)
    local p   = self.player
    local val = item.value
    local pct
    if     val == "armor" then pct = p.max_armor > 0 and p.armor / p.max_armor or 0
    elseif val == "fuel"  then pct = p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 0
    else                       pct = 0
    end
    pct = math.max(0, math.min(1, pct))
    local n = item._frames and #item._frames or 0
    if n == 0 then return 1 end
    return math.floor(pct * (n - 1) + 0.5) + 1
end

function Hud:_gauge_pct(item)
    local p = self.player
    if     item.value == "armor" then return p.max_armor > 0 and p.armor / p.max_armor or 0
    elseif item.value == "fuel"  then return p.max_fuel  > 0 and p.fuel  / p.max_fuel  or 0
    end
    return 0
end

function Hud:_draw_gauge(g, item, x, y, s)
    if not item._frames then return end
    -- Low gauges (< 25%) blink to warn the player.
    if self:_gauge_pct(item) < 0.25 and (math.floor(love.timer.getTime() * 4) % 2 == 0) then
        return
    end
    local fi  = self:_gauge_frame_index(item)
    local img = item._frames[fi]
    if img then
        g.setColor(1, 1, 1)
        g.draw(img, x, y, 0, s, s)
    end
end

-- weapon icon

function Hud:_draw_weapon(g, item, x, y, s)
    if not item._frames then return end
    local p   = self.player
    local fi  = math.max(1, math.min(#item._frames, (p.weapon_icon or 0) + 1))
    local img = item._frames[fi]
    if img then
        g.setColor(1, 1, 1)
        g.draw(img, x, y, 0, s, s)
    end
end

-- targeting sight
-- The reticle of a locking weapon (weapon_def.sight = the sights frame index). It
-- rests ahead of the vehicle; on a locking level it eases toward the enemy the
-- missiles would acquire (combat:player_lock_target), so the player sees where
-- they will go. The eased position is clamped to a padded box inside the viewport
-- so the reticle never leaves the screen, and is kept per player for co-op. It
-- flashes a few times the moment a lock is acquired.
local SIGHT_BLINK_INTERVAL = 0.08   -- s per on/off half-cycle
local SIGHT_BLINK_COUNT    = 3      -- number of flashes on a new lock

-- World point the reticle should sit on for a lock target: the sprite's visual
-- center. Ground entities are drawn at (x,y) offset by their anchor, so the
-- center is x + ox + iw/2; helicopters are already drawn centered on (x,y).
function Hud:_target_center(tgt)
    if tgt.class_idx and self.world then
        local r = self.world.images[tgt.class_idx + 1]
        if r and r.img then
            local iw, ih = r.img:getDimensions()
            return tgt.x + r.ox + iw / 2, tgt.y + r.oy + ih / 2
        end
    end
    return tgt.x, tgt.y
end

-- Draws a sights frame centred on a world point, in the player's view.
function Hud:_draw_sight_at(g, img, p, wx, wy, s)
    local x, y = p.camera:project(wx, wy)
    local w, h = img:getDimensions()
    g.setColor(1, 1, 1)
    g.draw(img, x, y, 0, s, s, w / 2, h / 2)
end

-- EXTRA (air_strike_fx): the air strike sight stays on the target of the
-- player's pending strike, whatever weapon is selected, blinking once the
-- incoming call has sounded. Returns true while one is pending.
function Hud:_draw_strike_marker(g, item, p, s)
    local air_strike = self.combat.air_strike
    local strike     = Config.air_strike_fx and air_strike:pending(p)
    if not strike then return false end
    local def = strike.def
    local img = item._frames and item._frames[def.sight + 1]
    if not img then return true end
    local blink = air_strike:time_to_impact(strike) <= def.incoming
        and math.floor(self.world.time * def.marker_blink_hz * 2) % 2 == 1
    if not blink then self:_draw_sight_at(g, img, p, strike.x, strike.y, s) end
    return true
end

function Hud:_draw_sight(g, item, s)
    local p = self.player
    if not (p and self.combat and p.camera) then return end
    local striking   = self:_draw_strike_marker(g, item, p, s)
    local weapon_def = self.combat.weapons[p.weapon_name]
    if not (weapon_def and weapon_def.sight ~= nil) then
        p._sight_x, p._sight_y, p._sight_lock, p._sight_blink = nil, nil, nil, nil
        return
    end
    local img = item._frames and item._frames[weapon_def.sight + 1]
    if not img then return end

    -- The air strike sight rests on the point a strike called now would land
    -- on; while one is pending the marker above takes its place.
    if weapon_def.proj_type == "air_strike" then
        p._sight_x, p._sight_y, p._sight_lock, p._sight_blink = nil, nil, nil, nil
        if not striking then
            local rad = (p:fire_angle() - 90) * math.pi / 180
            self:_draw_sight_at(g, img, p, p.x + math.cos(rad) * weapon_def.target_distance,
                p.y + math.sin(rad) * weapon_def.target_distance, s)
        end
        return
    end

    local cam = p.camera
    local screen_w, screen_h = love.graphics.getDimensions()
    if self.view_w then screen_w, screen_h = self.view_w, self.view_h end

    -- Resting position: straight ahead of the vehicle (which always faces up on
    -- screen), a short way down from the top edge.
    local cx    = cam:screen_center()
    local rx    = cx
    local ry    = screen_h * (item.rest or 0.2)
    local tx, ty = rx, ry

    local level   = (weapon_def.levels and weapon_def.levels[p.weapon_level]) or weapon_def
    local locking = level.locking or weapon_def.homing
    local tgt
    if locking then
        tgt = self.combat:player_lock_target(p.x, p.y, p:fire_angle(),
            self.combat:player_range(weapon_def), weapon_def.target_kind, weapon_def.lock_arc)
        if tgt then tx, ty = cam:project(self:_target_center(tgt)) end
    end

    -- Keep the reticle inside a padded box so it never touches the screen edge.
    local w, h = img:getDimensions()
    local pad  = item.pad or 0.1
    local mx   = math.max(w / 2 * s + 2, screen_w * pad)
    local my   = math.max(h / 2 * s + 2, screen_h * pad)
    tx = math.max(mx, math.min(screen_w - mx, tx))
    ty = math.max(my, math.min(screen_h - my, ty))

    local dt = love.timer.getDelta()

    -- Flash on lock: restart the blink whenever the locked target changes.
    if tgt then
        if tgt ~= p._sight_lock then p._sight_lock, p._sight_blink = tgt, 0 end
        if p._sight_blink then p._sight_blink = p._sight_blink + dt end
    else
        p._sight_lock, p._sight_blink = nil, nil
    end
    local visible = true
    if p._sight_blink then
        if p._sight_blink < SIGHT_BLINK_INTERVAL * SIGHT_BLINK_COUNT * 2 then
            visible = math.floor(p._sight_blink / SIGHT_BLINK_INTERVAL) % 2 == 0
        else
            p._sight_blink = nil
        end
    end

    -- Ease the reticle toward the target so a lock reads as a smooth glide from
    -- the resting point (seeded there when the sight first appears).
    if not p._sight_x then p._sight_x, p._sight_y = rx, ry end
    local k = 1 - math.exp(-(item.lerp or 8) * dt)
    p._sight_x = p._sight_x + (tx - p._sight_x) * k
    p._sight_y = p._sight_y + (ty - p._sight_y) * k

    if visible then
        g.setColor(1, 1, 1)
        g.draw(img, p._sight_x, p._sight_y, 0, s, s, w / 2, h / 2)
    end
end

-- movement cursor

function Hud:_draw_cursor(g, item, x, y, s)
    local p     = self.player
    local size, half, inner, dot_sz

    -- Original game art (DATA/BOX.BIN, per-mission override under hud/stage{m}/)
    -- when present; otherwise the engine-drawn black frame.
    if item._bg then
        local bw = item._bg:getWidth()
        size   = bw * s
        half   = size / 2
        inner  = half - 3 * s
        dot_sz = math.max(3, math.floor(bw / 6) * s)
        g.setColor(1, 1, 1)
        g.draw(item._bg, x, y, 0, s, s)
    else
        size = (item.size or 36) * s
        half = size / 2
        local wall = math.max(2, math.floor(size / 8))
        g.setColor(0, 0, 0, 1.0)
        g.setLineWidth(wall)
        g.rectangle("line", x + wall/2, y + wall/2, size - wall, size - wall)
        g.setLineWidth(1)
        inner  = half - wall - 3 * s
        dot_sz = math.max(3, math.floor(size / 7))
    end

    -- Green dot: forward/back maps to Y, strafe to X, plus a lateral push from
    -- turning. A sustained turn drives the dot all the way to the box edge (and to
    -- the corner together with forward motion), like the original.
    local max_s  = (p.max_fwd and p.max_fwd > 0) and p.max_fwd or 260
    -- The tank has no strafe (strafe_speed 0); its X comes purely from the turn
    -- cursor, so guard the divide and skip the strafe term.
    local max_r  = (p.strafe_speed and p.strafe_speed > 0) and p.strafe_speed or nil
    local strafe = max_r and (p.strafe or 0) / max_r or 0
    local fx     = math.max(-1, math.min(1, strafe + (p.turn_cursor or 0)))
    local dx     = fx * inner
    local dy     = -(p.speed or 0) / max_s * inner
    local dot_x  = x + half + dx - dot_sz / 2
    local dot_y  = y + half + dy - dot_sz / 2

    -- Green while the vehicle is under power: an airborne chopper, or the tank,
    -- which is always driving. Otherwise (a grounded chopper) a dim amber.
    local ground_vehicle = p.is_flyer and not p:is_flyer()
    if p.land_state == "airborne" or p.land_state == "taking_off" or ground_vehicle then
        g.setColor(0.1, 1.0, 0.15, 1.0)
    else
        g.setColor(0.85, 0.75, 0.1, 1.0)
    end
    g.rectangle("fill", dot_x, dot_y, dot_sz, dot_sz)
end

-- radar

-- The entities that can show on the radar, rebuilt when a stage load replaces the
-- world's entity list: most of a stage is scenery that never shows.
function Hud:_radar_entities()
    local entities = self.world.entities
    if self._radar_source ~= entities then
        local classes = self.world.stage.classes
        local list = {}
        for _, e in ipairs(entities) do
            local kind = classes[e.class_idx + 1].kind_name
            if e.objective or RADAR_ENEMY[kind] or RADAR_BUILDING[kind] then list[#list + 1] = e end
        end
        self._radar_source, self._radar_list = entities, list
    end
    return self._radar_list
end

-- The scanner ring, over the EXTRA (radar_backdrop) dark glass disc. The
-- original radar is see-through, its dark ring and blips made for the bright
-- DOS terrain; under night lighting and post-processing that terrain turns
-- dark too, so the backdrop fades in a disc of its own and recolors the ring
-- toward a light tone, both scaled by Config.radar_backdrop (0 = classic).
function Hud:_draw_radar_backdrop(g, item, x, y, s, cx, cy, radius)
    local amount = Config.radar_backdrop or 0
    if amount <= 0 then
        g.setColor(1, 1, 1)
        g.draw(item._bg, x, y, 0, s, s)
        return
    end
    local back = item.backdrop_color or { 0.02, 0.05, 0.04 }
    g.setColor(back[1], back[2], back[3], (item.backdrop_alpha or 0.85) * amount)
    g.circle("fill", cx, cy, radius - s, 48)

    local ring    = item.ring_color or { 0.72, 0.76, 0.84 }
    local classic = item.ring_classic or { 0.235, 0.235, 0.298 }
    self._tint_shader = self._tint_shader or g.newShader(TINT_SRC)
    g.setShader(self._tint_shader)
    g.setColor(classic[1] + (ring[1] - classic[1]) * amount,
        classic[2] + (ring[2] - classic[2]) * amount,
        classic[3] + (ring[3] - classic[3]) * amount)
    g.draw(item._bg, x, y, 0, s, s)
    g.setShader()
end

function Hud:_draw_radar(g, item, x, y, s)
    local p    = self.player
    local zoom = self:_radar_zoom_amount()

    -- Auto zoom narrows the range geometrically, so the zoom feels even across
    -- the whole animation.
    local base_range = item.world_range or 900
    local zoom_range = item.zoom_range or base_range
    local range      = base_range * (zoom_range / base_range) ^ zoom

    -- EXTRA (radar_zoom_grow): the radar also grows while zoomed, about a pivot
    -- given as a fraction of its box (the bottom edge by default, so it grows up
    -- off the screen edge rather than past it).
    if Config.radar_zoom_grow and zoom > 0 then
        local grow  = 1 + ((item.zoom_scale or 1) - 1) * zoom
        local pivot = item.zoom_pivot or { 0.5, 1 }
        local box_w = item._bg and item._bg:getWidth()  * s or (item.radius or 88) * s * 2
        local box_h = item._bg and item._bg:getHeight() * s or (item.radius or 88) * s * 2
        x = x + pivot[1] * box_w * (1 - grow)
        y = y + pivot[2] * box_h * (1 - grow)
        s = s * grow
    end
    local r = (item.radius or 88) * s

    -- center: middle of the (scaled) background image
    local cx, cy
    if item._bg then
        local bw = item._bg:getWidth()  * s
        local bh = item._bg:getHeight() * s
        cx = x + bw / 2
        cy = y + bh / 2
        self:_draw_radar_backdrop(g, item, x, y, s, cx, cy, bw / 2)
    else
        cx = x + r
        cy = y + r
        g.setColor(0, 0.04, 0, 0.92)
        g.circle("fill", cx, cy, r)
        g.setColor(0.1, 0.5, 0.1)
        g.setLineWidth(2)
        g.circle("line", cx, cy, r)
        g.setLineWidth(1)
    end

    if not self.world then return end

    local pa      = -(p.angle * math.pi / 180)
    local cos_pa  = math.cos(pa)
    local sin_pa  = math.sin(pa)
    local px_per_unit = r / range
    local classes = self.world.stage.classes
    local dot_r   = math.max(0.8, s * 0.8)

    -- Bucket blips by priority and draw low-to-high so the mission goal is never
    -- hidden under a building/enemy dot: buildings (brown) and the home base
    -- (black: its buildings, and the pad as a larger blip) first, enemies (red) next, objectives (white) last on top.
    local buildings, enemies, objectives, air, pickups = {}, {}, {}, {}, {}
    local base, base_buildings = {}, {}

    local function plot(bucket, ex, ey)
        local wdx, wdy = self.world:delta(ex, ey, p.x, p.y)
        local dx = wdx * px_per_unit
        local dy = wdy * px_per_unit
        local rx = dx * cos_pa - dy * sin_pa
        local ry = dx * sin_pa + dy * cos_pa
        if rx * rx + ry * ry <= r * r then bucket[#bucket + 1] = { rx, ry } end
    end
    for _, e in ipairs(self:_radar_entities()) do
        if e:is_alive() and not e.dormant then
            local kind = classes[e.class_idx + 1].kind_name
            local bucket
            if     e.objective          then bucket = objectives
            elseif RADAR_ENEMY[kind]    then bucket = enemies
            elseif e.base_building      then bucket = base_buildings
            else                             bucket = buildings
            end
            plot(bucket, e.x, e.y)
        end
    end

    local home = self.world.home_entity
    if home then plot(base, home.x, home.y) end

    -- Airborne enemy helicopters live outside world.entities (heli system).
    for _, h in ipairs(self.world.air_units or {}) do
        if h.state == "alive" then plot(air, h.x, h.y) end
    end

    -- Power-ups, blinking fast once they are about to expire.
    local powerups = self.powerups
    if powerups then
        for _, pu in ipairs(powerups.list) do
            if not powerups:expiring(pu) or math.floor(pu.age * RADAR_PICKUP_BLINK * 2) % 2 == 0 then
                plot(pickups, pu.x, pu.y)
            end
        end
    end

    -- EXTRA (air_strike_fx): pending air strike targets, blinking.
    local strikes    = {}
    local air_strike = Config.air_strike_fx and self.combat and self.combat.air_strike
    if air_strike and math.floor(self.world.time * RADAR_STRIKE_BLINK * 2) % 2 == 0 then
        for _, strike in ipairs(air_strike.strikes) do
            if air_strike:landing(strike) then plot(strikes, strike.x, strike.y) end
        end
    end

    local backdrop = Config.radar_backdrop or 0
    local function draw_blips(blips, colors, size)
        local half     = dot_r * (size or 1)
        local dim, lit = colors.classic, colors.bright
        g.setColor(dim[1] + (lit[1] - dim[1]) * backdrop, dim[2] + (lit[2] - dim[2]) * backdrop,
            dim[3] + (lit[3] - dim[3]) * backdrop, 0.95)
        for _, b in ipairs(blips) do
            g.rectangle("fill", cx + b[1] - half, cy + b[2] - half, half * 2, half * 2)
        end
    end
    draw_blips(buildings,      RADAR_COLORS.building)
    draw_blips(base_buildings, RADAR_COLORS.base)
    draw_blips(base,           RADAR_COLORS.base, item.base_size or 1.6)
    draw_blips(enemies,        RADAR_COLORS.enemy)
    draw_blips(air,            RADAR_COLORS.air)
    draw_blips(pickups,        RADAR_COLORS.pickup)
    draw_blips(strikes,        RADAR_COLORS.strike, 1.6)
    draw_blips(objectives,     RADAR_COLORS.objective)

    -- Co-op teammate (split screen): a larger dot in the teammate's color.
    local mate = self.coplayer
    if mate and (mate.armor or 0) > 0 and not mate.death then
        local wdx, wdy = self.world:delta(mate.x, mate.y, p.x, p.y)
        local dx = wdx * px_per_unit
        local dy = wdy * px_per_unit
        local rx = dx * cos_pa - dy * sin_pa
        local ry = dx * sin_pa + dy * cos_pa
        if rx * rx + ry * ry <= r * r then
            local col = self.coplayer_color or { 1, 1, 1 }
            g.setColor(col[1], col[2], col[3], 1)
            g.rectangle("fill", cx + rx - dot_r, cy + ry - dot_r, dot_r * 2, dot_r * 2)
        end
    end
end

return Hud
