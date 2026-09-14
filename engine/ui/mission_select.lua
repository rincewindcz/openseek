local Class   = require "engine.core.class"
local Font    = require "engine.core.font"
local Pointer = require "engine.ui.pointer"
local Layout  = require "engine.ui.layout"

-- Debug mission-select screen: pick any mission/phase and drop into it. Over the
-- main-menu MAINP backdrop (breathing zoom, subtly tinted toward the selected
-- mission's colour): a STAGE0X_MPIC carousel (left/right arrows cycle the
-- mission with a slide + arrow bump), a row of the four PHASE 0X buttons, and
-- PLAY / EXIT. Fully keyboard-drivable (up/down move between the carousel /
-- phase / button rows, left/right within a row); mouse and touch also work.
-- Confirming fades through black, then calls self.on_select(id, stage_name) --
-- "play" with the chosen "stageMP", or "exit". Reached from the main menu's
-- MISSION entry (see main.lua).
local MissionSelect = Class()

local DW, DH = Layout.DESIGN_W, Layout.DESIGN_H

local TITLE_Y = 8

-- Carousel picture box (STAGE0X_MPIC is fullscreen; shown shrunk, same aspect).
local MPIC_W, MPIC_H = 152, 114
local MPIC_X = (DW - MPIC_W) / 2
local MPIC_Y = 40

local ARROW_SCALE = 1.5
local ARROW_GAP   = 8      -- px between the picture box and each arrow
local ARROW_BUMP  = 0.45   -- extra scale at the peak of a click bump
local BUMP_TIME   = 0.18

local SLIDE_TIME  = 0.28   -- carousel image slide on a mission change

-- Phase button row (assets/mission/phase01..04). These are toggle buttons: only
-- one phase is selected at a time and it wears its pressed (down) frame to mark
-- the chosen level; PLAY then loads whatever phase is selected.
local PHASE_W, PHASE_H = 63, 12
local PHASE_PITCH = 69
local PHASE_X0 = (DW - (PHASE_PITCH * 3 + PHASE_W)) / 2
local PHASE_Y  = 170

local BTN_Y = 214
local BUTTONS = {
    { id = "play", x = 106 },
    { id = "exit", x = 168 },
}

local FOCUS_PAD    = 2
local FOCUS_COL    = { 240 / 255, 132 / 255, 0 }  -- SELFOCUS gold, for primitive rings
local CONFIRM_TIME = 0.3

-- Backdrop tint toward the selected mission's colour. TINT_AMOUNT is the whole
-- effect's strength (0 = off, ~0.5 = strong); TINT_SPEED is how fast it eases
-- between missions. Tune these two to taste.
local TINT_AMOUNT  = 0.42
local TINT_SPEED   = 3

-- Focus rows.
local ROW_CAROUSEL, ROW_PHASE, ROW_BUTTON = 0, 1, 2

local function img(path)
    if not love.filesystem.getInfo(path) then return nil end
    local ok, i = pcall(love.graphics.newImage, path)
    if ok then
        i:setFilter("nearest", "nearest")
        return i
    end
    print("missionselect: missing " .. path)
    return nil
end

local function in_rect(r, dx, dy)
    return r and dx >= r.x and dx <= r.x + r.w and dy >= r.y and dy <= r.y + r.h
end

function MissionSelect:init()
    self.active     = false
    self.t          = 0
    self.mission    = 0
    self.phase      = 0
    self.row        = ROW_CAROUSEL
    self.btn        = 1     -- focused button when row == ROW_BUTTON
    self.pressed    = nil   -- button index held down by mouse/touch
    self.confirming = nil
    self.confirm_t  = 0

    self.slide_t   = SLIDE_TIME
    self.slide_dir = 1
    self.prev_mpic = nil
    self.bump_l, self.bump_r = 0, 0

    self.title_font   = Font.get("mainmen")
    self.version_font = Font.get("chars")   -- bottom-right build tag, as on the main menu
    self.version_text = "OPENSEEK 0.9"
    self.focus = img("assets/hud/selfocus_f01.png")
    self.arrow = img("assets/mainmen/arrow.png")

    self.buttons = {}
    for i, b in ipairs(BUTTONS) do
        self.buttons[i] = {
            id = b.id, x = b.x, y = BTN_Y, w = 46, h = 12,
            up = img("assets/mission/" .. b.id .. ".png"),
            down = img("assets/mission/" .. b.id .. "_hi.png"),
        }
    end

    self.phases = {}
    for p = 0, 3 do
        self.phases[p + 1] = {
            x = PHASE_X0 + p * PHASE_PITCH, y = PHASE_Y, w = PHASE_W, h = PHASE_H,
            up = img(string.format("assets/mission/phase0%d.png", p + 1)),
            down = img(string.format("assets/mission/phase0%d_hi.png", p + 1)),
        }
    end

    local bg = img("assets/fullscreen/MAINP.png")
    local ok = bg ~= nil
    if ok then bg:setFilter("linear", "linear"); self.bg = bg else self.bg = nil end

    self._cache      = {}
    self._tint_cache = {}
    self.tint = self:_tint_for(self.mission)
end

function MissionSelect:is_active() return self.active end
function MissionSelect:close() self.active = false end

function MissionSelect:open()
    self.t          = 0
    self.row        = ROW_CAROUSEL
    self.pressed    = nil
    self.confirming = nil
    self.confirm_t  = 0
    self.slide_t    = SLIDE_TIME
    self.prev_mpic  = nil
    self.bump_l, self.bump_r = 0, 0
    local tt = self:_tint_for(self.mission)
    self.tint = { tt[1], tt[2], tt[3] }  -- snap (no interpolation from stale)
    self.active = true
end

function MissionSelect:_img(path)
    if self._cache[path] == nil then
        self._cache[path] = img(path) or false
    end
    return self._cache[path] or nil
end

function MissionSelect:_mpic(m)
    return self:_img(string.format("assets/fullscreen/STAGE0%d_MPIC.png", m))
end

function MissionSelect:stage_name()
    return string.format("stage%d%d", self.mission, self.phase)
end

-- A subtle backdrop tint toward the mission's own colour, sampled once from the
-- average of its MPIC and normalized so it shifts hue rather than darkening.
function MissionSelect:_tint_for(m)
    if self._tint_cache[m] then return self._tint_cache[m] end
    local t = { 1, 1, 1 }
    local path     = string.format("assets/fullscreen/STAGE0%d_MPIC.png", m)
    local ok, data = false, nil
    if love.filesystem.getInfo(path) then ok, data = pcall(love.image.newImageData, path) end
    if ok then
        local w, h = data:getWidth(), data:getHeight()
        local sr, sg, sb, n = 0, 0, 0, 0
        for y = 0, h - 1, 8 do
            for x = 0, w - 1, 8 do
                local r, g, b = data:getPixel(x, y)
                sr, sg, sb, n = sr + r, sg + g, sb + b, n + 1
            end
        end
        if n > 0 then
            local ar, ag, ab = sr / n, sg / n, sb / n
            local mx = math.max(ar, ag, ab, 0.001)
            t = {
                (1 - TINT_AMOUNT) + TINT_AMOUNT * (ar / mx),
                (1 - TINT_AMOUNT) + TINT_AMOUNT * (ag / mx),
                (1 - TINT_AMOUNT) + TINT_AMOUNT * (ab / mx),
            }
        end
    end
    self._tint_cache[m] = t
    return t
end

function MissionSelect:_cycle_mission(dir)
    self.prev_mpic = self:_mpic(self.mission)
    self.mission   = (self.mission + dir) % 5
    self.slide_t   = 0
    self.slide_dir = dir
    if dir < 0 then self.bump_l = BUMP_TIME else self.bump_r = BUMP_TIME end
end

function MissionSelect:_arrow_geom()
    if not self.arrow then return nil end
    local aw, ah = self.arrow:getWidth(), self.arrow:getHeight()
    local cy = MPIC_Y + MPIC_H / 2
    local hw, hh = aw * ARROW_SCALE, ah * ARROW_SCALE
    local lcx = MPIC_X - ARROW_GAP - hw / 2
    local rcx = MPIC_X + MPIC_W + ARROW_GAP + hw / 2
    return {
        aw = aw, ah = ah, cy = cy,
        lcx = lcx, rcx = rcx,
        lrect = { x = lcx - hw / 2, y = cy - hh / 2, w = hw, h = hh },
        rrect = { x = rcx - hw / 2, y = cy - hh / 2, w = hw, h = hh },
    }
end

function MissionSelect:_arrow_scale(bump)
    if bump <= 0 then return ARROW_SCALE end
    local pulse = math.sin((1 - bump / BUMP_TIME) * math.pi)  -- 0 -> 1 -> 0
    return ARROW_SCALE * (1 + ARROW_BUMP * pulse)
end

-- What interactive target sits under a design-space point (or nil).
function MissionSelect:_target_at(dx, dy)
    for p = 1, 4 do
        if in_rect(self.phases[p], dx, dy) then return "phase", p - 1 end
    end
    for i = 1, #self.buttons do
        if in_rect(self.buttons[i], dx, dy) then return "button", i end
    end
    local ag = self:_arrow_geom()
    if ag then
        if in_rect(ag.lrect, dx, dy) then return "arrow", -1 end
        if in_rect(ag.rrect, dx, dy) then return "arrow", 1 end
    end
    if dx >= MPIC_X and dx <= MPIC_X + MPIC_W and dy >= MPIC_Y and dy <= MPIC_Y + MPIC_H then
        return "mpic"
    end
    return nil
end

-- Mouse/touch, window coords. Hover sets focus; press arms a button / selects a
-- phase / bumps an arrow; release over the same armed button confirms it.
function MissionSelect:hover(x, y)
    if not self.active or self.confirming then return end
    local kind, v = self:_target_at(Pointer.to_design(x, y, DW, DH))
    if kind == "button" then self.row = ROW_BUTTON; self.btn = v
    elseif kind == "phase" then self.row = ROW_PHASE
    elseif kind == "arrow" or kind == "mpic" then self.row = ROW_CAROUSEL end
end

function MissionSelect:press(x, y)
    if not self.active or self.confirming then return end
    local kind, v = self:_target_at(Pointer.to_design(x, y, DW, DH))
    if kind == "button" then self.row = ROW_BUTTON; self.btn = v; self.pressed = v
    elseif kind == "phase" then self.row = ROW_PHASE; self.phase = v
    elseif kind == "arrow" then self.row = ROW_CAROUSEL; self:_cycle_mission(v)
    elseif kind == "mpic" then self.row = ROW_CAROUSEL end
end

function MissionSelect:release(x, y)
    if not self.active or self.confirming then return end
    local was = self.pressed
    self.pressed = nil
    if not was then return end
    local kind, v = self:_target_at(Pointer.to_design(x, y, DW, DH))
    if kind == "button" and v == was then
        self:_confirm(self.buttons[was].id, was)
    end
end

function MissionSelect:_nav(dir)
    if self.row == ROW_CAROUSEL then
        self:_cycle_mission(dir)
    elseif self.row == ROW_PHASE then
        self.phase = math.max(0, math.min(3, self.phase + dir))
    else
        self.btn = math.max(1, math.min(#self.buttons, self.btn + dir))
    end
end

function MissionSelect:keypressed(key)
    if not self.active or self.confirming then return end
    if key == "up" then
        self.row = math.max(ROW_CAROUSEL, self.row - 1)
    elseif key == "down" then
        self.row = math.min(ROW_BUTTON, self.row + 1)
    elseif key == "left" then
        self:_nav(-1)
    elseif key == "right" then
        self:_nav(1)
    elseif key == "1" or key == "2" or key == "3" or key == "4" then
        self.phase = tonumber(key) - 1
        self.row = ROW_PHASE
    elseif key == "return" or key == "space" or key == "kpenter" then
        if self.row == ROW_BUTTON then
            self:_confirm(self.buttons[self.btn].id, self.btn)
        else
            self:_confirm("play", 1)   -- Enter anywhere else is a play shortcut
        end
    elseif key == "escape" then
        self:_confirm("exit", 2)
    end
end

-- Start the confirm fade-out; the action fires in update() once it finishes.
function MissionSelect:_confirm(id, btn_idx)
    self.confirming = id
    self.confirm_t  = 0
    self.pressed    = btn_idx  -- keep that button shown pressed during the fade
end

function MissionSelect:update(dt)
    self.t = self.t + dt
    if self.slide_t < SLIDE_TIME then self.slide_t = self.slide_t + dt end
    if self.bump_l > 0 then self.bump_l = math.max(0, self.bump_l - dt) end
    if self.bump_r > 0 then self.bump_r = math.max(0, self.bump_r - dt) end

    -- Ease the backdrop tint toward the selected mission's colour.
    local tgt = self:_tint_for(self.mission)
    local k = 1 - math.exp(-TINT_SPEED * dt)
    for i = 1, 3 do self.tint[i] = self.tint[i] + (tgt[i] - self.tint[i]) * k end

    if not self.confirming then return end
    self.confirm_t = self.confirm_t + dt
    if self.confirm_t >= CONFIRM_TIME then
        local id = self.confirming
        self.confirming = nil
        self.pressed = nil
        if self.on_select then self.on_select(id, self:stage_name()) end
    end
end

function MissionSelect:_fade()
    if self.confirming then
        return math.max(0, 1 - self.confirm_t / CONFIRM_TIME)
    end
    return 1
end

-- Rect (design space) of the currently keyboard-focused element.
function MissionSelect:_focus_rect()
    if self.row == ROW_CAROUSEL then
        return { x = MPIC_X, y = MPIC_Y, w = MPIC_W, h = MPIC_H }
    elseif self.row == ROW_PHASE then
        return self.phases[self.phase + 1]
    else
        return self.buttons[self.btn]
    end
end

-- Static focus indicator on the active element. The carousel box is far larger
-- than the SELFOCUS sprite, which looks bad blown up, so it gets a 1px primitive
-- outline; the small button/phase rects use the sprite ring at its native scale.
function MissionSelect:_draw_focus(g, fade)
    local r = self:_focus_rect()
    if not r then return end
    if self.row == ROW_CAROUSEL then
        g.setLineWidth(1)
        g.setColor(FOCUS_COL[1], FOCUS_COL[2], FOCUS_COL[3], fade)
        g.rectangle("line", r.x - 1, r.y - 1, r.w + 2, r.h + 2)
    elseif self.focus then
        g.setColor(1, 1, 1, fade)
        g.draw(self.focus, r.x - FOCUS_PAD, r.y - FOCUS_PAD, 0,
            (r.w + FOCUS_PAD * 2) / self.focus:getWidth(),
            (r.h + FOCUS_PAD * 2) / self.focus:getHeight())
    end
end

function MissionSelect:_blit_mpic(g, image, x, fade)
    g.setColor(1, 1, 1, fade)
    if image then
        g.draw(image, x, MPIC_Y, 0, MPIC_W / image:getWidth(), MPIC_H / image:getHeight())
    else
        g.rectangle("line", x, MPIC_Y, MPIC_W, MPIC_H)
    end
end

function MissionSelect:draw()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local fade               = self:_fade()
    local scale, ox, oy      = Layout.fit(screen_w, screen_h)

    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    -- Backdrop: full-window breathing zoom, tinted toward the mission colour.
    if self.bg then
        local breathe = 1 + 0.015 * (1 + math.sin(self.t * 0.5)) / 2
        local bw, bh  = screen_w * breathe, screen_h * breathe
        g.setColor(self.tint[1] * fade, self.tint[2] * fade, self.tint[3] * fade, 1)
        g.draw(self.bg, (screen_w - bw) / 2, (screen_h - bh) / 2, 0, bw / self.bg:getWidth(), bh / self.bg:getHeight())
    end

    g.push()
    g.translate(ox, oy)
    g.scale(scale, scale)

    local title = "MISSION SELECT"
    self.title_font:print(title, (DW - self.title_font:width(title)) / 2, TITLE_Y,
        { color = { 1, 1, 1, fade } })

    -- Carousel picture (slide on a mission change, clipped to the box).
    local cur = self:_mpic(self.mission)
    if self.slide_t < SLIDE_TIME and self.prev_mpic then
        local p = self.slide_t / SLIDE_TIME
        p = p * p * (3 - 2 * p)                 -- smoothstep
        local off = p * MPIC_W
        local dir = self.slide_dir
        g.setScissor(ox + MPIC_X * scale, oy + MPIC_Y * scale, MPIC_W * scale, MPIC_H * scale)
        self:_blit_mpic(g, self.prev_mpic, MPIC_X - dir * off, fade)
        self:_blit_mpic(g, cur, MPIC_X + dir * MPIC_W - dir * off, fade)
        g.setScissor()
    else
        self:_blit_mpic(g, cur, MPIC_X, fade)
    end

    -- Arrows (left mirrored), each scaled by its click bump about its own center.
    local ag = self:_arrow_geom()
    if ag then
        local ls, rs = self:_arrow_scale(self.bump_l), self:_arrow_scale(self.bump_r)
        g.setColor(1, 1, 1, fade)
        g.draw(self.arrow, ag.lcx, ag.cy, 0, -ls, ls, ag.aw / 2, ag.ah / 2)
        g.draw(self.arrow, ag.rcx, ag.cy, 0,  rs, rs, ag.aw / 2, ag.ah / 2)
    end

    -- Phase buttons: the selected phase shows its pressed (down) frame.
    for p = 1, 4 do
        local b = self.phases[p]
        local sprite = (p - 1 == self.phase) and b.down or b.up
        if sprite then g.setColor(1, 1, 1, fade); g.draw(sprite, b.x, b.y) end
    end

    -- PLAY / EXIT: down frame while pressed.
    for i, b in ipairs(self.buttons) do
        local sprite = (self.pressed == i) and b.down or b.up
        if sprite then g.setColor(1, 1, 1, fade); g.draw(sprite, b.x, b.y) end
    end

    -- Keyboard focus indicator on the active element.
    self:_draw_focus(g, fade)

    g.pop()

    -- Build tag, bottom-right, in raw window pixels like the main menu (CHARS is
    -- truecolor gold, so only show it once the screen is fully up).
    if fade >= 1 then
        local vw = self.version_font:width(self.version_text)
        self.version_font:print(self.version_text, screen_w - vw - 4,
            screen_h - self.version_font.line_height - 3)
    end

    g.setColor(1, 1, 1, 1)
end

return MissionSelect
