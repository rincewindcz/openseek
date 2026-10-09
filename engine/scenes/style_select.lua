-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class         = require "engine.core.class"
local Scene         = require "engine.core.scene"
local Gameplay      = require "engine.scenes.gameplay"
local Font          = require "engine.core.font"
local Assets        = require "engine.core.assets"
local Audio         = require "engine.core.audio"
local Config        = require "engine.core.config"
local InputFrame    = require "engine.core.input_frame"
local Layout        = require "engine.ui.layout"
local Pointer       = require "engine.ui.pointer"
local TouchControls = require "engine.ui.touch_controls"
local Style         = require "engine.game.style"
local Difficulty    = require "engine.game.difficulty"

-- Style selection screen: the player picks a game style (engine/game/style.lua),
-- a difficulty and the controls over a live view of the game. The scene is a
-- gameplay phase of its own, unrecorded and silent, and every choice is
-- applied to Config at once, so the picture behind the cards is the game as
-- it will look (the phase holds no simulation parameters, see holds_params).
--
-- The phase is flown by the scripted runs of data/styles.json `preview`, one
-- after the other, each started inside an enemy base so there is always
-- something going on behind the cards.
--
-- The title opens the screen in place of the menu until it was confirmed once
-- (Config.style_chosen); there is no way out but the OK plate then. The
-- options open it with { return_to = <scene> }, where Esc puts the settings
-- back as they were. It reloads the world, so it is never opened over a
-- suspended game.
local StyleSelect = Class(Gameplay)

StyleSelect.ui_pointer     = true
StyleSelect.no_record      = true
StyleSelect.holds_params   = false   -- a choice here is meant to change the running phase
StyleSelect.mouse_steering = false
StyleSelect.padpressed     = Scene.padpressed   -- a menu: the pad stands for keys

local DESIGN_W = Layout.DESIGN_W

-- VSELECT pieces, as the vehicle select screen cuts them: a clean stretch of
-- each camo strip (a style's `camo` picks the row behind its card), and the
-- OK / EXIT plates.
local VSELECT    = "assets/fullscreen/VSELECT.png"
local CAMO_ROWS  = { { 106, 11, 194, 52 }, { 106, 71, 194, 51 }, { 106, 131, 194, 54 }, { 106, 192, 160, 42 } }
local OK_PLATE   = { 77, 49, 29, 14 }
local EXIT_PLATE = { 273, 222, 34, 15 }

local TITLE_Y   = 4
local TOP_BAND  = 23    -- dimmed strip under the title
local PANEL_Y   = 174   -- dimmed strip under the cards and rows
local CARD_X    = 8
local CARD_Y    = 179
local CARD_W    = 96
local CARD_H    = 21
local CARD_GAP  = 8
local LABEL_DY  = 5
local ABOUT_Y   = 204   -- the chosen style's one line
local ROW_Y     = { 217, 229 }
local ROW_H     = 10
local ROW_X     = 24    -- row label
local VALUE_X0  = 116   -- value zone, the value centred in it between its arrows
local VALUE_X1  = 240
local ARROW_GAP = 7     -- arrow centre to the value text
local OK_XY     = { x = 246, y = 220 }
local EXIT_XY   = { x = 279, y = 220 }
local FADE_IN   = 0.25
local FOCUS_Y   = 0.09  -- window heights the vehicle sits above the centre, clear of the cards

local GOLD = { 1, 0.8, 0.2 }

local DEFAULT_VEHICLE = "chopper"
local DEFAULT_SCRIPT  = { { ticks = 1800 } }
local DEFAULT_FADE    = 30

local CONTROLS = {
    { label = "KEYBOARD", value = false },
    { label = "KEYS + MOUSE", value = true },
}

-- Input source answering from a preview run's script: one held mask per
-- segment, its edge actions on the segment's first tick.
local ScriptSource = Class()

function ScriptSource:init(script)
    self.segments = {}
    self.index    = 1
    local tick = 0
    for _, seg in ipairs(script or {}) do
        local mask = 0
        for _, action in ipairs(seg.held or {}) do mask = mask + (InputFrame.BIT[action] or 0) end
        local ticks = seg.ticks or 0
        self.segments[#self.segments + 1] = { first = tick + 1, last = tick + ticks, mask = mask, events = seg.events }
        tick = tick + ticks
    end
    self.length = tick
end

function ScriptSource:queue(_event) end

function ScriptSource:frame(tick)
    while self.segments[self.index] and tick > self.segments[self.index].last do
        self.index = self.index + 1
    end
    local seg = self.segments[self.index]
    if not seg then return InputFrame.EMPTY end
    return InputFrame.new(seg.mask, tick == seg.first and seg.events or nil)
end

function StyleSelect:init(app)
    Gameplay.init(self, app)
    self.title_font = Font.get(Assets.exists("fonts/main.json") and "main" or "mainmen")
    self.name_font  = Font.get("hichars")
    self.gold_font  = Font.get("credchars")
    self.row_font   = Font.get("chars")
    self.about_font = Font.get("keysfont")
    if love.filesystem.getInfo(VSELECT) then
        local art = love.graphics.newImage(VSELECT)
        art:setFilter("nearest", "nearest")
        local w, h = art:getDimensions()
        self.art        = art
        self.camo_quads = {}
        for i, r in ipairs(CAMO_ROWS) do
            self.camo_quads[i] = love.graphics.newQuad(r[1], r[2] + math.floor((r[4] - CARD_H) / 2),
                CARD_W, CARD_H, w, h)
        end
        self.plate_quads = {
            love.graphics.newQuad(OK_PLATE[1], OK_PLATE[2], OK_PLATE[3], OK_PLATE[4], w, h),
            love.graphics.newQuad(EXIT_PLATE[1], EXIT_PLATE[2], EXIT_PLATE[3], EXIT_PLATE[4], w, h),
        }
    end
end

-- The choice rows, top to bottom: the style (drawn as the cards), the
-- difficulty and, where a mouse can steer, the controls.
function StyleSelect:_build_rows()
    self.rows = {
        {
            id = "style", choices = Style.choices(),
            get = function() return Config.style end,
            set = function(value) Style.apply(value) end,
        },
        {
            id = "difficulty", label = "DIFFICULTY", choices = Difficulty.preset_choices(),
            get = function() return Config.difficulty end,
            set = function(value)
                Config.difficulty = value
                Difficulty.apply_preset(value)
            end,
        },
    }
    if not TouchControls.available(self.app) then
        self.rows[#self.rows + 1] = {
            id = "controls", label = "CONTROLS", choices = CONTROLS,
            get = function() return Config.mouse_control end,
            set = function(value) Config.mouse_control = value end,
        }
    end
end

-- The preview's runs, each on a stage the pack holds.
function StyleSelect:_load_runs(preview)
    local stages = self.app.world.stages
    local function stage_of(name)
        return (name and Assets.exists(name .. ".json")) and name or nil
    end
    local runs = {}
    for _, run in ipairs(preview.runs or {}) do
        runs[#runs + 1] = {
            script = run.script, vehicle = run.vehicle, x = run.x, y = run.y, angle = run.angle,
            stage = stage_of(run.stage) or stage_of(preview.stage) or stages[1],
        }
    end
    if #runs == 0 then
        runs[1] = { script = DEFAULT_SCRIPT, stage = stages[1] }
    end
    return runs
end

function StyleSelect:enter(opts)
    local app      = self.app
    local settings = app.settings
    local preview  = Style.preview()
    self.return_to = opts and opts.return_to or nil
    self.t         = 0
    self.row       = 1
    self.pressed   = nil
    self.hover     = nil
    self.fade      = preview.fade or DEFAULT_FADE
    self.runs      = self:_load_runs(preview)

    -- What the preview phase borrows, put back by leave().
    local config = {}
    for key, value in pairs(Config) do
        if type(value) ~= "function" and type(value) ~= "table" then config[key] = value end
    end
    self.saved = {
        config    = config,
        stage     = app.world.stage_name,
        zoom      = app.camera.zoom_index,
        vehicle   = settings.vehicle,
        death     = settings.death_enabled,
        loadout   = settings.loadout,
        campaign  = app.campaign,
    }
    settings.loadout       = nil
    settings.death_enabled = false
    app.campaign           = false
    app.replay_play        = nil

    self:_build_rows()
    -- The first visit starts on the default style; the options keep what is set.
    if not self.return_to then Style.apply(Style.default()) end
    self:_start_run(1)
end

function StyleSelect:leave()
    local app, saved = self.app, self.saved
    Gameplay.leave(self)
    app.settings.vehicle       = saved.vehicle
    app.settings.death_enabled = saved.death
    app.settings.loadout       = saved.loadout
    app.campaign               = saved.campaign
    app.world:load(saved.stage)   -- the preview's wreckage stays out of the menus
    app.after_stage_load()
    app.camera:set_zoom(saved.zoom)
    self.saved = nil
end

-- the preview phase

-- Start run `index` from a fresh stage. Every run is a phase entered anew, as
-- one run may play on another stage than the last.
function StyleSelect:_start_run(index)
    local app = self.app
    local run = self.runs[index]
    self.run  = index
    app.settings.vehicle = run.vehicle or DEFAULT_VEHICLE
    Gameplay.enter(self)
    app.viewer_zoom_index = self.saved.zoom   -- enter() took the game zoom of the run before
end

function StyleSelect:reload_stage()
    self.app.world:load(self.runs[self.run].stage)
    self.app.after_stage_load()
end

function StyleSelect:begin_audio()
    if self.app.sound then self.app.sound:set_muted(true, true) end
end

function StyleSelect:enter_music() end   -- the menu music plays on

function StyleSelect:begin_input(...)
    Gameplay.begin_input(self, ...)
    self.source = ScriptSource:new(self.runs[self.run].script)
    self.length = self.source.length
end

-- The preview's vehicle cannot be lost. A run starts where its x, y and angle
-- put it, inside a base rather than on the pad.
function StyleSelect:spawn_player(carry)
    Gameplay.spawn_player(self, carry)
    local run, player, camera = self.runs[self.run], self.player, self.app.camera
    player.unlimited = true
    if run.x and run.y then
        player.x, player.y = run.x, run.y
        camera.x, camera.y = run.x, run.y
    end
    player.angle = run.angle or player.angle
end

-- The preview never ends by itself: no stats screen, no failed phase.
function StyleSelect:update_won(_dt) end
function StyleSelect:update_phase_failed(_dt) return false end

function StyleSelect:update(dt)
    Gameplay.update(self, dt)
    self.t = self.t + dt
    if self.app.tick >= self.length then
        self:_start_run(self.run % #self.runs + 1)
    end
end

-- selection

function StyleSelect:_step(row, dir)
    local index = 0
    for i, choice in ipairs(row.choices) do
        if choice.value == row.get() then index = i; break end
    end
    repeat
        index = ((index - 1 + dir) % #row.choices) + 1
    until not row.choices[index].hidden
    self:_set(row, row.choices[index].value)
end

function StyleSelect:_set(row, value)
    if row.get() == value then return end
    row.set(value)
    Audio.play_event("ui.move")
end

function StyleSelect:_choice(row)
    for _, choice in ipairs(row.choices) do
        if choice.value == row.get() then return choice end
    end
    return nil
end

function StyleSelect:_confirm()
    Audio.play_event("ui.confirm")
    Config.style        = Style.match()
    Config.style_chosen = true
    Config.save()
    self.app.scenes:switch(self.return_to or "main_menu")
end

function StyleSelect:_cancel()
    if not self.return_to then return end
    Audio.play_event("ui.back")
    for key, value in pairs(self.saved.config) do Config[key] = value end
    self.app.scenes:switch(self.return_to)
end

-- layout: the cards, the row value zones and the plates in design space

local function card_rect(i)
    return { x = CARD_X + (i - 1) * (CARD_W + CARD_GAP), y = CARD_Y, w = CARD_W, h = CARD_H }
end

local function inside(r, x, y)
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- What sits under a design-space point: { kind = "card" | "row" | "button", ... } or nil.
function StyleSelect:_hit(x, y)
    if inside({ x = OK_XY.x, y = OK_XY.y, w = OK_PLATE[3], h = OK_PLATE[4] }, x, y) then
        return { kind = "button", id = "ok" }
    end
    if self.return_to and inside({ x = EXIT_XY.x, y = EXIT_XY.y, w = EXIT_PLATE[3], h = EXIT_PLATE[4] }, x, y) then
        return { kind = "button", id = "exit" }
    end
    local n = 0
    for i, choice in ipairs(self.rows[1].choices) do
        if not choice.hidden then
            n = n + 1
            if inside(card_rect(n), x, y) then return { kind = "card", id = i } end
        end
    end
    for i = 2, #self.rows do
        local ry = ROW_Y[i - 1]
        if x >= ROW_X and x < VALUE_X1 and y >= ry - 2 and y < ry + ROW_H then
            return { kind = "row", id = i, dir = (x >= (VALUE_X0 + VALUE_X1) / 2) and 1 or -1 }
        end
    end
    return nil
end

local function same_hit(a, b)
    return a and b and a.kind == b.kind and a.id == b.id and a.dir == b.dir
end

function StyleSelect:_activate(hit)
    if hit.kind == "button" then
        if hit.id == "ok" then self:_confirm() else self:_cancel() end
    elseif hit.kind == "card" then
        self.row = 1
        self:_set(self.rows[1], self.rows[1].choices[hit.id].value)
    elseif hit.kind == "row" then
        self.row = hit.id
        self:_step(self.rows[hit.id], hit.dir)
    end
end

-- input

function StyleSelect:keypressed(key)
    if key == "escape" then self:_cancel(); return end
    if key == "return" or key == "kpenter" or key == "space" then self:_confirm(); return end
    if key == "up" or key == "down" then
        self.row = ((self.row - 1 + (key == "up" and -1 or 1)) % #self.rows) + 1
        Audio.play_event("ui.move")
    elseif key == "left" or key == "right" then
        self:_step(self.rows[self.row], key == "left" and -1 or 1)
    end
end

function StyleSelect:mousemoved(x, y)
    local hit = self:_hit(Pointer.to_design(x, y))
    self.hover = hit
    if hit and hit.kind == "row" then self.row = hit.id end
    if hit and hit.kind == "card" then self.row = 1 end
end

function StyleSelect:mousepressed(x, y)
    self.pressed = self:_hit(Pointer.to_design(x, y))
end

function StyleSelect:mousereleased(x, y)
    local hit, was = self:_hit(Pointer.to_design(x, y)), self.pressed
    self.pressed = nil
    if same_hit(hit, was) then self:_activate(hit) end
end

function StyleSelect:wheelmoved() end

-- A touch is the pointer here, not the vehicle's controls.
function StyleSelect:touchpressed() return false end
function StyleSelect:touchmoved() return false end
function StyleSelect:touchreleased() return false end

-- draw

local function centered(font, text, x, w)
    return math.floor(x + (w - font:width(text)) / 2)
end

function StyleSelect:_draw_arrow(cx, cy, dir, alpha)
    local g   = love.graphics
    local bob = (math.sin(self.t * 5) > 0) and 1 or 0
    cx = cx + dir * bob
    g.setColor(0, 0, 0, 0.8 * alpha)
    g.polygon("fill", cx - 2 * dir + 1, cy - 4 + 1, cx - 2 * dir + 1, cy + 4 + 1, cx + 2 * dir + 1, cy + 1)
    g.setColor(GOLD[1], GOLD[2], GOLD[3], alpha)
    g.polygon("fill", cx - 2 * dir, cy - 4, cx - 2 * dir, cy + 4, cx + 2 * dir, cy)
end

function StyleSelect:_draw_card(n, style, selected, fade)
    local g     = love.graphics
    local c     = card_rect(n)
    local shade = selected and 1 or 0.4
    local quad  = self.art and self.camo_quads[style.camo or n]
    if quad then
        g.setColor(shade, shade, shade, fade)
        g.draw(self.art, quad, c.x, c.y)
    else
        g.setColor(0.2 * shade, 0.2 * shade, 0.2 * shade, fade)
        g.rectangle("fill", c.x, c.y, c.w, c.h)
    end
    g.setColor(0, 0, 0, 0.6 * fade)
    g.setLineWidth(1)
    g.rectangle("line", c.x + 0.5, c.y + 0.5, c.w - 1, c.h - 1)

    -- The chosen style's name uses the baked gold credits font, as the vehicle
    -- select does for the active variant.
    if selected then
        self.gold_font:print(style.label, centered(self.gold_font, style.label, c.x, c.w), c.y + LABEL_DY,
            { color = { 1, 1, 1, fade } })
        local pulse = (self.row == 1) and (0.65 + 0.35 * math.sin(self.t * 4)) or 0.6
        g.setColor(GOLD[1], GOLD[2], GOLD[3], pulse * fade)
        g.rectangle("line", c.x - 1.5, c.y - 1.5, c.w + 3, c.h + 3)
    else
        local x, y = centered(self.name_font, style.label, c.x, c.w), c.y + LABEL_DY
        self.name_font:print(style.label, x + 1, y + 1, { color = { 0, 0, 0, 0.4 * fade } })
        self.name_font:print(style.label, x, y, { color = { 1, 1, 1, 0.5 * fade } })
    end
    g.setColor(1, 1, 1, 1)
end

function StyleSelect:_draw_row(i, fade)
    local row     = self.rows[i]
    local y       = ROW_Y[i - 1]
    local focused = self.row == i
    local alpha   = (focused and 1 or 0.6) * fade
    local choice  = self:_choice(row)
    local value   = choice and choice.label or ""
    local value_x = centered(self.row_font, value, VALUE_X0, VALUE_X1 - VALUE_X0)
    self.row_font:print(row.label, ROW_X, y, { color = { 1, 1, 1, alpha } })
    self.row_font:print(value, value_x, y, { color = { 1, 1, 1, alpha } })
    if focused then
        local cy = y + self.row_font.line_height / 2
        self:_draw_arrow(value_x - ARROW_GAP, cy, -1, fade)
        self:_draw_arrow(value_x + self.row_font:width(value) + ARROW_GAP, cy, 1, fade)
    end
end

function StyleSelect:_draw_plate(which, id, xy, fade)
    if not self.art then return end
    local g    = love.graphics
    local down = self.pressed and self.pressed.kind == "button" and self.pressed.id == id
    local lit  = self.hover and self.hover.kind == "button" and self.hover.id == id
    local k    = lit and 1 or 0.85
    g.setColor(k, k, k, fade)
    g.draw(self.art, self.plate_quads[which], xy.x + (down and 1 or 0), xy.y + (down and 1 or 0))
end

-- How dark the preview is on this tick: it fades in after a run starts and
-- out before the next one takes over.
function StyleSelect:_preview_dim()
    local tick, fade = self.app.tick, math.max(1, self.fade)
    local edge = math.min(tick, self.length - tick)
    return 1 - math.max(0, math.min(1, edge / fade))
end

function StyleSelect:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade               = math.min(1, self.t / FADE_IN)

    self.app.camera.view_oy = -screen_h * FOCUS_Y
    self:draw_world()
    g.setColor(0, 0, 0, self:_preview_dim())
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    local scale, ox, oy = Layout.fit(screen_w, screen_h)
    g.setColor(0, 0, 0, 0.5 * fade)
    g.rectangle("fill", 0, 0, screen_w, oy + TOP_BAND * scale)
    g.setColor(0, 0, 0, 0.6 * fade)
    g.rectangle("fill", 0, oy + PANEL_Y * scale, screen_w, screen_h - (oy + PANEL_Y * scale))

    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    local title = "SELECT GAME STYLE"
    self.title_font:print(title, centered(self.title_font, title, 0, DESIGN_W), TITLE_Y, { color = { 1, 1, 1, fade } })

    local styles, n = Style.list(), 0
    for _, choice in ipairs(self.rows[1].choices) do
        if not choice.hidden then
            n = n + 1
            local selected = choice.value == Config.style
            self:_draw_card(n, styles[n], selected, fade)
            local about = selected and styles[n].about
            if about then
                local x = centered(self.about_font, about, 0, DESIGN_W)
                self.about_font:print(about, x + 1, ABOUT_Y + 1, { color = { 0, 0, 0, 0.8 * fade } })
                self.about_font:print(about, x, ABOUT_Y, { color = { 1, 1, 1, 0.85 * fade } })
            end
        end
    end
    for i = 2, #self.rows do self:_draw_row(i, fade) end

    self:_draw_plate(1, "ok", OK_XY, fade)
    if self.return_to then self:_draw_plate(2, "exit", EXIT_XY, fade) end

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return StyleSelect
