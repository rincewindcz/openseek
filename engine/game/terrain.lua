-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local json    = require "lib.json"
local World   = require "engine.game.world"
local MapFile = require "engine.game.map_file"

-- The ground of a map that mixes art sets (map terrain, engine/game/map_file.lua):
-- a fill over the whole map, drawn in world units under the decals, in place
-- of the one ground colour. Each art pixel takes the colour of one art set:
-- the pixel is moved by a coarse tileable noise (warp, in cells), the cells
-- around where it lands weigh in by how near their middles are, each art
-- set's weight is moved by its own channel of a finer noise (amount) and by
-- an ordered dither shifted per art set (dither), and the heaviest wins. The
-- edge between two grounds so meanders through a cell and frays into a
-- dithered fringe, in hard pixels like the art. Tuning in data/terrain.json.
-- Presentation only; the game and the editor draw it alike.
local Terrain = Class()

local DATA_PATH = "data/terrain.json"
local ARTS      = 5    -- art sets 0 to 4
local ART_STEP  = 50   -- texel value per art digit in the cell image
local DEFAULTS  = {
    amount = 0.5,
    warp   = 0.8,
    fine   = 4,
    dither = 0.25,
    noise  = { size = 128, world = 512, seed = 7,
               octaves = { { cells = 4, weight = 0.5 }, { cells = 8, weight = 0.3 }, { cells = 16, weight = 0.2 } } },
}

-- World coordinates reach the map size, more than mediump holds to the pixel.
-- They come in as the texture coordinates of the fill: LOVE transforms the
-- vertices of a streamed draw on the CPU, so the vertex position may already
-- be in screen pixels.
local SHADER_SRC = [[
#if defined(GL_ES) && defined(GL_FRAGMENT_PRECISION_HIGH)
precision highp float;
#define WORLD_PRECISION highp
#elif defined(GL_ES)
#define WORLD_PRECISION mediump
#else
#define WORLD_PRECISION
#endif
varying WORLD_PRECISION vec2 world_pos;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    world_pos = VertexTexCoord.xy;
    return transform_projection * vertex_position;
}
#endif

#ifdef PIXEL
uniform Image cells;
uniform Image noise;
uniform float cell_count;
uniform float cell_size;
uniform float noise_world;
uniform float amount;
uniform float warp;
uniform float fine;
uniform float dither;
uniform vec3 colors[5];

// The art of grid cell c. The map is drawn from 0 to its size, so a cell
// past an edge is the first or last one: the last row and column of cells
// may reach past the edge, but no pixel lies past it.
float art_of(vec2 c) {
    vec2 w = mod(c, cell_count);
    return floor(Texel(cells, (w + 0.5) / cell_count).r * 255.0 / 50.0 + 0.5);
}

// The 4 x 4 ordered dither threshold of a pixel, 0 to 1.
float bayer2(vec2 a) {
    a = floor(a);
    return fract(dot(a, vec2(0.5, a.y * 0.75)));
}

float bayer4(vec2 a) {
    return bayer2(0.5 * a) * 0.25 + bayer2(a);
}

float weight_if(float art, float k, float w) {
    return step(abs(art - k), 0.5) * w;
}

#ifdef GL_ES
#define ARG_PRECISION mediump
#else
#define ARG_PRECISION
#endif
ARG_PRECISION vec4 effect(ARG_PRECISION vec4 color, Image tex, ARG_PRECISION vec2 texcoord, ARG_PRECISION vec2 screen) {
    vec2 p = floor(world_pos) + 0.5;
    vec2 uv = p / noise_world;
    vec4 coarse = Texel(noise, uv);
    vec2 g = p / cell_size + (coarse.rg - 0.5) * 2.0 * warp - 0.5;
    vec2 o = floor(g);
    vec2 f = g - o;
    float a00 = art_of(o);
    float a10 = art_of(o + vec2(1.0, 0.0));
    float a01 = art_of(o + vec2(0.0, 1.0));
    float a11 = art_of(o + vec2(1.0, 1.0));
    float w00 = (1.0 - f.x) * (1.0 - f.y);
    float w10 = f.x * (1.0 - f.y);
    float w01 = (1.0 - f.x) * f.y;
    float w11 = f.x * f.y;
    vec4 n1 = Texel(noise, uv * fine);
    float n2 = Texel(noise, uv * fine + vec2(0.5)).r;
    vec3 ground = colors[0];
    float best = -1000.0;
    for (int k = 0; k < 5; k++) {
        float fk = float(k);
        float w = weight_if(a00, fk, w00) + weight_if(a10, fk, w10) + weight_if(a01, fk, w01) + weight_if(a11, fk, w11);
        float jitter = k == 0 ? n1.r : (k == 1 ? n1.g : (k == 2 ? n1.b : (k == 3 ? n1.a : n2)));
        float score = w + (jitter - 0.5) * amount + (bayer4(p + vec2(fk, fk * 2.0)) - 0.5) * dither;
        if (w > 0.0 && score > best) {
            best   = score;
            ground = colors[k];
        }
    }
    return vec4(ground, 1.0) * color;
}
#endif
]]

local data_cache

local function load_data()
    if data_cache then return data_cache end
    local raw = love.filesystem.getInfo(DATA_PATH) and love.filesystem.read(DATA_PATH)
    local ok, decoded = pcall(json.decode, raw or "")
    data_cache = (ok and type(decoded) == "table") and decoded or {}
    for key, value in pairs(DEFAULTS) do
        if data_cache[key] == nil then data_cache[key] = value end
    end
    return data_cache
end

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

-- Tileable value noise, one field per channel, a few octaves on lattices
-- that divide the image. Drawn from a generator of its own, so the ground
-- looks the same every time and in the editor as in the game.
local function make_noise(spec)
    local rng  = love.math.newRandomGenerator(spec.seed)
    local size = spec.size
    local fields = {}
    for channel = 1, 4 do
        fields[channel] = {}
        for i, octave in ipairs(spec.octaves) do
            local lattice = {}
            for j = 0, octave.cells * octave.cells - 1 do lattice[j] = rng:random() end
            fields[channel][i] = lattice
        end
    end
    local function sample(lattice, cells, x, y)
        local fx, fy = x / size * cells, y / size * cells
        local ix, iy = math.floor(fx), math.floor(fy)
        local tx, ty = smoothstep(fx - ix), smoothstep(fy - iy)
        local x0, x1 = ix % cells, (ix + 1) % cells
        local y0, y1 = (iy % cells) * cells, ((iy + 1) % cells) * cells
        local top    = lattice[y0 + x0] + (lattice[y0 + x1] - lattice[y0 + x0]) * tx
        local bottom = lattice[y1 + x0] + (lattice[y1 + x1] - lattice[y1 + x0]) * tx
        return top + (bottom - top) * ty
    end
    local image = love.image.newImageData(size, size)
    image:mapPixel(function(x, y)
        local out = {}
        for channel = 1, 4 do
            local n = 0
            for i, octave in ipairs(spec.octaves) do
                n = n + octave.weight * sample(fields[channel][i], octave.cells, x, y)
            end
            out[channel] = n
        end
        return out[1], out[2], out[3], out[4]
    end)
    local noise = love.graphics.newImage(image)
    noise:setWrap("repeat", "repeat")
    return noise
end

function Terrain:init()
    self.grid      = nil    -- { cell, cells } shown, or nil for one ground colour
    self.key       = nil
    self.data      = nil    -- the cell image's pixels
    self.image     = nil
    self.shader    = nil
    self.noise     = nil
    self.fill      = nil    -- the map square, texture coordinates in world units
    self.fill_size = nil
end

-- Show grid (a map's terrain, or nil) over a map size px a side whose own
-- art set is art. stamp changes whenever the grid was changed in place.
function Terrain:set(grid, size, art, stamp)
    if not grid then
        self.grid, self.key = nil, nil
        return
    end
    local key = table.concat({ tostring(grid), size, tostring(art), tostring(stamp) }, ":")
    if key == self.key then return end
    self.key, self.grid, self.size, self.art = key, grid, size, art
    local n    = MapFile.terrain_side(grid.cell, size)
    local own  = tonumber(art) or 0
    local data = self.data
    if not data or data:getWidth() ~= n then data = love.image.newImageData(n, n) end
    local cells = grid.cells
    data:mapPixel(function(x, y)
        return (tonumber(cells[y * n + x + 1]) or own) * ART_STEP / 255, 0, 0, 1
    end)
    self.data = data
    if self.image and self.image:getWidth() == n then
        self.image:replacePixels(data)
    else
        self.image = love.graphics.newImage(data)
        self.image:setFilter("nearest", "nearest")
    end
end

-- Fill the map, (0, 0) to (size, size) in the current transform.
function Terrain:draw()
    if not self.grid then return end
    local g    = love.graphics
    local spec = load_data()
    if not self.shader then
        self.shader = g.newShader(SHADER_SRC)
        self.noise  = make_noise(spec.noise)
    end
    local colors = {}
    for k = 1, ARTS do colors[k] = World.art_ground(k - 1) end
    local shader = self.shader
    shader:send("cells", self.image)
    shader:send("noise", self.noise)
    shader:send("cell_count", MapFile.terrain_side(self.grid.cell, self.size))
    shader:send("cell_size", self.grid.cell)
    shader:send("noise_world", spec.noise.world)
    shader:send("amount", spec.amount)
    shader:send("warp", spec.warp)
    shader:send("fine", spec.fine)
    shader:send("dither", spec.dither)
    shader:send("colors", unpack(colors))
    local size = self.size
    if not self.fill or self.fill_size ~= size then
        self.fill = g.newMesh({
            { 0, 0, 0, 0 }, { size, 0, size, 0 }, { size, size, size, size }, { 0, size, 0, size },
        }, "fan", "static")
        self.fill_size = size
    end
    g.setShader(shader)
    g.setColor(1, 1, 1, 1)
    g.draw(self.fill)
    g.setShader()
end

return Terrain
