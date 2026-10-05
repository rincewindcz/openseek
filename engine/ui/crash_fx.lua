-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local json   = require "lib.json"
local Config = require "engine.core.config"
local Font   = require "engine.core.font"
local Log    = require "engine.core.log"

-- The crash / game-over picture brought to life, handed to Screen:show as its
-- fx (engine/core/screen.lua). Two EXTRAs, each with its own Config key:
--   crash_fx     smoke rising off the wreck, heat haze, a fire glow with embers,
--                and a flash and static cut in place of the fade-in
--   crash_cause  what destroyed the vehicle, typed under the picture
-- Everything but the text is composed at the picture's own resolution, so it
-- stays as blocky as the art. Presentation only; tuning is data/crash_fx.json.
local CrashFX = Class()

local DATA_PATH  = "data/crash_fx.json"
local HAZE_SLOTS = 3
local PUFF_SIZE  = 32
local STEP       = 0.1   -- prewarm step, seconds

-- Per art pixel: haze shifts rows sideways inside the haze ellipses, the glitch
-- tears bands of rows and mixes in static. haze[i] is centre x, y and radius
-- x, y in art pixels (a zero radius is an unused slot); wave is amplitude,
-- wavelength (art pixels) and speed; glitch is strength, tear (art pixels),
-- band height (rows) and static mix; scan darkens every other row with it.
local SHADER_SRC = [[
uniform vec2  size;
uniform float time;
uniform float seed;
uniform float scan;
uniform vec3  wave;
uniform vec4  glitch;
uniform vec4  haze[3];

float hash(vec2 p)
{
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen)
{
    vec2 cell = floor(uv * size);
    vec2 p    = cell + 0.5;
    float mask = 0.0;
    for (int i = 0; i < 3; i++) {
        vec2 d = (p - haze[i].xy) / max(haze[i].zw, vec2(0.001));
        mask = max(mask, 1.0 - smoothstep(0.3, 1.0, length(d)));
    }
    float k = 6.2832 / wave.y;
    float w = sin(p.y * k + time * wave.z)
            + 0.5 * sin(p.y * k * 2.7 - time * wave.z * 1.7 + p.x * 0.11);
    p.x += w * wave.x * mask;

    float level = glitch.x;
    if (level > 0.0) {
        float band = floor(cell.y / glitch.z);
        float torn = step(1.0 - level, hash(vec2(seed, band)));
        p.x += (hash(vec2(band, seed)) - 0.5) * 2.0 * glitch.y * level * torn;
    }
    vec3 c = Texel(tex, vec2(fract(p.x / size.x), p.y / size.y)).rgb;
    if (level > 0.0) {
        c = mix(c, vec3(hash(cell + seed * 17.0)), glitch.w * level);
        c *= 1.0 - scan * level * mod(cell.y, 2.0);
    }
    return vec4(c * color.rgb, color.a);
}
]]

local data
local shader
local puff_img
local canvases = {}

local function load_data()
    if data then return data end
    local raw = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    data = raw and json.decode(raw) or {}
    for _, key in ipairs({ "entrance", "glitch", "haze", "smoke", "cause", "respawn", "preview", "pictures" }) do
        data[key] = data[key] or {}
    end
    return data
end

-- The compiled shader, or nil where it does not build (the picture then shows
-- its smoke and fire without haze or static).
local function get_shader()
    if shader == nil then
        local ok, result = pcall(love.graphics.newShader, SHADER_SRC)
        if not ok then Log.warn("crash_fx", "shader failed: %s", tostring(result)) end
        shader = ok and result or false
    end
    return shader or nil
end

-- Soft round puff, opaque at the centre and fading to nothing at the rim.
local function get_puff()
    if not puff_img then
        local image_data = love.image.newImageData(PUFF_SIZE, PUFF_SIZE)
        local r = PUFF_SIZE / 2
        image_data:mapPixel(function(x, y)
            local dx, dy = (x + 0.5 - r) / r, (y + 0.5 - r) / r
            local a = math.max(0, 1 - math.sqrt(dx * dx + dy * dy))
            return 1, 1, 1, a * a
        end)
        puff_img = love.graphics.newImage(image_data)
        puff_img:setFilter("linear", "linear")
    end
    return puff_img
end

local function get_canvas(w, h)
    local key = w * 65536 + h
    if not canvases[key] then
        canvases[key] = love.graphics.newCanvas(w, h)
        canvases[key]:setFilter("nearest", "nearest")
    end
    return canvases[key]
end

local function spread(amount)
    return (math.random() - 0.5) * 2 * amount
end

local function cause_text(spec, vehicle, cause)
    local line = spec.lines and spec.lines[cause or ""]
    if line then return line end
    local verb  = spec.verbs and spec.verbs[vehicle] or "DESTROYED BY"
    local label = spec.labels and spec.labels[cause or ""] or spec.unknown or "ENEMY FIRE"
    return verb .. " " .. label
end

-- Show the picture of player's lost vehicle on screen (a Screen). terminal is
-- the game-over picture, held until a key. Otherwise it is the one before a
-- respawn: a flash as in the original, or with an extra on held for
-- respawn.hold so it can be read (a key ends it early). opts carries on_done /
-- on_cancel. Returns the picture's fx, nil with both extras off.
function CrashFX.show(screen, player, terminal, opts)
    opts = opts or {}
    local d       = load_data()
    local picture = (player.vehicle == "tank") and "TANKEND" or "DEATHPIC"
    local fx
    if Config.crash_fx or Config.crash_cause then
        local dry = (player.fuel or 1) <= 0 and (player.armor or 0) > 0
        fx = CrashFX:new(picture, player.vehicle, dry and "fuel" or player.damage_cause)
    end
    local show = { cues = "crash", variant = player.vehicle, fx = fx,
        on_done = opts.on_done, on_cancel = opts.on_cancel }
    if terminal then
        show.fade_in, show.wait_key = 0.6, true
    elseif fx then
        show.fade_in, show.fade_out = 0.1, d.respawn.fade_out or 0.3
        show.wait_key, show.timeout = true, d.respawn.hold or 3.2
    else
        show.fade_in, show.hold, show.fade_out = 0.1, 0.5, 0.1
    end
    screen:show(picture, show)
    return fx
end

-- Dev preview from the overview: the picture of a lost vehicle of that kind,
-- with data/crash_fx.json read again so an edit shows without a restart.
function CrashFX.preview(screen, vehicle, terminal)
    data = nil
    local cause = load_data().preview.cause
    return CrashFX.show(screen, { vehicle = vehicle, damage_cause = cause }, terminal)
end

function CrashFX:init(picture, vehicle, cause)
    local d       = load_data()
    self.data     = d
    self.animated = Config.crash_fx
    self.cut      = self.animated   -- Screen: no fade-in, the entrance plays instead
    self.spec     = self.animated and d.pictures[picture] or {}
    self.text     = Config.crash_cause and cause_text(d.cause, vehicle, cause) or nil
    self.age      = 0
    self.burst    = nil   -- {t, time}: static burst set off by an audio cue
    self.puffs    = {}    -- {spec, x, y, vx, vy, age, life, sway}
    self.embers   = {}    -- {spec, x, y, vx, vy, age, life, sway}
    self.emitters = {}    -- {spec, timer} per smoke source
    self.fires    = {}    -- {spec, carry, phase} per fire
    for _, e in ipairs(self.spec.smoke or {}) do
        self.emitters[#self.emitters + 1] = { spec = e, timer = 0 }
    end
    for _, f in ipairs(self.spec.fire or {}) do
        self.fires[#self.fires + 1] = { spec = f, carry = 0, phase = math.random() * 2 * math.pi }
    end
    -- The column already stands when the picture cuts in.
    for _ = 1, math.floor((d.smoke.prewarm or 0) / STEP) do self:_step(STEP) end
end

-- update

function CrashFX:_emit_smoke(e)
    local velocity = e.velocity or { 0, -12 }
    self.puffs[#self.puffs + 1] = {
        spec = e, age = 0,
        x    = e.x + spread(e.jitter or 0),
        y    = e.y + spread(e.jitter or 0),
        vx   = velocity[1] + spread(e.spread or 0),
        vy   = velocity[2] + spread(e.spread or 0),
        life = (e.lifetime or 5) * (0.8 + math.random() * 0.4),
        sway = math.random() * 2 * math.pi,
    }
end

function CrashFX:_emit_ember(f)
    local velocity = f.ember_velocity or { 0, -20 }
    local reach    = (f.radius or 10) * 0.4
    self.embers[#self.embers + 1] = {
        spec = f, age = 0,
        x    = f.x + spread(reach),
        y    = f.y + spread(reach),
        vx   = velocity[1] + spread(f.ember_spread or 0),
        vy   = velocity[2] * (0.6 + math.random() * 0.8),
        life = (f.ember_life or 2) * (0.5 + math.random()),
        sway = math.random() * 2 * math.pi,
    }
end

local function advance(list, dt)
    local live = {}
    for _, p in ipairs(list) do
        p.age = p.age + dt
        p.x   = p.x + (p.vx + math.sin(p.age * 1.3 + p.sway) * (p.spec.sway or 0)) * dt
        p.y   = p.y + p.vy * dt
        if p.age < p.life then live[#live + 1] = p end
    end
    return live
end

function CrashFX:_step(dt)
    local max = self.data.smoke.max or 240
    for _, emitter in ipairs(self.emitters) do
        emitter.timer = emitter.timer - dt
        while emitter.timer <= 0 do
            emitter.timer = emitter.timer + (emitter.spec.interval or 0.25) * (0.7 + math.random() * 0.6)
            if #self.puffs < max then self:_emit_smoke(emitter.spec) end
        end
    end
    for _, fire in ipairs(self.fires) do
        fire.carry = fire.carry + (fire.spec.embers or 0) * dt
        while fire.carry >= 1 do
            fire.carry = fire.carry - 1
            self:_emit_ember(fire.spec)
        end
    end
    self.puffs  = advance(self.puffs, dt)
    self.embers = advance(self.embers, dt)
end

function CrashFX:update(dt)
    self.age = self.age + dt
    local burst = self.burst
    if burst then
        burst.t = burst.t + dt
        if burst.t >= burst.time then self.burst = nil end
    end
    if self.animated then self:_step(dt) end
end

-- An audio cue of the overlay's sequence just played: radio noise shows as a
-- burst of static.
function CrashFX:cue(event)
    local time = self.animated and (self.data.glitch.events or {})[event]
    if time and time > 0 then self.burst = { t = 0, time = time } end
end

-- draw

-- Static strength now (0..1): the entrance resolving into the picture, or a
-- cue's burst fading out.
function CrashFX:_glitch_level()
    local level  = 0
    local static = self.data.entrance.static or 0
    if self.age < static then level = (1 - self.age / static) ^ 2 end
    local burst = self.burst
    if burst then
        level = math.max(level, (self.data.glitch.burst or 0.5) * (1 - burst.t / burst.time))
    end
    return level
end

-- The picture with its fire, smoke and embers, at the picture's resolution.
function CrashFX:_compose(img)
    local g      = love.graphics
    local canvas = get_canvas(img:getDimensions())
    local puff   = get_puff()
    local fade   = self.data.smoke.fade_in or 0.15
    g.push("all")
    g.setCanvas(canvas)
    g.origin()
    g.setScissor()
    g.setShader()
    g.clear(0, 0, 0, 1)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    g.draw(img, 0, 0)

    g.setBlendMode("add")
    for _, fire in ipairs(self.fires) do
        local f       = fire.spec
        local c       = f.color or { 1, 0.5, 0.1 }
        local flicker = 0.5 + 0.25 * math.sin(self.age * 13 + fire.phase)
            + 0.25 * math.sin(self.age * 7.3 + fire.phase * 2)
        local s       = (f.radius or 10) * 2 * (1 + 0.08 * flicker) / PUFF_SIZE
        g.setColor(c[1], c[2], c[3], (f.alpha or 0.25) * (1 - (f.flicker or 0.5) * flicker))
        g.draw(puff, f.x, f.y, 0, s, s, PUFF_SIZE / 2, PUFF_SIZE / 2)
    end

    g.setBlendMode("alpha")
    for _, p in ipairs(self.puffs) do
        local e    = p.spec
        local c    = e.color or { 0.5, 0.5, 0.5 }
        local t    = p.age / p.life
        local from = e.size_from or 10
        local s    = (from + ((e.size_to or 40) - from) * (1 - (1 - t) ^ 2)) / PUFF_SIZE
        local a    = (e.alpha or 0.2) * math.min(1, t / fade) * (1 - t)
        g.setColor(c[1], c[2], c[3], a)
        g.draw(puff, p.x, p.y, 0, s, s, PUFF_SIZE / 2, PUFF_SIZE / 2)
    end

    g.setBlendMode("add")
    for _, ember in ipairs(self.embers) do
        local c = ember.spec.ember_color or ember.spec.color or { 1, 0.5, 0.1 }
        g.setColor(c[1], c[2], c[3], 1 - ember.age / ember.life)
        g.rectangle("fill", math.floor(ember.x), math.floor(ember.y), 1, 1)
    end
    g.pop()
    return canvas
end

function CrashFX:_send(effect, img, level)
    local d      = self.data
    local glitch = d.glitch
    local zones  = {}
    for i = 1, HAZE_SLOTS do
        zones[i] = (self.spec.haze or {})[i] or { 0, 0, 0, 0 }
    end
    effect:send("size", { img:getDimensions() })
    effect:send("time", self.age)
    effect:send("seed", math.floor(self.age * (glitch.rate or 24)))
    effect:send("scan", glitch.lines or 0.3)
    effect:send("wave", { d.haze.amplitude or 0, math.max(1, d.haze.wavelength or 7), d.haze.speed or 3 })
    effect:send("glitch", { level, glitch.tear or 12, math.max(1, glitch.band or 3), glitch.noise or 0.7 })
    effect:send("haze", unpack(zones))
end

-- EXTRA (crash_cause): typed out centred at the foot of the picture.
function CrashFX:_draw_text(img, x, y, scale, alpha)
    local spec  = self.data.cause
    local shown = math.floor((self.age - (spec.delay or 1)) / (spec.char_time or 0.035))
    if shown <= 0 then return end
    local font   = Font.get(spec.font or "chars")
    local indent = math.floor((img:getWidth() - font:width(self.text)) / 2)
    font:print(self.text:sub(1, shown), x + indent * scale, y + (spec.y or 224) * scale,
        { scale = scale, color = { 1, 1, 1, alpha } })
end

-- Draws img at (x, y) with the given scale and overlay alpha, in place of the
-- overlay's own picture draw.
function CrashFX:draw(img, x, y, scale, alpha)
    local g = love.graphics
    if self.animated then   -- EXTRA (crash_fx)
        local canvas = self:_compose(img)
        local effect = get_shader()
        if effect then
            self:_send(effect, img, self:_glitch_level())
            g.setShader(effect)
        end
        g.setColor(1, 1, 1, alpha)
        g.draw(canvas, x, y, 0, scale, scale)
        g.setShader()
        local flash = self.data.entrance.flash or 0
        if self.age < flash then
            local c = self.data.entrance.flash_color or { 1, 1, 1 }
            g.setColor(c[1], c[2], c[3], alpha * (1 - self.age / flash) ^ 2)
            g.rectangle("fill", 0, 0, g.getDimensions())
        end
    else
        g.setColor(1, 1, 1, alpha)
        g.draw(img, x, y, 0, scale, scale)
    end
    if self.text then self:_draw_text(img, x, y, scale, alpha) end
    g.setColor(1, 1, 1)
end

return CrashFX
