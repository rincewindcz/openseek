-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

-- The roads of a player-made map (the "roads" of engine/game/map_file.lua) as
-- what a stage holds for them: ground segments for the borders and decals for
-- the centre marks, the way the original stages lay out the roads of a base.
--
-- A road is a centre line of points with a width. It runs level or upright
-- only (the marks exist in those two directions): a leg between two points
-- that is neither goes level first, then upright. A road that ends where it
-- began is a ring. The borders are the outline of all the roads together, so
-- roads that touch are joined: a road ending on another opens the border it
-- meets, a crossing opens all four, a bend is closed around its corner. The
-- border above and to the left of a road takes the first of its two colours,
-- the one below and to the right the second.
local Roads = {}

local function half_of(road)
    return math.max(1, math.floor((tonumber(road.width) or 0) / 2))
end

-- The legs of every road: the centre line a leg marks (x0, y0, x1, y1 with
-- x0 <= x1 and y0 <= y1), whether it is level, and the rect it covers (left,
-- top, right, bottom), which reaches half a width past a corner to close it.
local function legs_of(roads)
    local legs = {}
    for _, road in ipairs(roads) do
        local half, path = half_of(road), {}
        for _, p in ipairs(road.points or {}) do
            local last = path[#path]
            if last and last[1] ~= p[1] and last[2] ~= p[2] then path[#path + 1] = { p[1], last[2] } end
            last = path[#path]
            if not last or last[1] ~= p[1] or last[2] ~= p[2] then path[#path + 1] = { p[1], p[2] } end
        end
        -- A road that comes back to where it started is a ring: its first
        -- corner is closed like the others.
        local ring = #path > 3 and path[1][1] == path[#path][1] and path[1][2] == path[#path][2]
        for i = 1, #path - 1 do
            local a, b  = path[i], path[i + 1]
            local level = a[2] == b[2]
            local lead  = (i > 1 or ring) and half or 0
            local tail  = (i < #path - 1 or ring) and half or 0
            local leg   = { road = road, level = level,
                            x0 = math.min(a[1], b[1]), y0 = math.min(a[2], b[2]),
                            x1 = math.max(a[1], b[1]), y1 = math.max(a[2], b[2]) }
            -- lo / hi: how far the rect runs past the leg's lower and upper end.
            local forward = level and a[1] < b[1] or (not level and a[2] < b[2])
            local lo, hi  = forward and lead or tail, forward and tail or lead
            if level then
                leg.left, leg.right = leg.x0 - lo, leg.x1 + hi
                leg.top, leg.bottom = leg.y0 - half, leg.y0 + half
            else
                leg.left, leg.right = leg.x0 - half, leg.x0 + half
                leg.top, leg.bottom = leg.y0 - lo, leg.y1 + hi
            end
            legs[#legs + 1] = leg
        end
    end
    return legs
end

local function sorted_unique(values)
    table.sort(values)
    local out, index = {}, {}
    for _, v in ipairs(values) do
        if out[#out] ~= v then
            out[#out + 1] = v
            index[v]      = #out
        end
    end
    return out, index
end

local function same_color(a, b)
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- The outline of the legs' rects taken together, as segments. The rects are
-- laid on the grid of their own edges; a grid edge with road on one side only
-- is border, and border running on in one colour is one segment.
local function outline(legs, segments)
    local xs, ys = {}, {}
    for _, leg in ipairs(legs) do
        xs[#xs + 1], xs[#xs + 2] = leg.left, leg.right
        ys[#ys + 1], ys[#ys + 2] = leg.top, leg.bottom
    end
    local x_at, y_at
    xs, x_at = sorted_unique(xs)
    ys, y_at = sorted_unique(ys)
    local nx = #xs
    local cells = {}   -- (row - 1) * nx + column -> the first leg covering that cell
    for _, leg in ipairs(legs) do
        for row = y_at[leg.top], y_at[leg.bottom] - 1 do
            for column = x_at[leg.left], x_at[leg.right] - 1 do
                local key = (row - 1) * nx + column
                cells[key] = cells[key] or leg
            end
        end
    end
    local function cell(column, row)
        if column < 1 or row < 1 or column >= nx or row >= #ys then return nil end
        return cells[(row - 1) * nx + column]
    end

    -- Borders along a grid line of `count` steps: sides(i) gives the legs
    -- before and after the line at step i, emit(from, to, color) takes a run.
    local function runs(count, sides, emit)
        local start, color
        for i = 1, count + 1 do
            local before, after = nil, nil
            if i <= count then before, after = sides(i) end
            local here
            if after and not before then here = after.road.edge[1]
            elseif before and not after then here = before.road.edge[2] end
            if start and not (here and same_color(here, color)) then
                emit(start, i, color)
                start = nil
            end
            if here and not start then start, color = i, here end
        end
    end
    for row = 1, #ys do
        runs(nx - 1, function(i) return cell(i, row - 1), cell(i, row) end, function(from, to, color)
            segments[#segments + 1] = { x1 = xs[from], y1 = ys[row], x2 = xs[to], y2 = ys[row], color = color }
        end)
    end
    for column = 1, nx do
        runs(#ys - 1, function(i) return cell(column - 1, i), cell(column, i) end, function(from, to, color)
            segments[#segments + 1] = { x1 = xs[column], y1 = ys[from], x2 = xs[column], y2 = ys[to], color = color }
        end)
    end
end

-- The centre marks of a leg, evenly spaced at about the road's pitch. None
-- where a leg running the other way covers the spot: a crossing, a bend, the
-- mouth of a road that runs on past this one.
local function marks_of(leg, legs, size, marks)
    local road  = leg.road
    local pitch = tonumber(road.pitch) or 0
    local mark  = leg.level and road.across or road.down
    if pitch <= 0 or not mark then return end
    local length = (leg.x1 - leg.x0) + (leg.y1 - leg.y0)
    local count  = math.floor(length / pitch + 0.5)
    for k = 1, count do
        local along = math.floor(length * (k - 0.5) / count + 0.5)
        local x, y  = leg.x0 + (leg.level and along or 0), leg.y0 + (leg.level and 0 or along)
        local clear = true
        for _, other in ipairs(legs) do
            if other.level ~= leg.level and x > other.left and x < other.right and y > other.top and y < other.bottom then
                clear = false
                break
            end
        end
        if clear then marks[#marks + 1] = { x = x % size, y = y % size, type = mark } end
    end
end

-- roads -> { segments = { { x1, y1, x2, y2, color } }, marks = { { x, y, type } },
-- legs }: the border lines, the centre mark decals (type: the map type of a
-- mark, the road's `across` or `down`) and the legs they were built from (each
-- { road, left, top, right, bottom }, the ground a leg covers). size is the
-- map's wrap period.
function Roads.build(roads, size)
    local legs  = legs_of(roads or {})
    local built = { segments = {}, marks = {}, legs = legs }
    if #legs == 0 then return built end
    outline(legs, built.segments)
    for _, leg in ipairs(legs) do marks_of(leg, legs, size, built.marks) end
    return built
end

return Roads
