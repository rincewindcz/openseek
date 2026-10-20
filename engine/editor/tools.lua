-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Entity   = require "engine.game.entity"
local Roads    = require "engine.game.roads"
local MapFile  = require "engine.game.map_file"
local Catalog  = require "engine.editor.catalog"
local Document = require "engine.editor.document"
local Generate = require "engine.editor.generate"
local Ops      = require "engine.editor.ops"
local View     = require "engine.editor.view"

-- The map editor's tools. Each is a table of handlers the editor scene calls
-- with itself (editor) and the pointer's world position (unwrapped: a point past
-- the seam stays past it): press, drag, release for the left button, cancel
-- for the right button and Esc, keypressed, and draw for its overlay inside
-- the world pass (once per map copy in view for a tool with `poly` set). Tool
-- state lives on editor.work, reset when the tool changes.
local Tools = {}

local DRAG_START  = 3     -- screen px the pointer travels before a press becomes a drag
local HANDLE_GRAB = 7     -- screen px around a route or line point that grab it
local SEG_GRAB    = 5
local DOUBLE_TIME = 0.35
local HALF_STEP_TAN = math.tan(math.rad(22.5))   -- between two rays 45 degrees apart

local ROUTE_KINDS = { tank = true, truck = true }

Tools.ORDER = { "select", "place", "scatter", "erase", "ground", "route", "line", "road", "measure" }

local function shift_down()
    return love.keyboard.isDown("lshift", "rshift")
end

local function ctrl_down()
    return love.keyboard.isDown("lctrl", "rctrl")
end

-- With Ctrl held, (x, y) moved onto the nearest ray from the anchor at a
-- multiple of 45 degrees, as a drawing program constrains a segment. anchor
-- is a map point { x, y }; the result lies on the pointer's own copy of the map.
local function on_ray(dx, dy)
    local ax, ay = math.abs(dx), math.abs(dy)
    if ay < ax * HALF_STEP_TAN then return dx, 0 end
    if ax < ay * HALF_STEP_TAN then return 0, dy end
    local d = math.floor((ax + ay) / 2 + 0.5)
    return dx < 0 and -d or d, dy < 0 and -d or d
end

local function constrain(editor, x, y, anchor)
    if not (anchor and ctrl_down()) then return x, y end
    local dx, dy = on_ray(editor.doc:delta(x, y, anchor[1], anchor[2]))
    return anchor[1] + dx, anchor[2] + dy
end

-- What an armed kind sees (the faint ring) and where it fires (the strong
-- one), around (x, y).
function Tools.draw_ranges(kind_name, x, y)
    local td = Entity.type_for(kind_name)
    if not (td.armed and (td.detection_radius or 0) > 0) then return end
    local g = love.graphics
    g.setColor(1, 0.4, 0.3, 0.5)
    g.circle("line", x, y, td.detection_radius, 64)
    if (td.attack_range or 0) > 0 then
        g.setColor(1, 0.4, 0.3, 0.9)
        g.circle("line", x, y, td.attack_range, 64)
    end
end

-- An object with what is placed with it, unless single parts are being picked.
local function whole(editor, o)
    if editor.parts then return { o } end
    return editor.doc:members(o)
end

-- select

local Select = { id = "select", icon = "select", label = "SELECT", key = "v",
                 tip = "SELECT AND MOVE (V)" }

function Select.press(editor, wx, wy)
    local hits = editor.view:pick(editor.doc, wx, wy, function(o, info) return editor:pickable(o, info) end)
    local top  = hits[1]
    local road = not top and editor:road_at(wx, wy) or nil
    local work = { x0 = wx, y0 = wy, x1 = wx, y1 = wy, dx = 0, dy = 0 }
    local selection = editor.selection
    if top or road then
        work.mode     = "move"
        work.hits     = hits
        work.was_held = top and selection:has(top) or (road ~= nil and selection:has_road(road))
        if shift_down() then
            if top and work.was_held then selection:remove(whole(editor, top))
            elseif top then selection:add(whole(editor, top))
            elseif work.was_held then selection:remove_roads({ road })
            else selection:add_roads({ road }) end
            work.mode = nil
        elseif not work.was_held then
            if top then selection:replace(whole(editor, top)) else selection:replace({}, { road }) end
        end
    else
        work.mode = "box"
        if not shift_down() then selection:clear() end
    end
    editor.work = work
end

function Select.drag(editor, wx, wy)
    local work = editor.work
    if not work or not work.mode then return end
    work.x1, work.y1 = wx, wy
    if work.mode ~= "move" then return end
    local z = editor.view:zoom()
    if not work.moving and math.max(math.abs(wx - work.x0), math.abs(wy - work.y0)) * z < DRAG_START then return end
    work.moving = true
    local dx, dy = editor:snap_delta(wx - work.x0, wy - work.y0)
    -- Ctrl keeps the move on one axis.
    if ctrl_down() then
        if math.abs(dx) >= math.abs(dy) then dy = 0 else dx = 0 end
    end
    if dx ~= work.dx or dy ~= work.dy then
        editor.doc:move(editor.selection.list, dx - work.dx, dy - work.dy, true)
        editor.doc:move_roads(editor.selection.roads, dx - work.dx, dy - work.dy, true)
        work.dx, work.dy = dx, dy
    end
end

function Select.release(editor)
    local work = editor.work
    editor.work = nil
    if not work or not work.mode then return end
    local doc = editor.doc
    if work.mode == "move" then
        if work.moving then
            doc:begin("MOVE")
            doc:record_move(editor.selection.list, work.dx, work.dy)
            doc:record_road_move(editor.selection.roads, work.dx, work.dy)
            doc:commit()
        elseif work.was_held and #work.hits > 1 then
            -- A second click on a selected object reaches the one under it.
            local next_hit = work.hits[1]
            for i, o in ipairs(work.hits) do
                if editor.selection:has(o) then next_hit = work.hits[i % #work.hits + 1] end
            end
            editor.selection:replace(whole(editor, next_hit))
        end
        return
    end
    -- Box: every pickable object whose anchor lies inside, and every road
    -- that lies inside with all its points.
    local cx, cy = (work.x0 + work.x1) / 2, (work.y0 + work.y1) / 2
    local hw, hh = math.abs(work.x1 - work.x0) / 2, math.abs(work.y1 - work.y0) / 2
    if hw * editor.view:zoom() < DRAG_START and hh * editor.view:zoom() < DRAG_START then return end
    local found = {}
    for _, o in ipairs(doc.map.objects) do
        local dx, dy = doc:delta(o.x, o.y, cx, cy)
        if math.abs(dx) <= hw and math.abs(dy) <= hh and editor:pickable(o, doc:info(o)) then
            for _, member in ipairs(whole(editor, o)) do found[#found + 1] = member end
        end
    end
    editor.selection:add(found)
    local roads = {}
    for _, road in ipairs(editor:roads_pickable() and doc.map.roads or {}) do
        local inside = #road.points > 0
        for _, p in ipairs(road.points) do
            local dx, dy = doc:delta(p[1], p[2], cx, cy)
            if math.abs(dx) > hw or math.abs(dy) > hh then inside = false end
        end
        if inside then roads[#roads + 1] = road end
    end
    editor.selection:add_roads(roads)
end

function Select.cancel(editor)
    local work = editor.work
    if work and work.mode == "move" and work.moving then
        editor.doc:move(editor.selection.list, -work.dx, -work.dy, true)
        editor.doc:move_roads(editor.selection.roads, -work.dx, -work.dy, true)
    elseif not work then
        editor.selection:clear()
    end
    editor.work = nil
end

function Select.draw(editor)
    local work = editor.work
    if not (work and work.mode == "box") then return end
    local g = love.graphics
    local c = editor.kit.theme.accent
    local x, y = math.min(work.x0, work.x1), math.min(work.y0, work.y1)
    local w, h = math.abs(work.x1 - work.x0), math.abs(work.y1 - work.y0)
    g.setColor(c[1], c[2], c[3], 0.12)
    g.rectangle("fill", x, y, w, h)
    g.setColor(c[1], c[2], c[3], 0.9)
    g.rectangle("line", x, y, w, h)
end

-- place

local Place = { id = "place", icon = "place", label = "PLACE", key = "p",
                tip = "PLACE THE PICKED OBJECT (P)" }

local function entry_spacing(editor, entry)
    local info = Catalog.type_info(Catalog.part_type(entry.parts[entry.main]))
    local step = math.max(info.w, info.h, 4)
    if editor.grid.snap then step = math.ceil(step / editor.grid.step) * editor.grid.step end
    return step
end

local function place_at(editor, wx, wy)
    local entry = editor.placing
    local x, y  = editor:snap(wx, wy)
    if entry.prefab then
        Ops.paste(editor.doc, entry.prefab, x, y)
    else
        Ops.place(editor.doc, entry, x, y)
    end
    editor.work.last_x, editor.work.last_y = x, y
end

function Place.press(editor, wx, wy)
    local entry = editor.placing
    if not entry then
        editor:say("PICK AN OBJECT IN THE OBJECTS LIST FIRST")
        return
    end
    editor.work = { spacing = entry.parts and entry_spacing(editor, entry) or nil }
    editor.doc:begin("PLACE " .. entry.label)
    place_at(editor, wx, wy)
end

function Place.drag(editor, wx, wy)
    local work = editor.work
    if not work or not editor.placing or not work.spacing or editor.placing.home then return end
    local x, y = editor:snap(wx, wy)
    local dx, dy = x - work.last_x, y - work.last_y
    local dist   = math.sqrt(dx * dx + dy * dy)
    -- Lay a row along the drag at the object's own pitch.
    while dist >= work.spacing do
        local k = work.spacing / dist
        place_at(editor, work.last_x + dx * k, work.last_y + dy * k)
        dx, dy = x - work.last_x, y - work.last_y
        dist   = math.sqrt(dx * dx + dy * dy)
    end
end

function Place.release(editor)
    if editor.work then editor.doc:commit() end
    editor.work = nil
end

function Place.cancel(editor)
    if editor.work then
        editor.doc:commit()
        editor.work = nil
        return
    end
    editor:set_tool("select")
end

local function ghost(map_type, x, y)
    local info = Catalog.type_info(map_type)
    View.draw_object({ info = function() return info end }, { x = x, y = y }, 0.6)
    return info
end

-- What is about to be placed, under the pointer: a prefab with its roads, an
-- object with the reach of its guns.
function Place.draw(editor)
    local entry = editor.placing
    if not entry or not editor.hover_world then return end
    local g    = love.graphics
    local x, y = editor:snap(editor.hover_world[1], editor.hover_world[2])
    if entry.prefab then
        local doc = editor.doc
        for _, s in ipairs(Roads.build(Ops.lay_roads(doc, entry.prefab, x, y), doc:size()).segments) do
            local dx, dy = doc:delta(s.x1, s.y1, x, y)
            g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255, 0.7)
            g.line(x + dx, y + dy, x + dx + s.x2 - s.x1, y + dy + s.y2 - s.y1)
        end
        for _, item in ipairs(entry.prefab.items) do ghost(item.map_type, x + item.dx, y + item.dy) end
        return
    end
    -- A hangar hut goes over the tank inside it.
    local huts = {}
    for _, part in ipairs(entry.parts) do
        local map_type = Catalog.part_type(part)
        if Catalog.is_hut(Catalog.type_info(map_type)) then
            huts[#huts + 1] = map_type
        else
            Tools.draw_ranges(ghost(map_type, x, y).kind_name, x, y)
        end
    end
    for _, map_type in ipairs(huts) do ghost(map_type, x, y) end
end

-- scatter

local Scatter = { id = "scatter", icon = "scatter", label = "SCATTER", key = "b",
                  tip = "SCATTER THE TICKED OBJECTS WITH A BRUSH (B)" }

local function stamp(editor, wx, wy)
    local doc, brush = editor.doc, editor.scatter
    local entries = brush.list
    if #entries == 0 then return end
    for _ = 1, brush.density do
        local turn, dist = math.random() * 2 * math.pi, brush.radius * math.sqrt(math.random())
        local x = math.floor(wx + math.cos(turn) * dist + 0.5)
        local y = math.floor(wy + math.sin(turn) * dist + 0.5)
        local free = true
        if brush.gap > 0 then
            doc:each_in(x % doc:size(), y % doc:size(), x % doc:size(), y % doc:size(), brush.gap, function(o)
                local dx, dy = o.x - x % doc:size(), o.y - y % doc:size()
                if dx * dx + dy * dy < brush.gap * brush.gap then free = false end
            end)
        end
        if free then Ops.place(doc, entries[math.random(#entries)], x, y) end
    end
end

function Scatter.press(editor, wx, wy)
    if #editor.scatter.list == 0 then
        editor:say("TICK ONE OR MORE OBJECTS IN THE OBJECTS LIST FIRST")
        return
    end
    editor.work = { last_x = wx, last_y = wy }
    editor.doc:begin("SCATTER")
    stamp(editor, wx, wy)
end

function Scatter.drag(editor, wx, wy)
    local work = editor.work
    if not work then return end
    local dx, dy = wx - work.last_x, wy - work.last_y
    local reach = editor.scatter.radius * 0.5
    if dx * dx + dy * dy >= reach * reach then
        stamp(editor, wx, wy)
        work.last_x, work.last_y = wx, wy
    end
end

function Scatter.release(editor)
    if editor.work then editor.doc:commit() end
    editor.work = nil
end

function Scatter.cancel(editor)
    if editor.work then Scatter.release(editor) else editor:set_tool("select") end
end

local function draw_brush(editor, radius)
    if not editor.hover_world then return end
    local g = love.graphics
    local c = editor.kit.theme.accent
    g.setColor(c[1], c[2], c[3], 0.9)
    g.circle("line", editor.hover_world[1], editor.hover_world[2], radius, 48)
    g.setColor(c[1], c[2], c[3], 0.08)
    g.circle("fill", editor.hover_world[1], editor.hover_world[2], radius, 48)
end

function Scatter.draw(editor)
    draw_brush(editor, editor.scatter.radius)
end

-- erase

local Erase = { id = "erase", icon = "erase", label = "ERASE", key = "e",
                tip = "ERASE WITH A BRUSH (E)" }

local SOFT_LAYERS = { scenery = true, ground = true }

local function erase_at(editor, wx, wy)
    local doc, radius = editor.doc, editor.erase.radius
    local size = doc:size()
    local x, y = wx % size, wy % size
    local gone = {}
    doc:each_in(x, y, x, y, radius, function(o)
        local info = doc:info(o)
        local dx, dy = o.x - x, o.y - y
        if dx * dx + dy * dy <= radius * radius and not editor:hidden(o, info)
        and (editor.erase.all or SOFT_LAYERS[info.layer]) then
            for _, member in ipairs(whole(editor, o)) do gone[#gone + 1] = member end
        end
    end)
    if #gone > 0 then doc:remove(gone) end
end

function Erase.press(editor, wx, wy)
    editor.work = {}
    editor.doc:begin("ERASE")
    erase_at(editor, wx, wy)
end

function Erase.drag(editor, wx, wy)
    if editor.work then erase_at(editor, wx, wy) end
end

function Erase.release(editor)
    if editor.work then editor.doc:commit() end
    editor.work = nil
    editor.selection:prune(editor.doc)
end

function Erase.cancel(editor)
    if editor.work then Erase.release(editor) else editor:set_tool("select") end
end

function Erase.draw(editor)
    draw_brush(editor, editor.erase.radius)
end

-- ground: paints the terrain, cells of the ground of another art set, with a
-- brush. scenery: "keep" what lies on the cells it paints, "clear" the
-- scenery and ground marks off them, or "replace" them with the ground cover
-- of the art set painted. One stroke is one undo step.

local Ground = { id = "ground", icon = "ground", label = "GROUND", key = "t",
                 tip = "PAINT THE GROUND OF AN ART SET (T)" }

local function paint_at(editor, wx, wy)
    local doc     = editor.doc
    local brush   = editor.ground
    local size    = doc:size()
    local cell    = doc.map.terrain and doc.map.terrain.cell or brush.cell
    local n       = MapFile.terrain_side(cell, size)
    local radius  = brush.radius
    local indices = { MapFile.terrain_index(cell, size, wx, wy) }
    -- The last row and column may be cut short by the edge: a cell's middle
    -- is the middle of what lies inside the map, and the brush reaches over
    -- the seam into the copies around.
    local function middle(k)
        return (k * cell + math.min((k + 1) * cell, size)) / 2
    end
    wx, wy = wx % size, wy % size
    for oy = -size, size, size do
        for ox = -size, size, size do
            local lx, ly = wx - ox, wy - oy
            for row = math.max(0, math.floor((ly - radius) / cell)), math.min(n - 1, math.floor((ly + radius) / cell)) do
                for column = math.max(0, math.floor((lx - radius) / cell)),
                             math.min(n - 1, math.floor((lx + radius) / cell)) do
                    local dx, dy = middle(column) - lx, middle(row) - ly
                    if dx * dx + dy * dy <= radius * radius then indices[#indices + 1] = row * n + column + 1 end
                end
            end
        end
    end
    local art = brush.art or doc:art()
    doc:paint_terrain(indices, art, cell)
    if brush.scenery ~= "keep" then
        -- Only the cells this stroke reaches for the first time: what it laid
        -- stays while the brush passes over it again.
        local work = editor.work
        work.cells = work.cells or {}
        local painted, fresh, seen, gone = {}, {}, {}, {}
        for _, k in ipairs(indices) do
            if not work.cells[k] then
                work.cells[k], painted[k] = true, true
                fresh[#fresh + 1] = k
            end
        end
        for oy = -size, size, size do
            for ox = -size, size, size do
                doc:each_in(wx - ox, wy - oy, wx - ox, wy - oy, radius + cell, function(o)
                    local info = doc:info(o)
                    if not seen[o] and painted[MapFile.terrain_index(cell, size, o.x, o.y)]
                    and SOFT_LAYERS[info.layer] and not editor:hidden(o, info) then
                        for _, member in ipairs(whole(editor, o)) do
                            if not seen[member] then
                                seen[member] = true
                                gone[#gone + 1] = member
                            end
                        end
                    end
                end)
            end
        end
        if #gone > 0 then doc:remove(gone) end
        if brush.scenery == "replace" and #fresh > 0 then
            if work.stage == nil then work.stage = Generate.stage_for(doc, art) or false end
            local objects = Generate.cells(doc, work.stage, fresh, cell)
            if #objects > 0 then doc:add(objects) end
        end
    end
end

function Ground.press(editor, wx, wy)
    editor.work = {}
    editor.doc:begin("GROUND")
    paint_at(editor, wx, wy)
end

function Ground.drag(editor, wx, wy)
    if editor.work then paint_at(editor, wx, wy) end
end

function Ground.release(editor)
    if editor.work then editor.doc:commit() end
    editor.work = nil
    editor.selection:prune(editor.doc)
end

function Ground.cancel(editor)
    if editor.work then Ground.release(editor) else editor:set_tool("select") end
end

function Ground.draw(editor)
    draw_brush(editor, editor.ground.radius)
end

-- routes, ground lines and roads: polylines edited point by point

local EDIT_LABELS   = { route = "EDIT ROUTE", line = "EDIT LINE", road = "EDIT ROAD" }
local EXTEND_LABELS = { route = "EXTEND ROUTE", line = "EXTEND LINE", road = "EXTEND ROAD" }

local function shapes_of(editor, kind)
    local map = editor.doc.map
    if kind == "route" then return map.routes end
    return kind == "road" and map.roads or map.lines
end

-- A road runs level or upright: (x, y) moved onto the nearer of the two from
-- the anchor.
local function square(editor, x, y, anchor)
    if not anchor then return x, y end
    local dx, dy = editor.doc:delta(x, y, anchor[1], anchor[2])
    if math.abs(dx) >= math.abs(dy) then return anchor[1] + dx, anchor[2] end
    return anchor[1], anchor[2] + dy
end

-- A road point on or near another road is put on that road's centre line, so
-- the two join. With an anchor the point stays on its leg from it, and only a
-- road across that leg takes it. skip is the road being edited.
local function join(editor, x, y, anchor, skip)
    local doc     = editor.doc
    local level   = anchor and anchor[2] == y
    local upright = anchor and not level
    local best_x, best_y, best_d = x, y, nil
    for _, road in ipairs(doc.map.roads) do
        local reach = (tonumber(road.width) or 0) / 2 + Catalog.data().roads.join
        for i = 1, (road ~= skip) and #road.points - 1 or 0 do
            -- The pointer and the leg's far end, both from the leg's near end.
            local a, b   = road.points[i], road.points[i + 1]
            local px, py = doc:delta(x, y, a[1], a[2])
            local bx, by = b[1] - a[1], b[2] - a[2]
            if by == 0 and not level and px >= math.min(0, bx) - reach and px <= math.max(0, bx) + reach then
                local d = math.abs(py)
                if d <= reach and (not best_d or d < best_d) then best_x, best_y, best_d = x, y - py, d end
            elseif bx == 0 and not upright and py >= math.min(0, by) - reach and py <= math.max(0, by) + reach then
                local d = math.abs(px)
                if d <= reach and (not best_d or d < best_d) then best_x, best_y, best_d = x - px, y, d end
            end
        end
    end
    return best_x, best_y
end

-- A road point whose leg from the anchor comes near the line of the road's
-- first point is put on that line, so the road can come back to where it
-- began and close as a ring.
local function meet_start(editor, x, y, anchor, first)
    if not (anchor and first) then return x, y end
    local reach  = Catalog.data().roads.join
    local dx, dy = editor.doc:delta(first[1], first[2], x, y)
    if y == anchor[2] and math.abs(dx) <= reach then return x + dx, y end
    if x == anchor[1] and math.abs(dy) <= reach then return x, y + dy end
    return x, y
end

-- Where a point of a shape goes for the pointer at (x, y): a route or line
-- point by the Ctrl constraint, a road point square to the anchor, onto the
-- line of the road's first point when near it and onto a road it meets.
local function settle(editor, kind, x, y, anchor, skip, first)
    if kind ~= "road" then return constrain(editor, x, y, anchor) end
    x, y = square(editor, x, y, anchor)
    x, y = meet_start(editor, x, y, anchor, first)
    return join(editor, x, y, anchor, skip)
end

-- The first point of the shape being drawn, once coming back to it would
-- close a ring.
local function ring_start(work)
    return #work.points >= 3 and work.points[1] or nil
end

local function copy_points(points)
    local out = {}
    for i, p in ipairs(points) do out[i] = { p[1], p[2] } end
    return out
end

-- The point or segment of a shape under a world position:
-- { shape, index } for a point, { shape, index, segment = true } for the
-- segment after point index.
local function poly_hover(editor, kind, wx, wy)
    local doc = editor.doc
    local z   = editor.view:zoom()
    local best, best_d = nil, HANDLE_GRAB / z
    for _, shape in ipairs(shapes_of(editor, kind)) do
        for i, p in ipairs(shape.points) do
            local dx, dy = doc:delta(wx, wy, p[1], p[2])
            local d = math.sqrt(dx * dx + dy * dy)
            if d < best_d then best, best_d = { shape = shape, index = i }, d end
        end
    end
    if best then return best end
    best_d = SEG_GRAB / z
    for _, shape in ipairs(shapes_of(editor, kind)) do
        for i = 1, #shape.points - 1 do
            local a, b = shape.points[i], shape.points[i + 1]
            local px, py = doc:delta(wx, wy, a[1], a[2])
            local sx, sy = b[1] - a[1], b[2] - a[2]
            local len2   = sx * sx + sy * sy
            if len2 > 0 then
                local k = math.max(0, math.min(1, (px * sx + py * sy) / len2))
                local dx, dy = px - sx * k, py - sy * k
                local d = math.sqrt(dx * dx + dy * dy)
                if d < best_d then best, best_d = { shape = shape, index = i, segment = true }, d end
            end
        end
    end
    return best
end

local function finish_shape(editor, kind)
    local work = editor.work
    editor.work = nil
    if not (work and work.points) or #work.points < 2 then return end
    local doc = editor.doc
    if work.extend then
        -- A shape carried on from one of its ends: the points drawn join it.
        if #work.points > work.keep then
            local points = work.points
            if work.reversed then
                points = {}
                for i = #work.points, 1, -1 do points[#points + 1] = work.points[i] end
            end
            doc:set_points(work.extend, points, nil, EXTEND_LABELS[kind])
        end
        editor.shape = work.extend
    elseif kind == "road" then
        local style = Catalog.road_style(doc:art())
        local function mark(part)
            return part and Catalog.part_type(part) or nil
        end
        editor.shape = doc:add_road({
            points = work.points, width = editor.road.width or style.width,
            pitch  = editor.road.marks and style.pitch or 0,
            edge   = { { unpack(style.edge[1]) }, { unpack(style.edge[2]) } },
            across = mark(style.across), down = mark(style.down),
        })
    elseif kind == "route" then
        doc:begin("ADD ROUTE")
        local route = doc:add_route(work.points)
        -- A route drawn for the selected units is theirs.
        local riders = {}
        for _, o in ipairs(editor.selection.list) do
            if ROUTE_KINDS[doc:info(o).kind_name] then riders[#riders + 1] = o end
        end
        doc:set_field(riders, "route", route.id)
        doc:commit()
        editor.shape = route
    else
        local line = { color = { editor.line_color[1], editor.line_color[2], editor.line_color[3] }, points = work.points }
        doc:add_line(line)
        editor.shape = line
    end
end

local function poly_tool(kind, def)
    local tool = def
    tool.poly  = true

    function tool.press(editor, wx, wy)
        local x, y = editor:snap(wx, wy)
        local size = editor.doc:size()
        local work = editor.work
        if work and work.points then
            local now  = love.timer.getTime()
            local last = work.points[#work.points]
            x, y = settle(editor, kind, x, y, last, work.extend, ring_start(work))
            x, y = Document.near(x, y, last, size)
            if now - (work.clicked or 0) < DOUBLE_TIME and last[1] == x and last[2] == y then
                finish_shape(editor, kind)
                return
            end
            work.points[#work.points + 1] = { x, y }
            work.clicked = now
            return
        end
        -- A click on a road's leg starts a road joined to it; Shift adds a point instead.
        local hover = poly_hover(editor, kind, wx, wy)
        if hover and kind == "road" and hover.segment and not shift_down() then hover = nil end
        if hover then
            editor.shape = hover.shape
            local points = copy_points(hover.shape.points)
            local index  = hover.index
            if hover.segment then
                -- A point added to a road lies on the leg it splits.
                local a, b = points[index], points[index + 1]
                x, y = Document.near(x, y, a, size)
                if kind == "road" and a[2] == b[2] then y = a[2] elseif kind == "road" and a[1] == b[1] then x = a[1] end
                index = index + 1
                table.insert(points, index, { x, y })
            end
            editor.work = { edit = hover.shape, before = hover.shape.points, edited = points, index = index,
                        origin = copy_points(points), inserted = hover.segment }
            hover.shape.points = points
            editor.doc:refresh()
            return
        end
        editor.shape = nil
        x, y = settle(editor, kind, x, y, nil)
        editor.work  = { points = { { x % size, y % size } }, clicked = love.timer.getTime() }
    end

    function tool.drag(editor, wx, wy)
        local work = editor.work
        if not (work and work.edit) then return end
        local x, y = editor:snap(wx, wy)
        local size = editor.doc:size()
        if kind == "road" then
            -- An end of a road joins another road, the two ends of a ring
            -- move as one, and the points beside the one dragged follow it, so
            -- the legs to them stay level or upright.
            local origin = work.origin
            local last   = #origin
            local ring   = last > 3 and origin[1][1] == origin[last][1] and origin[1][2] == origin[last][2]
            local moved  = { work.index }
            if ring and work.index == 1 then moved[2] = last
            elseif ring and work.index == last then moved[2] = 1
            elseif work.index == 1 or work.index == last then x, y = join(editor, x, y, nil, work.edit) end
            for _, index in ipairs(moved) do
                local here   = origin[index]
                local hx, hy = Document.near(x, y, here, size)
                for step = -1, 1, 2 do
                    local was = origin[index + step]
                    if was and was[2] == here[2] and was[1] ~= here[1] then
                        work.edited[index + step] = { was[1], hy }
                    elseif was and was[1] == here[1] and was[2] ~= here[2] then
                        work.edited[index + step] = { hx, was[2] }
                    end
                end
                work.edited[index] = { hx, hy }
            end
            x, y = Document.near(x, y, origin[work.index], size)
        else
            -- Ctrl: at a multiple of 45 degrees from the point before (or after).
            x, y = constrain(editor, x, y, work.edited[work.index - 1] or work.edited[work.index + 1])
            x, y = Document.near(x, y, work.origin[work.index], size)
        end
        work.edited[work.index] = { x, y }
        work.moved = true
        editor.doc:refresh()
    end

    function tool.release(editor)
        local work = editor.work
        if not (work and work.edit) then return end
        editor.work = nil
        work.edit.points = work.before
        editor.doc:refresh()
        if work.moved or work.inserted then
            editor.doc:set_points(work.edit, work.edited, nil, EDIT_LABELS[kind])
            return
        end
        -- A click on an end of a shape carries it on from there: the points
        -- clicked next are added to it. A ring has no end.
        local points = copy_points(work.before)
        local last   = #points
        local ring   = kind == "road" and last > 3 and points[1][1] == points[last][1] and points[1][2] == points[last][2]
        if ring or (work.index ~= 1 and work.index ~= last) then return end
        local reversed = work.index == 1 and last > 1
        if reversed then
            for i = 1, math.floor(last / 2) do points[i], points[last + 1 - i] = points[last + 1 - i], points[i] end
        end
        editor.work = { points = points, extend = work.edit, reversed = reversed, keep = last,
                        clicked = love.timer.getTime() }
    end

    function tool.cancel(editor)
        local work = editor.work
        if work and work.points then
            finish_shape(editor, kind)
        elseif work and work.edit then
            work.edit.points = work.before
            editor.work = nil
            editor.doc:refresh()
        else
            editor:set_tool("select")
        end
    end

    function tool.keypressed(editor, key)
        local work = editor.work
        if key == "return" or key == "kpenter" then
            if work and work.points then finish_shape(editor, kind) end
            return true
        elseif key == "backspace" and work and work.points then
            if #work.points > (work.keep or 0) then table.remove(work.points) end
            if #work.points == 0 then editor.work = nil end
            return true
        elseif key == "delete" and not work then
            local hover = editor.hover_world and poly_hover(editor, kind, editor.hover_world[1], editor.hover_world[2])
            if hover and not hover.segment and #hover.shape.points > 2 then
                local points = copy_points(hover.shape.points)
                table.remove(points, hover.index)
                editor.doc:set_points(hover.shape, points, nil, "DELETE POINT")
            elseif (hover and hover.shape) or editor.shape then
                local shape = hover and hover.shape or editor.shape
                if kind == "route" then editor.doc:remove_route(shape)
                elseif kind == "road" then editor.doc:remove_road(shape)
                else editor.doc:remove_line(shape) end
                editor.shape = nil
            end
            return true
        end
        return false
    end

    function tool.draw(editor)
        local g    = love.graphics
        local z    = editor.view:zoom()
        local c    = editor.kit.theme.accent
        local work = editor.work
        local hover = editor.hover_world and not work and poly_hover(editor, kind, editor.hover_world[1], editor.hover_world[2])
        for _, shape in ipairs(shapes_of(editor, kind)) do
            local chosen = shape == editor.shape
            for i, p in ipairs(shape.points) do
                local hot = hover and hover.shape == shape and hover.index == i and not hover.segment
                local r   = (hot and 5 or 3.5) / z
                g.setColor(0, 0, 0, 0.8)
                g.rectangle("fill", p[1] - r - 1 / z, p[2] - r - 1 / z, r * 2 + 2 / z, r * 2 + 2 / z)
                if hot or chosen then g.setColor(c[1], c[2], c[3], 1) else g.setColor(1, 1, 1, 0.9) end
                g.rectangle("fill", p[1] - r, p[2] - r, r * 2, r * 2)
            end
        end
        if work and work.points then
            local points = work.points
            local ahead
            if editor.hover_world then
                local x, y = editor:snap(editor.hover_world[1], editor.hover_world[2])
                local last = points[#points]
                x, y = settle(editor, kind, x, y, last, work.extend, ring_start(work))
                local dx, dy = editor.doc:delta(x, y, last[1], last[2])
                ahead = { last[1] + dx, last[2] + dy }
            end
            -- A road shows the ground it will take.
            if kind == "road" then
                local half = (work.extend and work.extend.width or editor.road.width
                    or Catalog.road_style(editor.doc:art()).width) / 2
                g.setColor(c[1], c[2], c[3], 0.16)
                for i = 1, #points - (ahead and 0 or 1) do
                    local a, b = points[i], points[i + 1] or ahead
                    g.rectangle("fill", math.min(a[1], b[1]) - half, math.min(a[2], b[2]) - half,
                        math.abs(b[1] - a[1]) + half * 2, math.abs(b[2] - a[2]) + half * 2)
                end
            end
            g.setColor(c[1], c[2], c[3], 1)
            g.setLineWidth(1.5 / z)
            for i = 1, #points - 1 do
                g.line(points[i][1], points[i][2], points[i + 1][1], points[i + 1][2])
            end
            if ahead then
                local last = points[#points]
                g.setColor(c[1], c[2], c[3], 0.6)
                g.line(last[1], last[2], ahead[1], ahead[2])
            end
            for _, p in ipairs(points) do
                g.setColor(c[1], c[2], c[3], 1)
                g.rectangle("fill", p[1] - 3 / z, p[2] - 3 / z, 6 / z, 6 / z)
            end
        end
    end

    return tool
end

local Route = poly_tool("route", { id = "route", icon = "route", label = "ROUTE", key = "r",
    tip = "DRAW AND EDIT PATROL ROUTES (R)" })
local Line = poly_tool("line", { id = "line", icon = "line", label = "LINE", key = "l",
    tip = "DRAW AND EDIT GROUND LINES (L)" })
local Road = poly_tool("road", { id = "road", icon = "road", label = "ROAD", key = "o",
    tip = "DRAW AND EDIT ROADS (O)" })

-- measure: a line dragged over the map, read as a distance and as travel time

local Measure = { id = "measure", icon = "measure", label = "MEASURE", key = "u",
                  tip = "MEASURE A DISTANCE AND THE TIME IT TAKES (U)" }

function Measure.press(editor, wx, wy)
    local x, y = editor:snap(wx, wy)
    editor.measure = { x0 = x, y0 = y, x1 = x, y1 = y }
    editor.work    = {}
end

function Measure.drag(editor, wx, wy)
    local span = editor.measure
    if not (editor.work and span) then return end
    local x, y = editor:snap(wx, wy)
    local dx, dy = x - span.x0, y - span.y0
    if ctrl_down() then dx, dy = on_ray(dx, dy) end
    span.x1, span.y1 = span.x0 + dx, span.y0 + dy
end

function Measure.release(editor)
    editor.work = nil
end

function Measure.cancel(editor)
    if editor.measure then editor.measure = nil else editor:set_tool("select") end
    editor.work = nil
end

function Measure.draw(editor)
    local span = editor.measure
    if not span then return end
    local g = love.graphics
    local z = editor.view:zoom()
    local c = editor.kit.theme.accent
    -- The line was dragged on one copy of the map; it shows on the one in view.
    local ox, oy = editor.doc:delta(span.x0, span.y0, editor.view.x, editor.view.y)
    local x0, y0 = editor.view.x + ox, editor.view.y + oy
    local x1, y1 = x0 + span.x1 - span.x0, y0 + span.y1 - span.y0
    g.setLineWidth(3 / z)
    g.setColor(0, 0, 0, 0.7)
    g.line(x0, y0, x1, y1)
    g.setLineWidth(1.5 / z)
    g.setColor(c[1], c[2], c[3], 1)
    g.line(x0, y0, x1, y1)
    for _, p in ipairs({ { x0, y0 }, { x1, y1 } }) do
        g.setColor(0, 0, 0, 0.7)
        g.circle("fill", p[1], p[2], 4.5 / z, 12)
        g.setColor(c[1], c[2], c[3], 1)
        g.circle("fill", p[1], p[2], 3 / z, 12)
    end
end

-- briefing picture: the square of the map a briefing card shows. Not on the
-- tool strip; the BRIEFING page of the map settings hands over to it.

local Card = { id = "card", icon = "image", label = "PICTURE" }

function Card.press(editor, wx, wy)
    local pick = editor.card_pick
    if pick then
        local size = editor.doc:size()
        local x, y = editor:snap(wx, wy)
        editor:set_card(pick.slot, { kind = "view", x = x % size, y = y % size, size = pick.size,
                                     label = pick.label })
    end
    editor:finish_card_pick()
end

function Card.drag() end
function Card.release() end

function Card.cancel(editor)
    editor:finish_card_pick()
end

function Card.draw(editor)
    local pick = editor.card_pick
    if not (pick and editor.hover_world) then return end
    local g = love.graphics
    local c = editor.kit.theme.accent
    local x, y = editor:snap(editor.hover_world[1], editor.hover_world[2])
    local half = pick.size / 2
    g.setColor(0, 0, 0, 0.7)
    g.rectangle("line", x - half - 1, y - half - 1, pick.size + 2, pick.size + 2)
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("line", x - half, y - half, pick.size, pick.size)
end

-- place pick: where a "get to a place" objective is met, or where an event's
-- shelling lands (Editor:pick_place). Not on the tool strip either; the
-- dialogs hand over to it.

local Spot = { id = "spot", icon = "pin", label = "PLACE" }

function Spot.press(editor, wx, wy)
    editor:finish_place_pick(wx, wy)
end

function Spot.drag() end
function Spot.release() end

function Spot.cancel(editor)
    editor:finish_place_pick()
end

function Spot.draw(editor)
    local pick = editor.place_pick
    if not (pick and editor.hover_world) then return end
    local g = love.graphics
    local c = editor.kit.theme.accent
    local x, y = editor:snap(editor.hover_world[1], editor.hover_world[2])
    g.setColor(c[1], c[2], c[3], 0.12)
    g.circle("fill", x, y, pick.radius, 48)
    g.setColor(c[1], c[2], c[3], 1)
    g.circle("line", x, y, pick.radius, 48)
end

Tools.defs = { select = Select, place = Place, scatter = Scatter, erase = Erase, ground = Ground, route = Route, line = Line,
               road = Road, measure = Measure, card = Card, spot = Spot }

Tools.ROUTE_KINDS = ROUTE_KINDS

return Tools
