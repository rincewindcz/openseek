-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Catalog = require "engine.editor.catalog"
local Ops     = require "engine.editor.ops"
local View    = require "engine.editor.view"

-- The map editor's tools. Each is a table of handlers the editor scene calls
-- with itself (editor) and the pointer's world position (unwrapped: a point past
-- the seam stays past it): press, drag, release for the left button, cancel
-- for the right button and Esc, keypressed, and draw for its overlay inside
-- the world pass. Tool state lives on editor.work, reset when the tool changes.
local Tools = {}

local DRAG_START  = 3     -- screen px the pointer travels before a press becomes a drag
local HANDLE_GRAB = 7     -- screen px around a route or line point that grab it
local SEG_GRAB    = 5
local DOUBLE_TIME = 0.35
local HALF_STEP_TAN = math.tan(math.rad(22.5))   -- between two rays 45 degrees apart

local ROUTE_KINDS = { tank = true, truck = true }

Tools.ORDER = { "select", "place", "scatter", "erase", "route", "line" }

local function shift_down()
    return love.keyboard.isDown("lshift", "rshift")
end

local function ctrl_down()
    return love.keyboard.isDown("lctrl", "rctrl")
end

-- With Ctrl held, (x, y) moved onto the nearest ray from the anchor at a
-- multiple of 45 degrees, as a drawing program constrains a segment. anchor
-- is a map point { x, y }; the result lies on the pointer's own copy of the map.
local function constrain(editor, x, y, anchor)
    if not (anchor and ctrl_down()) then return x, y end
    local dx, dy = editor.doc:delta(x, y, anchor[1], anchor[2])
    local ax, ay = math.abs(dx), math.abs(dy)
    if ay < ax * HALF_STEP_TAN then
        dy = 0
    elseif ax < ay * HALF_STEP_TAN then
        dx = 0
    else
        local d = math.floor((ax + ay) / 2 + 0.5)
        dx, dy = dx < 0 and -d or d, dy < 0 and -d or d
    end
    return anchor[1] + dx, anchor[2] + dy
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
    local work = { x0 = wx, y0 = wy, x1 = wx, y1 = wy, dx = 0, dy = 0 }
    if top then
        work.mode     = "move"
        work.hits     = hits
        work.was_held = editor.selection:has(top)
        if shift_down() then
            if work.was_held then editor.selection:remove(whole(editor, top)) else editor.selection:add(whole(editor, top)) end
            work.mode = nil
        elseif not work.was_held then
            editor.selection:replace(whole(editor, top))
        end
    else
        work.mode = "box"
        if not shift_down() then editor.selection:clear() end
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
        work.dx, work.dy = dx, dy
    end
end

function Select.release(editor)
    local work = editor.work
    editor.work = nil
    if not work or not work.mode then return end
    if work.mode == "move" then
        if work.moving then
            editor.doc:record_move(editor.selection.list, work.dx, work.dy)
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
    -- Box: every pickable object whose anchor lies inside.
    local doc = editor.doc
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
end

function Select.cancel(editor)
    local work = editor.work
    if work and work.mode == "move" and work.moving then
        editor.doc:move(editor.selection.list, -work.dx, -work.dy, true)
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
    local part = entry.parts[entry.main]
    local info = Catalog.type_info({ from = part.from, class = part.class, sprite = part.sprite })
    local step = math.max(info.w, info.h, 4)
    if editor.grid.snap then step = math.ceil(step / editor.grid.step) * editor.grid.step end
    return step
end

local function place_at(editor, wx, wy)
    local entry = editor.placing
    local x, y  = editor:snap(wx, wy)
    Ops.place(editor.doc, entry, x, y)
    editor.work.last_x, editor.work.last_y = x, y
end

function Place.press(editor, wx, wy)
    if not editor.placing then
        editor:say("PICK AN OBJECT IN THE OBJECTS LIST FIRST")
        return
    end
    editor.work = { spacing = entry_spacing(editor, editor.placing) }
    editor.doc:begin("PLACE " .. editor.placing.label)
    place_at(editor, wx, wy)
end

function Place.drag(editor, wx, wy)
    local work = editor.work
    if not work or not editor.placing or editor.placing.home then return end
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

function Place.draw(editor)
    local entry = editor.placing
    if not entry or not editor.hover_world then return end
    local x, y = editor:snap(editor.hover_world[1], editor.hover_world[2])
    for _, part in ipairs(entry.parts) do
        local info = Catalog.type_info({ from = part.from, class = part.class, sprite = part.sprite })
        View.draw_object({ info = function() return info end }, { x = x, y = y }, 0.6)
    end
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

-- routes and ground lines: polylines edited point by point

local function shapes_of(editor, kind)
    return kind == "route" and editor.doc.map.routes or editor.doc.map.lines
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
    if kind == "route" then
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

    function tool.press(editor, wx, wy)
        local x, y = editor:snap(wx, wy)
        local size = editor.doc:size()
        local work = editor.work
        if work and work.points then
            local now  = love.timer.getTime()
            local last = work.points[#work.points]
            x, y = constrain(editor, x, y, last)
            if now - (work.clicked or 0) < DOUBLE_TIME and last[1] == x % size and last[2] == y % size then
                finish_shape(editor, kind)
                return
            end
            work.points[#work.points + 1] = { x % size, y % size }
            work.clicked = now
            return
        end
        local hover = poly_hover(editor, kind, wx, wy)
        if hover then
            editor.shape = hover.shape
            local points = copy_points(hover.shape.points)
            local index  = hover.index
            if hover.segment then
                index = index + 1
                table.insert(points, index, { x % size, y % size })
            end
            editor.work = { edit = hover.shape, before = hover.shape.points, edited = points, index = index,
                        inserted = hover.segment }
            hover.shape.points = points
            return
        end
        editor.shape = nil
        editor.work  = { points = { { x % size, y % size } }, clicked = love.timer.getTime() }
    end

    function tool.drag(editor, wx, wy)
        local work = editor.work
        if not (work and work.edit) then return end
        local x, y = editor:snap(wx, wy)
        local size = editor.doc:size()
        -- Ctrl: at a multiple of 45 degrees from the point before (or after).
        x, y = constrain(editor, x, y, work.edited[work.index - 1] or work.edited[work.index + 1])
        work.edited[work.index] = { x % size, y % size }
        work.moved = true
    end

    function tool.release(editor)
        local work = editor.work
        if not (work and work.edit) then return end
        editor.work = nil
        work.edit.points = work.before
        if work.moved or work.inserted then
            editor.doc:set_points(work.edit, work.edited, nil, kind == "route" and "EDIT ROUTE" or "EDIT LINE")
        end
    end

    function tool.cancel(editor)
        local work = editor.work
        if work and work.points then
            finish_shape(editor, kind)
        elseif work and work.edit then
            work.edit.points = work.before
            editor.work = nil
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
            table.remove(work.points)
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
                if kind == "route" then editor.doc:remove_route(shape) else editor.doc:remove_line(shape) end
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
            g.setColor(c[1], c[2], c[3], 1)
            g.setLineWidth(1.5 / z)
            local points = work.points
            for i = 1, #points - 1 do
                g.line(points[i][1], points[i][2], points[i + 1][1], points[i + 1][2])
            end
            if editor.hover_world then
                local x, y = editor:snap(editor.hover_world[1], editor.hover_world[2])
                local last = points[#points]
                x, y = constrain(editor, x, y, last)
                local dx, dy = editor.doc:delta(x, y, last[1], last[2])
                g.setColor(c[1], c[2], c[3], 0.6)
                g.line(last[1], last[2], last[1] + dx, last[2] + dy)
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

-- objective place: where a "get to a place" objective is met. Not on the tool
-- strip either; the OBJECTIVES page of the map settings hands over to it.

local Spot = { id = "spot", icon = "pin", label = "OBJECTIVE" }

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

Tools.defs = { select = Select, place = Place, scatter = Scatter, erase = Erase, route = Route, line = Line,
               card = Card, spot = Spot }

Tools.ROUTE_KINDS = ROUTE_KINDS

return Tools
