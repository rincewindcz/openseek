-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class   = require "engine.core.class"
local World   = require "engine.game.world"
local Terrain = require "engine.game.terrain"
local Catalog = require "engine.editor.catalog"

-- The editor's view of a map: a free camera over the wrapped world inside a
-- rect of the window, and the drawing of the document under it (ground,
-- decals, ground lines, objects, routes), north up and unlit. It draws from
-- the document, never from a loaded World, so nothing has to be compiled
-- while editing.
local View = Class()

local ZOOMS        = { 0.125, 0.1875, 0.25, 0.375, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8 }
local DEFAULT_ZOOM = 9       -- index into ZOOMS: 2x
local CULL_MARGIN  = 96      -- world px around the view an anchor may lie and still show
local DIM_OUTSIDE  = 0.35    -- shade over the map copies past the seam
local MISSING      = { 1, 0.2, 0.8 }

View.ZOOMS = ZOOMS

function View:init()
    self.x, self.y  = 2048, 2048   -- world point at the middle of the rect
    self.zoom_index = DEFAULT_ZOOM
    self.rect       = { x = 0, y = 0, w = 800, h = 600 }   -- window pixels
    self.drawn      = { decals = {}, objects = {} }         -- what the last draw showed, in draw order
    self.terrain    = Terrain:new()
end

local region_terrain = nil   -- the terrain fill of View.draw_region

-- The ground of the map's terrain over (0, 0) to (size, size) of the current
-- transform; nothing on a map of one ground.
local function draw_terrain(terrain, doc)
    terrain:set(doc.map.terrain, doc:size(), doc:art(), doc.terrain_revision)
    terrain:draw()
end

function View:draw_terrain(doc)
    draw_terrain(self.terrain, doc)
end

function View:zoom()
    return ZOOMS[self.zoom_index]
end

function View:center()
    return self.rect.x + self.rect.w / 2, self.rect.y + self.rect.h / 2
end

function View:contains(sx, sy)
    local r = self.rect
    return sx >= r.x and sx < r.x + r.w and sy >= r.y and sy < r.y + r.h
end

-- Window pixel -> world point (not wrapped: a point past the seam stays past it).
function View:to_world(sx, sy)
    local cx, cy = self:center()
    local z = self:zoom()
    return self.x + (sx - cx) / z, self.y + (sy - cy) / z
end

function View:to_screen(wx, wy)
    local cx, cy = self:center()
    local z = self:zoom()
    return cx + (wx - self.x) * z, cy + (wy - self.y) * z
end

function View:wrap(size)
    self.x, self.y = self.x % size, self.y % size
end

function View:pan(dx, dy, size)
    local z = self:zoom()
    self.x, self.y = self.x - dx / z, self.y - dy / z
    self:wrap(size)
end

-- Step the zoom, keeping the world point under (sx, sy) where it is.
function View:zoom_by(steps, sx, sy, size)
    local index = math.max(1, math.min(#ZOOMS, self.zoom_index + steps))
    if index == self.zoom_index then return end
    local cx, cy = self:center()
    sx, sy = sx or cx, sy or cy
    local wx, wy = self:to_world(sx, sy)
    self.zoom_index = index
    local z = self:zoom()
    self.x, self.y = wx - (sx - cx) / z, wy - (sy - cy) / z
    self:wrap(size)
end

-- Back to the zoom the editor opens with, keeping the middle of the view.
function View:reset_zoom()
    self.zoom_index = DEFAULT_ZOOM
end

-- The closest zoom that shows the whole map, centred on it.
function View:fit(size)
    local side = math.min(self.rect.w, self.rect.h)
    local index = 1
    for i, z in ipairs(ZOOMS) do
        if size * z <= side then index = i end
    end
    self.zoom_index = index
    self:look_at(size / 2, size / 2, size)
end

function View:look_at(wx, wy, size)
    self.x, self.y = wx % size, wy % size
end

-- World rect in view: x0, y0, x1, y1.
function View:bounds()
    local z = self:zoom()
    local hw, hh = self.rect.w / 2 / z, self.rect.h / 2 / z
    return self.x - hw, self.y - hh, self.x + hw, self.y + hh
end

-- Offsets of the map copies the view overlaps.
function View:tiles(size)
    local x0, y0, x1, y1 = self:bounds()
    local out = {}
    for ky = math.floor((y0 - CULL_MARGIN) / size), math.floor((y1 + CULL_MARGIN) / size) do
        for kx = math.floor((x0 - CULL_MARGIN) / size), math.floor((x1 + CULL_MARGIN) / size) do
            out[#out + 1] = { ox = kx * size, oy = ky * size }
        end
    end
    return out
end

-- Run fn under the world transform, clipped to the rect.
function View:world_pass(fn)
    local g = love.graphics
    local r = self.rect
    local cx, cy = self:center()
    g.push("all")
    g.setScissor(r.x, r.y, r.w, r.h)
    g.translate(math.floor(cx), math.floor(cy))
    g.scale(self:zoom())
    g.translate(-self.x, -self.y)
    fn()
    g.pop()
end

local function by_depth(a, b)
    if a.y ~= b.y then return a.y < b.y end
    if a.x ~= b.x then return a.x < b.x end
    return a.id < b.id
end

-- Draw order of a pass: on one spot a hangar hut draws above the tank
-- inside it, as in play.
local function sort_pass(doc, list)
    table.sort(list, function(a, b)
        if a.y == b.y and a.x == b.x then
            local hut_a, hut_b = Catalog.is_hut(doc:info(a)), Catalog.is_hut(doc:info(b))
            if hut_a ~= hut_b then return hut_b end
        end
        return by_depth(a, b)
    end)
end

-- The objects in view of one map copy, split into the ground pass and the
-- object pass, each in draw order. hidden(o, info) leaves an object out.
function View:collect(doc, tile, hidden)
    local x0, y0, x1, y1 = self:bounds()
    local decals, objects = {}, {}
    doc:each_in(x0 - tile.ox, y0 - tile.oy, x1 - tile.ox, y1 - tile.oy, CULL_MARGIN, function(o)
        local info = doc:info(o)
        if not hidden(o, info) then
            local list = info.kind_name == "ground_decal" and decals or objects
            list[#list + 1] = o
        end
    end)
    table.sort(decals, by_depth)
    sort_pass(doc, objects)
    return decals, objects
end

local function draw_object(doc, o, alpha)
    local g    = love.graphics
    local info = doc:info(o)
    if info.img then
        Catalog.draw_sprite(info, o.x, o.y, 1, alpha)
    else
        -- No sprite: a post the helicopter system flies from, or a type this
        -- pack cannot resolve.
        local c = info.ok and { 1, 0.85, 0.3 } or MISSING
        g.setColor(c[1], c[2], c[3], (alpha or 1) * 0.9)
        g.polygon("line", o.x, o.y - 7, o.x + 7, o.y, o.x, o.y + 7, o.x - 7, o.y)
        g.line(o.x - 3, o.y, o.x + 3, o.y)
        g.line(o.x, o.y - 3, o.x, o.y + 3)
    end
end

View.draw_object = draw_object

-- The roads as the phase will show them: centre marks, then the borders.
local function draw_roads(doc)
    local g     = love.graphics
    local built = doc:built_roads()
    g.setColor(1, 1, 1, 1)
    for _, mark in ipairs(built.marks) do
        local info = Catalog.type_info(mark.type)
        if info.img then g.draw(info.img, mark.x, mark.y, 0, 1, 1, -info.ox, -info.oy) end
    end
    for _, s in ipairs(built.segments) do
        g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255, 1)
        g.line(s.x1, s.y1, s.x2, s.y2)
    end
end

-- Draw the map. opts: hidden(o, info), show_lines, show_roads, grid (step or nil).
function View:draw(doc, opts)
    local g    = love.graphics
    local r    = self.rect
    local size = doc:size()
    local ground = World.art_ground(doc:art())
    g.setColor(ground[1], ground[2], ground[3], 1)
    g.rectangle("fill", r.x, r.y, r.w, r.h)

    self.drawn = { decals = {}, objects = {} }
    self:world_pass(function()
        g.setLineStyle("rough")
        local z = self:zoom()
        for _, tile in ipairs(self:tiles(size)) do
            local decals, objects = self:collect(doc, tile, opts.hidden)
            g.push()
            g.translate(tile.ox, tile.oy)
            self:draw_terrain(doc)
            for _, o in ipairs(decals) do draw_object(doc, o) end
            g.setLineWidth(math.max(1, 1 / z))
            if opts.show_roads then draw_roads(doc) end
            if opts.show_lines then
                for _, line in ipairs(doc.map.lines) do
                    local c = line.color
                    g.setColor(c[1] / 255, c[2] / 255, c[3] / 255, 1)
                    for i = 1, #line.points - 1 do
                        g.line(line.points[i][1], line.points[i][2], line.points[i + 1][1], line.points[i + 1][2])
                    end
                end
            end
            for _, o in ipairs(objects) do draw_object(doc, o) end
            -- The copies past the seam are the same map again: shade them.
            if tile.ox ~= 0 or tile.oy ~= 0 then
                g.setColor(0, 0, 0, DIM_OUTSIDE)
                g.rectangle("fill", 0, 0, size, size)
            end
            local drawn = self.drawn
            for _, o in ipairs(decals) do drawn.decals[#drawn.decals + 1] = o end
            for _, o in ipairs(objects) do drawn.objects[#drawn.objects + 1] = o end
            g.pop()
        end

        if opts.grid then
            local step = opts.grid
            while step * z < 8 do step = step * 2 end
            local x0, y0, x1, y1 = self:bounds()
            g.setLineWidth(1 / z)
            for x = math.floor(x0 / step) * step, x1, step do
                g.setColor(0, 0, 0, (x % (step * 4) == 0) and 0.22 or 0.1)
                g.line(x, y0, x, y1)
            end
            for y = math.floor(y0 / step) * step, y1, step do
                g.setColor(0, 0, 0, (y % (step * 4) == 0) and 0.22 or 0.1)
                g.line(x0, y, x1, y)
            end
        end

        -- The seam: where the map ends and wraps.
        g.setLineWidth(1 / z)
        g.setColor(1, 0.8, 0.2, 0.55)
        g.rectangle("line", 0, 0, size, size)
    end)
    g.setColor(1, 1, 1, 1)
end

-- The objects under a world point among those the last draw showed: every one
-- whose sprite box holds the point, topmost first.
function View:pick(doc, wx, wy, pickable)
    local size = doc:size()
    wx, wy = wx % size, wy % size
    local hits, seen = {}, {}
    local function test(list)
        for i = #list, 1, -1 do
            local o    = list[i]
            local info = doc:info(o)
            local x, y = o.x + info.ox, o.y + info.oy
            if not seen[o] and wx >= x and wx < x + info.w and wy >= y and wy < y + info.h
            and pickable(o, info) then
                seen[o] = true
                hits[#hits + 1] = o
            end
        end
    end
    test(self.drawn.objects)
    test(self.drawn.decals)
    return hits
end

-- Draw a square of the map, `size` world pixels a side with (x, y) at its
-- middle, into the rect (px, py, pw, ph) of the current render target: ground,
-- decals, ground lines and objects, as the editor shows them.
function View.draw_region(doc, x, y, size, px, py, pw, ph)
    local g      = love.graphics
    local period = doc:size()
    local ground = World.art_ground(doc:art())
    local half   = size / 2
    g.push("all")
    g.setScissor(px, py, pw, ph)
    g.setColor(ground[1], ground[2], ground[3], 1)
    g.rectangle("fill", px, py, pw, ph)
    g.translate(px + pw / 2, py + ph / 2)
    g.scale(pw / size, ph / size)
    g.translate(-x, -y)
    g.setLineStyle("rough")
    g.setLineWidth(1)
    -- The square may reach over the seam: every map copy it touches is drawn.
    for ky = math.floor((y - half - CULL_MARGIN) / period), math.floor((y + half + CULL_MARGIN) / period) do
        for kx = math.floor((x - half - CULL_MARGIN) / period), math.floor((x + half + CULL_MARGIN) / period) do
            local ox, oy = kx * period, ky * period
            local decals, objects = {}, {}
            doc:each_in(x - half - ox, y - half - oy, x + half - ox, y + half - oy, CULL_MARGIN, function(o)
                local list = doc:info(o).kind_name == "ground_decal" and decals or objects
                list[#list + 1] = o
            end)
            table.sort(decals, by_depth)
            sort_pass(doc, objects)
            g.push()
            g.translate(ox, oy)
            region_terrain = region_terrain or Terrain:new()
            draw_terrain(region_terrain, doc)
            for _, o in ipairs(decals) do draw_object(doc, o) end
            draw_roads(doc)
            for _, line in ipairs(doc.map.lines) do
                local c = line.color
                g.setColor(c[1] / 255, c[2] / 255, c[3] / 255, 1)
                for i = 1, #line.points - 1 do
                    g.line(line.points[i][1], line.points[i][2], line.points[i + 1][1], line.points[i + 1][2])
                end
            end
            for _, o in ipairs(objects) do draw_object(doc, o) end
            g.pop()
        end
    end
    g.pop()
end

function View:state()
    return { x = math.floor(self.x), y = math.floor(self.y), zoom = self.zoom_index }
end

function View:restore(state, size)
    if type(state) ~= "table" then return end
    self.x = tonumber(state.x) or self.x
    self.y = tonumber(state.y) or self.y
    self.zoom_index = math.max(1, math.min(#ZOOMS, math.floor(tonumber(state.zoom) or self.zoom_index)))
    self:wrap(size)
end

return View
