local Class  = require "engine.core.class"
local Config = require "engine.core.config"
local json   = require "lib.json"

-- Gameplay post-processing: a filmic grade over the world view (warm tone,
-- saturation, S-curve contrast, local sharpening, bloom, vignette, animated
-- grain) plus softened ground shadows. Gameplay scenes bracket their
-- world pass with begin_world / end_world (the HUD and overlays stay outside, so
-- they are never filtered) and their shadow draws with begin_shadows /
-- end_shadows. Each pass costs nothing when its strengths are zero.
--
-- The look constants (what 100% of each strength means) and the presets live in
-- data/postfx.json; the per-strength sliders are Config keys (see STRENGTHS).
local PostFX = Class()

local DATA_PATH = "data/postfx.json"

-- Preset value key -> Config key.
PostFX.STRENGTHS = {
    grade        = "postfx_grade",
    contrast     = "postfx_contrast",
    sharpen      = "postfx_sharpen",
    bloom        = "postfx_bloom",
    vignette     = "postfx_vignette",
    grain        = "postfx_grain",
    soft_shadows = "postfx_soft_shadows",
}

local DEFAULT_LOOK = {
    exposure = 1, warmth = { 1, 1, 1 }, saturation = 0, contrast = 0, sharpen = 0,
    bloom_threshold = 1, bloom_gain = 0, bloom_tint = { 1, 1, 1 }, bloom_spread = 1,
    vignette = 0, vignette_power = 2, grain = 0, shadow_blur = 0, shadow_passes = 1, shadow_gain = 1,
}

local data

local function load_data()
    if data then return data end
    local raw = love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    decoded = (ok and type(decoded) == "table") and decoded or {}
    local look = {}
    for k, v in pairs(DEFAULT_LOOK) do
        look[k] = (decoded.look and decoded.look[k] ~= nil) and decoded.look[k] or v
    end
    data = { look = look, presets = decoded.presets or {} }
    return data
end

-- Preset rows for the settings page. "custom" is shown when the sliders match no
-- preset, but is skipped when cycling.
function PostFX.preset_choices()
    local out = {}
    for _, p in ipairs(load_data().presets) do
        out[#out + 1] = { label = p.label, value = p.name }
    end
    out[#out + 1] = { label = "CUSTOM", value = "custom", hidden = true }
    return out
end

function PostFX.apply_preset(name)
    for _, p in ipairs(load_data().presets) do
        if p.name == name then
            for key, config_key in pairs(PostFX.STRENGTHS) do
                Config[config_key] = p.values[key] or 0
            end
            return
        end
    end
end

-- The preset whose values the current sliders match, or "custom".
function PostFX.match_preset()
    for _, p in ipairs(load_data().presets) do
        local same = true
        for key, config_key in pairs(PostFX.STRENGTHS) do
            if math.abs((p.values[key] or 0) - Config[config_key]) > 1e-3 then
                same = false
                break
            end
        end
        if same then return p.name end
    end
    return "custom"
end

-- LOVE compiles OpenGL ES pixel shaders at mediump, 16-bit on many mobile GPUs:
-- too coarse for window-pixel coordinates (the grain hash bands) and one-texel
-- offsets on a wide canvas. Every shader here opts into highp where available.
-- LOVE declares effect() before this code at mediump, so the parameters keep
-- that precision and the texture coordinate is read from its highp varying.
local PRECISION = [[
#if defined(GL_ES) && defined(GL_FRAGMENT_PRECISION_HIGH)
precision highp float;
#endif
]]

local EFFECT = [[
vec4 effect(mediump vec4 color, Image tex, mediump vec2 texcoord, mediump vec2 screen) {
    vec2 uv = VaryingTexCoord.st;
]]

local LUMA = [[
float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
]]

-- Separable 9-tap gaussian in 5 bilinear taps; dir is the texel step times the spread.
local BLUR_SRC = PRECISION .. [[
uniform vec2 dir;
]] .. EFFECT .. [[
    vec4 s = Texel(tex, uv) * 0.227027;
    s += (Texel(tex, uv + dir * 1.384615) + Texel(tex, uv - dir * 1.384615)) * 0.316216;
    s += (Texel(tex, uv + dir * 3.230769) + Texel(tex, uv - dir * 3.230769)) * 0.070270;
    return s * color;
}
]]

-- Bright pass into a quarter-size target: four bilinear taps cover the 4x4 source
-- block, so thin bright sprites (tracers, rotor tips) are not skipped.
local BRIGHT_SRC = PRECISION .. LUMA .. [[
uniform vec2 texel;
uniform float threshold;
vec3 bright(vec3 c) {
    return c * clamp((luma(c) - threshold) / max(1.0 - threshold, 0.001), 0.0, 1.0);
}
]] .. EFFECT .. [[
    vec3 s = bright(Texel(tex, uv + vec2(-texel.x, -texel.y)).rgb)
           + bright(Texel(tex, uv + vec2( texel.x, -texel.y)).rgb)
           + bright(Texel(tex, uv + vec2(-texel.x,  texel.y)).rgb)
           + bright(Texel(tex, uv + vec2( texel.x,  texel.y)).rgb);
    return vec4(s * 0.25, 1.0);
}
]]

local SHADOW_SRC = PRECISION .. [[
uniform float gain;
]] .. EFFECT .. [[
    return vec4(0.0, 0.0, 0.0, min(1.0, Texel(tex, uv).a * gain) * color.a);
}
]]

local COMPOSITE_SRC = PRECISION .. LUMA .. [[
uniform Image bloom_tex;
uniform vec2 texel;
uniform vec4 viewport;
uniform float px_size;
uniform float grain_seed;
uniform float grade;
uniform float contrast;
uniform float sharpen;
uniform float bloom;
uniform float vignette;
uniform float grain;
uniform float exposure;
uniform vec3 warmth;
uniform float saturation;
uniform float contrast_gain;
uniform float sharpen_gain;
uniform float bloom_gain;
uniform vec3 bloom_tint;
uniform float vignette_gain;
uniform float vignette_power;
uniform float grain_gain;

// Sine-free hash (Dave Hoskins, hash13): stable at any pixel coordinate, unlike
// fract(sin(x) * k), whose float precision bands and coarsens as x grows.
float hash(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

]] .. EFFECT .. [[
    vec2 px = uv / texel;   // window pixel: the world canvas covers the window
    vec3 c = Texel(tex, uv).rgb;
    vec2 o = texel * px_size;
    vec3 n = Texel(tex, uv + vec2(o.x, 0.0)).rgb + Texel(tex, uv - vec2(o.x, 0.0)).rgb
           + Texel(tex, uv + vec2(0.0, o.y)).rgb + Texel(tex, uv - vec2(0.0, o.y)).rgb;
    c = max(c + (c - n * 0.25) * sharpen * sharpen_gain, 0.0);

    c *= mix(vec3(1.0), warmth * exposure, grade);
    float l = luma(c);
    c = clamp(l + (c - l) * (1.0 + saturation * grade), 0.0, 1.0);
    c = mix(c, c * c * (3.0 - 2.0 * c), contrast * contrast_gain);

    c += Texel(bloom_tex, uv).rgb * bloom_tint * bloom * bloom_gain;

    vec2 q = (px - viewport.xy) / viewport.zw * 2.0 - 1.0;
    c *= clamp(1.0 - vignette * vignette_gain * pow(length(q), vignette_power), 0.0, 1.0);

    float g = hash(vec3(floor((px - viewport.xy) / px_size), grain_seed)) - 0.5;
    c += g * grain * grain_gain * (1.0 - abs(luma(c) * 2.0 - 1.0) * 0.5);
    return vec4(clamp(c, 0.0, 1.0), 1.0);
}
]]

local GRAIN_FRAMES = 64   -- distinct grain patterns cycled at 24 per second

-- Unused uniforms are compiled out; sending one would raise.
local function send(shader, name, ...)
    if shader:hasUniform(name) then shader:send(name, ...) end
end

function PostFX:init()
    local g = love.graphics
    self.blur_shader      = g.newShader(BLUR_SRC)
    self.bright_shader    = g.newShader(BRIGHT_SRC)
    self.shadow_shader    = g.newShader(SHADOW_SRC)
    self.composite_shader = g.newShader(COMPOSITE_SRC)
    self.w, self.h        = 0, 0
    self.world_on         = false
    self.shadows_on       = false
end

local function new_canvas(w, h)
    local c = love.graphics.newCanvas(math.max(1, w), math.max(1, h))
    c:setFilter("linear", "linear")
    return c
end

function PostFX:_ensure(w, h)
    if self.w == w and self.h == h then return end
    self.w, self.h   = w, h
    self.world       = new_canvas(w, h)
    self.bloom_a     = new_canvas(math.floor(w / 4), math.floor(h / 4))
    self.bloom_b     = new_canvas(math.floor(w / 4), math.floor(h / 4))
    self.shadow      = new_canvas(w, h)
    self.shadow_a    = new_canvas(math.floor(w / 2), math.floor(h / 2))
    self.shadow_b    = new_canvas(math.floor(w / 2), math.floor(h / 2))
end

function PostFX:grading_active()
    if not Config.postfx_enabled then return false end
    return Config.postfx_grade > 0 or Config.postfx_contrast > 0 or Config.postfx_sharpen > 0
        or Config.postfx_bloom > 0 or Config.postfx_vignette > 0 or Config.postfx_grain > 0
end

function PostFX:soft_shadows_active()
    return Config.postfx_enabled and Config.postfx_soft_shadows > 0
end

-- Redirect drawing into a fresh full-window target, keeping the caller's
-- transform and scissor. Clears the whole target so split-screen halves never
-- bleed stale pixels into the blur passes.
local function redirect(canvas, r, g, b, a)
    local gfx = love.graphics
    local prev = gfx.getCanvas()
    gfx.setCanvas(canvas)
    local sx, sy, sw, sh = gfx.getScissor()
    gfx.setScissor()
    gfx.clear(r, g, b, a)
    if sx then gfx.setScissor(sx, sy, sw, sh) end
    return prev
end

-- Draw src into dst scaled to fill it, through shader (or none), replacing dst.
local function pass(dst, src, shader)
    local g = love.graphics
    g.setCanvas(dst)
    g.setShader(shader)
    g.draw(src, 0, 0, 0, dst:getWidth() / src:getWidth(), dst:getHeight() / src:getHeight())
end

function PostFX:begin_world()
    self.world_on = self:grading_active()
    if not self.world_on then return end
    self:_ensure(love.graphics.getDimensions())
    self.world_prev = redirect(self.world, 0, 0, 0, 1)
end

-- Composite the graded world onto the previous target inside the viewport rect
-- (window pixels; the vignette centres on it). The caller's scissor still clips.
function PostFX:end_world(vx, vy, vw, vh)
    if not self.world_on then return end
    self.world_on = false
    local g    = love.graphics
    local look = load_data().look
    local sx, sy, sw, sh = g.getScissor()
    g.setCanvas(self.world_prev)
    g.push("all")
    g.origin()
    g.setScissor()
    g.setColor(1, 1, 1, 1)
    g.setBlendMode("replace", "premultiplied")

    if Config.postfx_bloom > 0 then
        local bw, bh = self.bloom_a:getDimensions()
        send(self.bright_shader, "texel", { 1 / self.w, 1 / self.h })
        send(self.bright_shader, "threshold", look.bloom_threshold)
        pass(self.bloom_a, self.world, self.bright_shader)
        for _ = 1, 2 do
            send(self.blur_shader, "dir", { look.bloom_spread / bw, 0 })
            pass(self.bloom_b, self.bloom_a, self.blur_shader)
            send(self.blur_shader, "dir", { 0, look.bloom_spread / bh })
            pass(self.bloom_a, self.bloom_b, self.blur_shader)
        end
    end

    local s = self.composite_shader
    local px_size = math.max(1, math.floor(self.h / 540 + 0.5))
    send(s, "bloom_tex", self.bloom_a)
    send(s, "texel", { 1 / self.w, 1 / self.h })
    send(s, "viewport", { vx, vy, vw, vh })
    send(s, "px_size", px_size)
    send(s, "grain_seed", math.floor(love.timer.getTime() * 24) % GRAIN_FRAMES)
    send(s, "grade", Config.postfx_grade)
    send(s, "contrast", Config.postfx_contrast)
    send(s, "sharpen", Config.postfx_sharpen)
    send(s, "bloom", Config.postfx_bloom)
    send(s, "vignette", Config.postfx_vignette)
    send(s, "grain", Config.postfx_grain)
    send(s, "exposure", look.exposure)
    send(s, "warmth", look.warmth)
    send(s, "saturation", look.saturation)
    send(s, "contrast_gain", look.contrast)
    send(s, "sharpen_gain", look.sharpen)
    send(s, "bloom_gain", look.bloom_gain)
    send(s, "bloom_tint", look.bloom_tint)
    send(s, "vignette_gain", look.vignette)
    send(s, "vignette_power", look.vignette_power)
    send(s, "grain_gain", look.grain)
    g.setCanvas(self.world_prev)
    if sx then g.setScissor(sx, sy, sw, sh) end
    g.setShader(s)
    g.draw(self.world)
    g.pop()
end

-- Collect shadow silhouettes into their own target. Casters are merged with a
-- max blend, so overlapping shadows (a heli over its own smoke) do not darken
-- each other, as with one sun.
function PostFX:begin_shadows()
    self.shadows_on = self:soft_shadows_active()
    if not self.shadows_on then return end
    local g = love.graphics
    self:_ensure(g.getDimensions())
    self.shadow_prev = redirect(self.shadow, 0, 0, 0, 0)
    self.shadow_blend, self.shadow_alpha_mode = g.getBlendMode()
    g.setBlendMode("lighten", "premultiplied")
end

-- Blur the collected silhouettes at half size and lay them back over the ground,
-- darkened to keep their weight once spread out. The blur stays a true gaussian
-- by repeating narrow passes (spread capped at MAX_SPREAD texels) instead of
-- widening one pass, whose sparse taps would stamp offset copies of the shape.
local MAX_SPREAD = 1.5

function PostFX:end_shadows()
    if not self.shadows_on then return end
    self.shadows_on = false
    local g    = love.graphics
    local look = load_data().look
    local k    = Config.postfx_soft_shadows
    g.setBlendMode(self.shadow_blend, self.shadow_alpha_mode)
    local sx, sy, sw, sh = g.getScissor()
    g.setCanvas(self.shadow_prev)
    g.push("all")
    g.origin()
    g.setScissor()
    g.setColor(1, 1, 1, 1)
    g.setBlendMode("replace", "premultiplied")
    local hw, hh = self.shadow_a:getDimensions()
    local spread = math.min(MAX_SPREAD, look.shadow_blur * k * self.h / 1080)
    pass(self.shadow_a, self.shadow, nil)
    for _ = 1, look.shadow_passes do
        send(self.blur_shader, "dir", { spread / hw, 0 })
        pass(self.shadow_b, self.shadow_a, self.blur_shader)
        send(self.blur_shader, "dir", { 0, spread / hh })
        pass(self.shadow_a, self.shadow_b, self.blur_shader)
    end

    g.setCanvas(self.shadow_prev)
    if sx then g.setScissor(sx, sy, sw, sh) end
    g.setBlendMode("alpha")
    send(self.shadow_shader, "gain", 1 + (look.shadow_gain - 1) * k)
    g.setShader(self.shadow_shader)
    g.draw(self.shadow_a, 0, 0, 0, self.w / hw, self.h / hh)
    g.pop()
end

return PostFX
