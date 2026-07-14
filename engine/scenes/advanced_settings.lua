local Class   = require "engine.core.class"
local Scene   = require "engine.core.scene"
local Font    = require "engine.core.font"
local Layout  = require "engine.ui.layout"
local Config  = require "engine.core.config"
local Pointer = require "engine.ui.pointer"

-- Advanced OpenSeek options: a paginated page over the pulsating main-menu
-- backdrop, editing the engine tunables in engine/core/config. Reached from the
-- main menu's OPTIONS entry. Changes apply live (the systems read Config every
-- frame) and are written to the save directory on exit.
local AdvancedSettings = Class(Scene)

AdvancedSettings.ui_pointer = true

local DESIGN_W, DESIGN_H = Layout.DESIGN_W, Layout.DESIGN_H

local PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 20, 34, 280, 176
local TITLE_Y   = 42
local TABS_Y    = 58
local TAB_GAP   = 20
local ROW_X     = 40
local VALUE_RX  = 280
local ROW_Y0    = 82
local ROW_DY    = 22
local ROW_H     = 12
local ARROW_GAP = 8
local FADE_IN   = 0.25

-- Options grouped into listable pages. toggle flips a boolean; range steps a
-- number shown as a percentage. Every key is a persisted field of Config.
local PAGES = {
    { title = "VISUAL EFFECTS", options = {
        { key = "effects_flashes",  label = "FLASH FX",      kind = "toggle" },
        { key = "flash_intensity",  label = "FLASH LEVEL",   kind = "range", min = 0.0, max = 1.5, step = 0.1 },
        { key = "night_lighting",   label = "NIGHT LIGHT",   kind = "toggle" },
        { key = "night_brightness", label = "NIGHT AMBIENT", kind = "range", min = 0.5, max = 2.0, step = 0.1 },
    } },
    { title = "GAMEPLAY", options = {
        { key = "speed_scale",          label = "GAME SPEED",     kind = "range", min = 0.5, max = 1.2, step = 0.1 },
        { key = "hud_scale",            label = "HUD SIZE",       kind = "range", min = 0.8, max = 1.6, step = 0.1 },
        { key = "axis_aligned_pickups", label = "CLASSIC PICKUPS", kind = "toggle" },
        { key = "friendly_fire_pows",   label = "FRIENDLY FIRE",  kind = "toggle" },
        { key = "endstats_count_up",    label = "STATS COUNT UP", kind = "toggle" },
    } },
}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function AdvancedSettings:init(app)
    Scene.init(self, app)
    self.font   = Font.get("chars")
    self.page   = 1
    self.cursor = 1
    self.t      = 0

    local ok, img = pcall(love.graphics.newImage, "assets/fullscreen/MAINP.png")
    if ok then img:setFilter("linear", "linear"); self.bg = img end
    local aok, arrow = pcall(love.graphics.newImage, "assets/mainmen/arrow.png")
    if aok then arrow:setFilter("nearest", "nearest"); self.arrow = arrow end
end

function AdvancedSettings:enter() self.t = 0; self.page = 1; self.cursor = 1 end

function AdvancedSettings:_options() return PAGES[self.page].options end

-- Persist and return to the menu.
function AdvancedSettings:_exit()
    Config.save()
    self.app.scenes:replace("main_menu")
end

function AdvancedSettings:_move(dir)
    local n = #self:_options()
    self.cursor = ((self.cursor - 1 + dir) % n) + 1
end

function AdvancedSettings:_set_page(page)
    self.page   = ((page - 1) % #PAGES) + 1
    self.cursor = 1
end

-- Change the selected option. dir is +1 / -1; a toggle ignores its magnitude.
function AdvancedSettings:_adjust(dir)
    local opt = self:_options()[self.cursor]
    if opt.kind == "toggle" then
        Config[opt.key] = not Config[opt.key]
    else
        local v = Config[opt.key] + opt.step * dir
        v = math.floor(v / opt.step + 0.5) * opt.step   -- snap off float drift
        Config[opt.key] = clamp(v, opt.min, opt.max)
    end
end

function AdvancedSettings:_value_text(opt)
    if opt.kind == "toggle" then
        return Config[opt.key] and "ON" or "OFF"
    end
    return string.format("%d%%", math.floor(Config[opt.key] * 100 + 0.5))
end

function AdvancedSettings:keypressed(key)
    if key == "escape" then self:_exit(); return end
    if key == "tab" then
        self:_set_page(self.page + (love.keyboard.isDown("lshift", "rshift") and -1 or 1))
    elseif key == "up"    then self:_move(-1)
    elseif key == "down"  then self:_move(1)
    elseif key == "left"  then self:_adjust(-1)
    elseif key == "right" then self:_adjust(1)
    elseif key == "return" or key == "space" or key == "kpenter" then self:_adjust(1) end
end

-- Tab positions (design space), centered as a group. Shared by draw and hit test.
function AdvancedSettings:_tab_layout()
    local widths, total = {}, 0
    for i, pg in ipairs(PAGES) do
        widths[i] = self.font:width(pg.title)
        total = total + widths[i]
    end
    total = total + TAB_GAP * (#PAGES - 1)
    local x, tabs = (DESIGN_W - total) / 2, {}
    for i, pg in ipairs(PAGES) do
        tabs[i] = { x = x, w = widths[i], title = pg.title }
        x = x + widths[i] + TAB_GAP
    end
    return tabs
end

-- Row under a window-space point, or nil.
function AdvancedSettings:_row_at(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dx < ROW_X - 12 or dx > VALUE_RX + 4 then return nil end
    for i = 1, #self:_options() do
        local ry = ROW_Y0 + (i - 1) * ROW_DY
        if dy >= ry - 3 and dy <= ry + ROW_H then return i end
    end
    return nil
end

function AdvancedSettings:mousemoved(x, y)
    local i = self:_row_at(x, y)
    if i then self.cursor = i end
end

-- Click a tab to switch pages, or a row to change it: toggles flip, ranges step
-- up on the right half and down on the left half.
function AdvancedSettings:mousepressed(x, y)
    local dx, dy = Pointer.to_design(x, y, DESIGN_W, DESIGN_H)
    if dy >= TABS_Y - 3 and dy <= TABS_Y + ROW_H then
        for i, tab in ipairs(self:_tab_layout()) do
            if dx >= tab.x - 4 and dx <= tab.x + tab.w + 4 then self:_set_page(i); return end
        end
    end
    local i = self:_row_at(x, y)
    if not i then return end
    self.cursor = i
    local opt = self:_options()[i]
    if opt.kind == "toggle" then
        self:_adjust(1)
    else
        self:_adjust(dx >= (ROW_X + VALUE_RX) / 2 and 1 or -1)
    end
end

function AdvancedSettings:update(dt) self.t = self.t + dt end

function AdvancedSettings:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade = math.min(1, self.t / FADE_IN)

    -- Pulsating backdrop, matching the main menu (breathing zoom, fade-in).
    if self.bg then
        local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
        local bw, bh  = screen_w * breathe, screen_h * breathe
        g.setColor(fade, fade, fade, 1)
        g.draw(self.bg, (screen_w - bw) / 2, (screen_h - bh) / 2, 0,
            bw / self.bg:getWidth(), bh / self.bg:getHeight())
    else
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", 0, 0, screen_w, screen_h)
    end

    local scale, ox, oy = Layout.fit(screen_w, screen_h)
    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    -- Dim panel behind the text so the gold font reads over the artwork.
    g.setColor(0, 0, 0, 0.55 * fade)
    g.rectangle("fill", PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 4)

    local title = "ADVANCED OPTIONS"
    self.font:print(title, (DESIGN_W - self.font:width(title)) / 2, TITLE_Y,
        { color = { 1, 1, 1, fade } })

    -- Page tabs; the active one is bright and underlined.
    for i, tab in ipairs(self:_tab_layout()) do
        local active = (i == self.page)
        self.font:print(tab.title, tab.x, TABS_Y,
            { color = { 1, 1, 1, (active and 1 or 0.4) * fade } })
        if active then
            g.setColor(1, 1, 1, fade)
            g.rectangle("fill", tab.x, TABS_Y + self.font.line_height + 1, tab.w, 1)
        end
    end

    for i, opt in ipairs(self:_options()) do
        local y   = ROW_Y0 + (i - 1) * ROW_DY
        local sel = (i == self.cursor)
        local a   = (sel and 1 or 0.6) * fade
        self.font:print(opt.label, ROW_X, y, { color = { 1, 1, 1, a } })
        local vt = self:_value_text(opt)
        self.font:print(vt, VALUE_RX - self.font:width(vt), y, { color = { 1, 1, 1, a } })
        if sel and self.arrow then
            local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
            local phase  = 0.5 + 0.5 * math.sin(self.t * 2.2)
            g.setColor(1, 1, 1, fade)
            g.draw(self.arrow, ROW_X - ARROW_GAP - aw / 2 + 3 * phase,
                y + self.font.line_height / 2, 0, 1, 1, aw / 2, ah / 2)
        end
    end

    g.pop()
    g.setColor(1, 1, 1, 1)
end

return AdvancedSettings
