local Class = require "engine.core.class"
local Scene = require "engine.core.scene"
local Audio = require "engine.core.audio"

-- Test scene reached from the overview/editor (F10): every imported sound in
-- data/sounds.json laid out by category as clickable rows. Click a row to play
-- it (a ▶ triangle); the sounding row shows a ■ stop square and a click stops
-- it. Categories pack left-to-right into columns so they fit any window height.
local SoundGallery = Class(Scene)

local COL_W    = 300
local COL_GAP  = 16
local MARGIN_X = 20
local TOP      = 44
local BOTTOM   = 14
local HEAD_H   = 24
local ROW_H    = 18
local CAT_GAP  = 14

local C = {
    bg     = { 0.06, 0.06, 0.09, 1    },
    header = { 0.6,  0.9,  1,    1    },
    cat    = { 1.0,  0.78, 0.20, 1    },
    row    = { 0.78, 0.82, 0.9,  1    },
    hover  = { 1,    1,    1,    0.09 },
    play   = { 0.35, 0.9,  0.4,  1    },
    play_bg= { 0.2,  0.5,  0.3,  0.35 },
    stop   = { 1,    0.45, 0.4,  1    },
    tri    = { 0.55, 0.6,  0.7,  1    },
}

-- Pack the category blocks into fixed-width columns, wrapping to a new column
-- (reprinting the header) whenever a row would overflow the visible height, so
-- everything fits without maximizing the window. Returns the drawable/clickable
-- row records.
function SoundGallery:_layout()
    local _, screen_h = love.graphics.getDimensions()
    local col_bottom  = screen_h - BOTTOM
    local rows = {}
    local x, y = MARGIN_X, TOP

    local function new_column()
        x = x + COL_W + COL_GAP
        y = TOP
    end

    for _, cat in ipairs(Audio.categories()) do
        if y > TOP and y + HEAD_H + ROW_H > col_bottom then new_column() end
        rows[#rows + 1] = { header = cat.title, x = x, y = y }
        y = y + HEAD_H
        for _, item in ipairs(cat.items or {}) do
            if y + ROW_H > col_bottom then
                new_column()
                rows[#rows + 1] = { header = cat.title .. " (cont.)", x = x, y = y }
                y = y + HEAD_H
            end
            rows[#rows + 1] = { name = item.name, label = item.label, x = x, y = y }
            y = y + ROW_H
        end
        y = y + CAT_GAP
    end
    return rows
end

function SoundGallery:enter()
    self.rows  = self:_layout()
    self.hover = nil
end

function SoundGallery:leave()
    Audio.stop_all()
end

function SoundGallery:_row_at(mx, my)
    for _, r in ipairs(self.rows or {}) do
        if r.name and mx >= r.x and mx <= r.x + COL_W and my >= r.y and my <= r.y + ROW_H then
            return r
        end
    end
end

function SoundGallery:mousemoved(x, y)
    self.hover = self:_row_at(x, y)
end

function SoundGallery:mousepressed(x, y)
    local r = self:_row_at(x, y)
    if not r then return end
    if Audio.is_playing(r.name) then Audio.stop(r.name) else Audio.play(r.name) end
end

function SoundGallery:keypressed(key)
    if key == "escape" or key == "f10" then self.app.scenes:switch("overview") end
end

function SoundGallery:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(C.bg)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(C.header)
    g.print("SOUND GALLERY  -  original SFX imported from the game.   Click to play / stop.   F10 / Esc: back", 10, 14)

    for _, r in ipairs(self.rows or {}) do
        if r.header then
            g.setColor(C.cat)
            g.print(r.header, r.x, r.y + 4)
            g.setColor(0.3, 0.32, 0.4, 1)
            g.rectangle("fill", r.x, r.y + HEAD_H - 4, COL_W - 8, 1)
        else
            local sounding = Audio.is_playing(r.name)
            if sounding then
                g.setColor(C.play_bg)
                g.rectangle("fill", r.x - 2, r.y - 1, COL_W - 4, ROW_H)
            elseif r == self.hover then
                g.setColor(C.hover)
                g.rectangle("fill", r.x - 2, r.y - 1, COL_W - 4, ROW_H)
            end
            -- play triangle / stop square glyph
            local gx, gy = r.x + 4, r.y + 3
            if sounding then
                g.setColor(C.stop)
                g.rectangle("fill", gx, gy, 9, 9)
            else
                g.setColor(C.tri)
                g.polygon("fill", gx, gy, gx, gy + 9, gx + 8, gy + 4.5)
            end
            g.setColor(sounding and C.play or C.row)
            g.print(r.label, r.x + 20, r.y)
        end
    end
    g.setColor(1, 1, 1)
end

return SoundGallery
