-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local json      = require "lib.json"
local Config    = require "engine.core.config"
local Animation = require "engine.core.animation"

-- Small presentation details, each an EXTRA with its own Config key:
--   tank_recoil   the tank turret kicks back on a shell shot, with muzzle smoke
--   shell_casings the chaingun spills brass casings that settle and fade
--   tread_dust    a tank at speed kicks up dust (snow in winter) behind its treads
--   wreck_smoke   destroyed buildings and tanks keep smoking for a while
--   shell_impact  a tank shell bursts into an explosion where it strikes
--   pickup_glint  a light sweep runs across each pickup now and then
--   target_glint  the same sweep across every live mission objective
-- Fed one way by the World forwarders (:weapon_fired, :projectile_impact, :wreck)
-- and by the players read after each tick; never read back by the simulation.
-- Tuning is data/detail_fx.json.
local DetailFX = Class()

local DATA_PATH = "data/detail_fx.json"

-- Pickup glint: a band across the sprite along dir (image pixels, unit length),
-- centred at pos (-1..1 of the sprite's extent along dir), clipped to the sprite's
-- own pixels and sampled per art pixel so it stays blocky like the art.
local GLINT_SRC = [[
uniform vec2 dir;
uniform vec2 size;
uniform float pos;
uniform float width;
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen)
{
    vec2 p  = floor(uv * size) + 0.5 - size * 0.5;
    float s = dot(p, dir) / dot(abs(dir), size * 0.5);
    float k = 1.0 - smoothstep(0.0, width, abs(s - pos));
    return vec4(color.rgb, Texel(tex, uv).a * k * color.a);
}
]]

local function set_of(list)
    local out = {}
    for _, v in ipairs(list or {}) do out[v] = true end
    return out
end

function DetailFX:init()
    local raw = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    self.data = raw and json.decode(raw) or {}
    local d   = self.data
    self.recoil_weapons = set_of(d.recoil and d.recoil.weapons)
    self.casing_weapons = set_of(d.casings and d.casings.weapons)
    self.dust_color     = nil
    self.puff_img       = nil
    self.batch          = nil
    self.glint_shader   = nil
    self:reset()
end

function DetailFX:enter(world)
    self:reset()
    local m     = world and world.stage_name and world.stage_name:match("^stage(%d)")
    local colors = self.data.tread_dust and self.data.tread_dust.colors or {}
    self.dust_color = (m and colors[m]) or colors.default
end

function DetailFX:reset()
    self.recoils    = setmetatable({}, { __mode = "k" })   -- player -> seconds since the shot
    self.dust_timer = setmetatable({}, { __mode = "k" })   -- player -> seconds to the next puff
    self.smokes     = {}   -- {anim, x, y, vx, vy, scale_from, scale_to, alpha, tint}
    self.casings    = {}   -- {x, y, vx, vy, rot, spin, age}
    self.dusts      = {}   -- {x, y, vx, vy, age}
    self.wrecks     = {}   -- {x, y, left, time, interval, timer}
    self.impacts    = {}   -- {anim, x, y, scale}
end

-- emitters

-- A weapon fired at (x, y) by shooter (a Player for the player's own shots).
function DetailFX:fire(x, y, weapon_name, shooter)
    if not shooter or not shooter.fire_angle then return end
    if Config.tank_recoil and shooter.vehicle == "tank" and self.recoil_weapons[weapon_name] then
        self:_recoil(x, y, shooter)
    end
    if Config.shell_casings and self.casing_weapons[weapon_name] then
        self:_casing(shooter)
    end
end

-- EXTRA (tank_recoil)
function DetailFX:_recoil(x, y, player)
    local spec = self.data.recoil
    self.recoils[player] = 0
    local rad    = (player:fire_angle() - 90) * math.pi / 180
    local fx, fy = math.cos(rad), math.sin(rad)
    for _ = 1, spec.smoke_count do
        local speed = spec.smoke_speed * (0.5 + math.random())
        self.smokes[#self.smokes + 1] = {
            anim  = Animation.new(spec.smoke_clip),
            x     = x + (math.random() - 0.5) * 2 * spec.smoke_jitter,
            y     = y + (math.random() - 0.5) * 2 * spec.smoke_jitter,
            vx    = fx * speed, vy = fy * speed,
            scale_from = spec.smoke_scale, scale_to = spec.smoke_scale * 1.5,
            alpha = spec.smoke_alpha, tint = 1,
        }
    end
end

-- EXTRA (shell_casings): ejected to the shooter's right, carrying part of its
-- velocity so a moving vehicle does not outrun its own brass.
function DetailFX:_casing(player)
    local spec = self.data.casings
    local rad  = (player:fire_angle() - 90) * math.pi / 180
    local out  = rad + math.pi / 2 + (math.random() - 0.5) * spec.spread_deg * math.pi / 180
    local head = (player.angle - 90) * math.pi / 180
    local vx   = math.cos(head) * player.speed + math.cos(head + math.pi / 2) * (player.strafe or 0)
    local vy   = math.sin(head) * player.speed + math.sin(head + math.pi / 2) * (player.strafe or 0)
    local speed = spec.speed * (0.6 + math.random() * 0.8)
    local casings = self.casings
    if #casings >= spec.max then table.remove(casings, 1) end
    casings[#casings + 1] = {
        x = player.x, y = player.y,
        vx = vx * spec.carry + math.cos(out) * speed,
        vy = vy * spec.carry + math.sin(out) * speed,
        rot = math.random() * 2 * math.pi, spin = (math.random() - 0.5) * 2 * spec.spin, age = 0,
    }
end

-- EXTRA (shell_impact): a player round of a listed weapon struck at (x, y).
-- Returns the clip it plays, or nil.
function DetailFX:impact(x, y, weapon_name)
    local spec = self.data.impact
    local clip = spec and spec.weapons[weapon_name or ""]
    if not Config.shell_impact or not clip then return nil end
    self.impacts[#self.impacts + 1] = { anim = Animation.new(clip), x = x, y = y, scale = spec.scale or 1 }
    return clip
end

-- EXTRA (wreck_smoke): an entity died with the given explosion size.
function DetailFX:wreck(x, y, explosion)
    local spec = self.data.wreck_smoke
    local kind = spec and spec.explosions[explosion]
    if not Config.wreck_smoke or not kind then return end
    self.wrecks[#self.wrecks + 1] = {
        x = x, y = y, left = kind.time, time = kind.time, interval = kind.interval, timer = 0,
    }
end

-- update

-- EXTRA (tread_dust): puffs behind both treads of a tank moving at speed.
function DetailFX:_tread_dust(dt, player)
    local spec = self.data.tread_dust
    if not Config.tread_dust or not spec or not self.dust_color
    or player.vehicle ~= "tank" or player.death
    or math.abs(player.speed) < spec.min_speed * player.max_fwd * (player.speed_factor or 1) then
        self.dust_timer[player] = nil
        return
    end
    local timer = (self.dust_timer[player] or 0) - dt
    if timer > 0 then
        self.dust_timer[player] = timer
        return
    end
    self.dust_timer[player] = spec.interval
    if #self.dusts >= spec.max then return end
    local w, h   = player:tank_hull_size()
    local rad    = (player.angle - 90) * math.pi / 180
    local fx, fy = math.cos(rad), math.sin(rad)
    local back   = player.speed >= 0 and -1 or 1   -- the trailing end of the hull
    for side = -1, 1, 2 do
        local lat = side * w * spec.gauge * 0.5
        local x   = player.x + fx * back * h * spec.rear - fy * lat
        local y   = player.y + fy * back * h * spec.rear + fx * lat
        self.dusts[#self.dusts + 1] = {
            age = 0,
            x  = x + (math.random() - 0.5) * 2 * spec.jitter,
            y  = y + (math.random() - 0.5) * 2 * spec.jitter,
            vx = fx * player.speed * spec.drift, vy = fy * player.speed * spec.drift,
        }
    end
end

local function update_puffs(list, dt)
    local live = {}
    for _, p in ipairs(list) do
        p.anim:update(dt)
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        if not p.anim:is_done() then live[#live + 1] = p end
    end
    return live
end

function DetailFX:_update_dusts(dt)
    local lifetime = self.data.tread_dust and self.data.tread_dust.lifetime or 0
    local live = {}
    for _, p in ipairs(self.dusts) do
        p.age = p.age + dt
        p.x   = p.x + p.vx * dt
        p.y   = p.y + p.vy * dt
        if p.age < lifetime then live[#live + 1] = p end
    end
    self.dusts = live
end

function DetailFX:_update_wrecks(dt)
    local spec = self.data.wreck_smoke
    if not spec then return end
    local live = {}
    for _, w in ipairs(self.wrecks) do
        w.left  = w.left - dt
        w.timer = w.timer - dt
        if w.timer <= 0 and Config.wreck_smoke and #self.smokes < spec.max then
            w.timer = w.interval * (0.7 + math.random() * 0.6)
            local life = w.left / w.time
            local thin = spec.thin > 0 and math.min(1, life / spec.thin) or 1
            self.smokes[#self.smokes + 1] = {
                anim  = Animation.new(spec.clip),
                x     = w.x + (math.random() - 0.5) * 2 * spec.jitter,
                y     = w.y + (math.random() - 0.5) * 2 * spec.jitter,
                vx    = spec.wind[1] * (0.6 + math.random() * 0.8),
                vy    = spec.wind[2] * (0.6 + math.random() * 0.8),
                scale_from = spec.scale_from, scale_to = spec.scale_to,
                alpha = spec.alpha * thin, tint = spec.tint,
            }
        end
        if w.left > 0 then live[#live + 1] = w end
    end
    self.wrecks = live
end

function DetailFX:_update_casings(dt)
    local spec = self.data.casings
    if not spec then return end
    local live = {}
    local keep = math.max(0, 1 - spec.drag * dt)
    for _, c in ipairs(self.casings) do
        c.age  = c.age + dt
        c.x    = c.x + c.vx * dt
        c.y    = c.y + c.vy * dt
        c.rot  = c.rot + c.spin * dt
        c.vx, c.vy, c.spin = c.vx * keep, c.vy * keep, c.spin * keep
        if c.age < spec.lifetime then live[#live + 1] = c end
    end
    self.casings = live
end

function DetailFX:update(dt, players)
    for player, t in pairs(self.recoils) do
        t = t + dt
        self.recoils[player] = (t < self.data.recoil.time) and t or nil
    end
    for _, p in ipairs(players) do self:_tread_dust(dt, p) end
    self.smokes = update_puffs(self.smokes, dt)
    local impacts = {}
    for _, b in ipairs(self.impacts) do
        b.anim:update(dt)
        if not b.anim:is_done() then impacts[#impacts + 1] = b end
    end
    self.impacts = impacts
    self:_update_dusts(dt)
    self:_update_casings(dt)
    self:_update_wrecks(dt)
end

-- queries

-- EXTRA (tank_recoil): how far back (art pixels) the player's turret sits now.
function DetailFX:recoil_kick(player)
    local t = self.recoils[player]
    if not t or not Config.tank_recoil then return 0 end
    local spec = self.data.recoil
    return spec.kick * (1 - t / spec.time) ^ 2
end

-- draw

local function draw_puffs(list)
    local g = love.graphics
    for _, p in ipairs(list) do
        local img = p.anim:current_image()
        if img then
            local w, h = img:getDimensions()
            local s    = p.scale_from + (p.scale_to - p.scale_from) * p.anim:progress()
            local tint = p.tint or 1
            if type(tint) == "table" then
                g.setColor(tint[1], tint[2], tint[3], p.alpha)
            else
                g.setColor(tint, tint, tint, p.alpha)
            end
            g.draw(img, p.x, p.y, 0, s, s, w / 2, h / 2)
        end
    end
end

-- Soft round puff, opaque at the centre and fading to nothing at the rim.
local PUFF_SIZE = 32

local function make_puff()
    local data = love.image.newImageData(PUFF_SIZE, PUFF_SIZE)
    local r    = PUFF_SIZE / 2
    data:mapPixel(function(x, y)
        local dx, dy = (x + 0.5 - r) / r, (y + 0.5 - r) / r
        local a = math.max(0, 1 - math.sqrt(dx * dx + dy * dy))
        return 1, 1, 1, a * a
    end)
    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

-- EXTRA (tread_dust): puffs grow from size_from to size_to (world units) and
-- fade out over their lifetime.
function DetailFX:_draw_dust()
    local spec = self.data.tread_dust
    local g    = love.graphics
    local c    = self.dust_color
    self.puff_img = self.puff_img or make_puff()
    for _, p in ipairs(self.dusts) do
        local t    = p.age / spec.lifetime
        local size = spec.size_from + (spec.size_to - spec.size_from) * (1 - (1 - t) ^ 2)
        local s    = size / PUFF_SIZE
        g.setColor(c[1], c[2], c[3], spec.alpha * (1 - t))
        g.draw(self.puff_img, p.x, p.y, 0, s, s, PUFF_SIZE / 2, PUFF_SIZE / 2)
    end
end

-- Ground layer, inside the renderer's ground pass: casings and tread dust.
function DetailFX:draw_ground()
    local g = love.graphics
    if Config.tread_dust and self.data.tread_dust and self.dust_color and #self.dusts > 0 then
        self:_draw_dust()
    end
    local spec = self.data.casings
    if Config.shell_casings and spec and #self.casings > 0 then
        if not self.batch then
            local pixel = love.image.newImageData(1, 1)
            pixel:setPixel(0, 0, 1, 1, 1, 1)
            self.batch = g.newSpriteBatch(g.newImage(pixel), spec.max, "stream")
        end
        local batch = self.batch
        local c     = spec.color
        batch:clear()
        for _, casing in ipairs(self.casings) do
            local a = math.min(1, (spec.lifetime - casing.age) / spec.fade)
            batch:setColor(c[1], c[2], c[3], a)
            batch:add(casing.x, casing.y, casing.rot, spec.width, spec.length, 0.5, 0.5)
        end
        g.setColor(1, 1, 1)
        g.draw(batch)
    end
    g.setColor(1, 1, 1)
end

-- EXTRA (pickup_glint, target_glint): redraws a sprite, just drawn at (x, y)
-- with rotation rot and origin (ox, oy), as the glint band when one is sweeping.
-- key names both the Config toggle and the data block. screen_rot is the
-- sprite's total rotation on screen, so the sweep keeps one screen direction;
-- t is a running time, offset by the position so sprites glint out of step.
function DetailFX:draw_glint(key, img, x, y, rot, ox, oy, screen_rot, t)
    local spec = self.data[key]
    if not Config[key] or not spec then return end
    local u = ((t + x * 0.137 + y * 0.311) % spec.period) / spec.sweep
    if u >= 1 then return end
    local g      = love.graphics
    local w, h   = img:getDimensions()
    local angle  = spec.angle_deg * math.pi / 180 - screen_rot
    local reach  = 1 + spec.width
    local c      = spec.color or { 1, 1, 1 }
    self.glint_shader = self.glint_shader or g.newShader(GLINT_SRC)
    local shader = self.glint_shader
    shader:send("dir", { math.cos(angle), math.sin(angle) })
    shader:send("size", { w, h })
    shader:send("pos", reach * (2 * u - 1))
    shader:send("width", spec.width)
    g.setShader(shader)
    g.setColor(c[1], c[2], c[3], spec.strength)
    g.draw(img, x, y, rot, 1, 1, ox, oy)
    g.setShader()
    g.setColor(1, 1, 1)
end

-- Air layer, over the objects: muzzle and wreck smoke.
function DetailFX:draw_air()
    local g = love.graphics
    g.setColor(1, 1, 1)
    for _, b in ipairs(self.impacts) do   -- EXTRA (shell_impact)
        local img = b.anim:current_image()
        if img then
            local w, h = img:getDimensions()
            g.draw(img, b.x, b.y, 0, b.scale, b.scale, w / 2, h / 2)
        end
    end
    if #self.smokes > 0 then draw_puffs(self.smokes) end
    g.setColor(1, 1, 1)
end

return DetailFX
