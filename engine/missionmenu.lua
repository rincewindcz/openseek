local Class   = require "engine.class"
local Font    = require "engine.font"
local json    = require "lib.json"
local Pointer = require "engine.pointer"

-- Pre-mission menu, styled after the original's MISSION/PHASE screen: the
-- STAGE0X_MS backdrop (its "MISSION 0X" title is baked in), the overlaid
-- "PHASE 0Y" title, the objective-icon column, the mission text, and a row of
-- five buttons (SAVE / LOAD / SHOP / PLAY / EXIT). Confirming a button calls
-- self.on_select(id); the caller (main.lua) decides what each does.
--
-- Buttons behave like real buttons: the focused one wears a SELFOCUS ring;
-- pressing (mouse/touch down, or keyboard) swaps to the button's down frame, and
-- the action only fires on release over the same button. The mission text is the
-- original per-phase briefing from data/mission_text.json (see
-- tools/export_mission_text.py), not an invented one-liner.
--
-- Widgets come from tools/export_mission.py (assets/mission/); the backdrop and
-- objective-icon columns are the already-exported fullscreen / phase art.
local MissionMenu = Class()

local DW, DH = 320, 240

local TITLE_Y = 26
local ICON_X, ICON_Y = 6, 52
local TEXT_X, TEXT_Y, TEXT_W = 82, 54, 232
local LINE_GAP = 2
local PARA_GAP = 6
local BTN_Y = 224
local FOCUS_PAD = 2      -- design px the focus ring extends past the button
local CONFIRM_TIME = 0.3 -- fade-through-black before the action fires

-- Buttons left to right, with their design-space x. Order is the nav order.
local BUTTONS = {
  { id = "save", x = 2 },
  { id = "load", x = 50 },
  { id = "shop", x = 177 },
  { id = "play", x = 224 },
  { id = "exit", x = 270 },
}
local DEFAULT_CURSOR = 4  -- PLAY

local function img(path)
  local ok, i = pcall(love.graphics.newImage, path)
  if ok then
    i:setFilter("nearest", "nearest")
    return i
  end
  print("missionmenu: missing " .. path)
  return nil
end

function MissionMenu:init()
  self.active     = false
  self.cursor     = DEFAULT_CURSOR   -- focused button
  self.pressed    = nil              -- button held down (mouse/touch/key), or nil
  self.confirming = nil              -- id of the button whose fade-out is playing
  self.confirm_t  = 0
  self.font       = Font.get("charstit")

  self.buttons = {}
  for i, b in ipairs(BUTTONS) do
    local up = img("assets/mission/" .. b.id .. ".png")
    self.buttons[i] = {
      id   = b.id, x = b.x,
      up   = up,                                      -- released frame
      down = img("assets/mission/" .. b.id .. "_hi.png"),  -- pressed frame
      w    = up and up:getWidth()  or 0,
      h    = up and up:getHeight() or 0,
    }
  end

  self.focus = img("assets/hud/selfocus_f01.png")     -- ring around focused button

  local raw = love.filesystem.read("data/mission_text.json")
  self.text = raw and json.decode(raw) or {}

  self._cache = {}  -- path -> image | false
end

function MissionMenu:is_active() return self.active end
function MissionMenu:close() self.active = false end

function MissionMenu:_img(path)
  if self._cache[path] == nil then
    self._cache[path] = img(path) or false
  end
  return self._cache[path] or nil
end

-- Wraps text to width w (design px) using the CHARS advances.
function MissionMenu:_wrap(text, w)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local try = (line == "") and word or (line .. " " .. word)
    if line ~= "" and self.font:width(try) > w then
      lines[#lines + 1] = line
      line = word
    else
      line = try
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- stage_name is "stageMP": M = mission (0-4), P = phase (0-3). The backdrop,
-- phase title and objective icons are 1-based on the phase, and the mission
-- text is keyed by the raw stage name in mission_text.json.
function MissionMenu:open(stage_name)
  local m = tonumber(stage_name:sub(6, 6)) or 0
  local p = tonumber(stage_name:sub(7, 7)) or 0

  self.backdrop = self:_img(string.format("assets/fullscreen/STAGE0%d_MS.png", m))
  self.title    = self:_img(string.format("assets/mission/title_phase0%d.png", p + 1))
  self.icon     = self:_img(string.format("assets/phase/stage%d_phase%d_f00.png", m, p + 1))

  -- Original briefing text: one or more paragraphs (objective first, then any
  -- enemy/threat notes), each wrapped to the text column and separated by a gap.
  -- Already upper case in the source to match the yellow CHARSTIT body text.
  self.text_lines = {}
  local info = self.text[stage_name]
  if info and info.paragraphs then
    for pi, para in ipairs(info.paragraphs) do
      if pi > 1 then self.text_lines[#self.text_lines + 1] = { gap = true } end
      for _, l in ipairs(self:_wrap(para, TEXT_W)) do
        self.text_lines[#self.text_lines + 1] = { l }
      end
    end
  end

  self.cursor     = DEFAULT_CURSOR
  self.pressed    = nil
  self.confirming = nil
  self.confirm_t  = 0
  self.active     = true
end

-- Index of the button under a design-space point, or nil.
function MissionMenu:_button_at(dx, dy)
  for i, b in ipairs(self.buttons) do
    if b.up and dx >= b.x and dx <= b.x + b.w and dy >= BTN_Y and dy <= BTN_Y + b.h then
      return i
    end
  end
  return nil
end

-- Start the confirm fade-out for a button; the action fires in update() once the
-- fade finishes. idx (optional) keeps that button shown pressed during the fade.
function MissionMenu:_confirm(id, idx)
  self.confirming = id
  self.confirm_t  = 0
  self.pressed    = idx
end

-- Mouse/touch, window coords. Hover moves focus; press arms a button; release
-- over the same button confirms it (down-on-press, action on release). Input is
-- ignored once a confirm fade is playing.
function MissionMenu:hover(x, y)
  if not self.active or self.confirming then return end
  local i = self:_button_at(Pointer.to_design(x, y, DW, DH))
  if i then self.cursor = i end
end

function MissionMenu:press(x, y)
  if not self.active or self.confirming then return end
  local i = self:_button_at(Pointer.to_design(x, y, DW, DH))
  if i then self.cursor = i; self.pressed = i end
end

function MissionMenu:release(x, y)
  if not self.active or self.confirming then return end
  local i = self:_button_at(Pointer.to_design(x, y, DW, DH))
  local was = self.pressed
  self.pressed = nil
  if was and i == was then
    self:_confirm(self.buttons[was].id, was)
  end
end

function MissionMenu:keypressed(key)
  if not self.active or self.confirming then return end
  if key == "left" then
    self.cursor = (self.cursor - 2) % #self.buttons + 1
  elseif key == "right" then
    self.cursor = self.cursor % #self.buttons + 1
  elseif key == "return" or key == "space" or key == "kpenter" then
    self:_confirm(self.buttons[self.cursor].id, self.cursor)
  elseif key == "escape" then
    self:_confirm("exit")
  end
end

function MissionMenu:update(dt)
  if not self.confirming then return end
  self.confirm_t = self.confirm_t + dt
  if self.confirm_t >= CONFIRM_TIME then
    local id = self.confirming
    self.confirming = nil
    self.pressed = nil
    if self.on_select then self.on_select(id) end
  end
end

-- Whole-screen opacity: 1 normally, easing to 0 (through the black fill) while a
-- confirm is playing so the choice fades out before the caller acts.
function MissionMenu:_fade()
  if self.confirming then
    return math.max(0, 1 - self.confirm_t / CONFIRM_TIME)
  end
  return 1
end

function MissionMenu:draw()
  local g      = love.graphics
  local sw, sh = g.getDimensions()
  local sc     = math.min(sw / DW, sh / DH)
  local fade   = self:_fade()  -- content alpha; dissolves into the black fill

  g.setColor(0, 0, 0, 1)
  g.rectangle("fill", 0, 0, sw, sh)

  g.push()
  g.translate((sw - DW * sc) / 2, (sh - DH * sc) / 2)
  g.scale(sc, sc)

  g.setColor(1, 1, 1, fade)
  if self.backdrop then
    g.draw(self.backdrop, 0, 0, 0, DW / self.backdrop:getWidth(), DH / self.backdrop:getHeight())
  end
  if self.title then
    g.draw(self.title, (DW - self.title:getWidth()) / 2, TITLE_Y)
  end
  if self.icon then
    g.draw(self.icon, ICON_X, ICON_Y)
  end

  local y = TEXT_Y
  for _, row in ipairs(self.text_lines) do
    if row.gap then
      y = y + PARA_GAP
    else
      self.font:print(row[1], TEXT_X, y, { color = { 1, 1, 1, fade } })
      y = y + self.font.line_height + LINE_GAP
    end
  end

  for i, b in ipairs(self.buttons) do
    local sprite = (self.pressed == i) and b.down or b.up
    if sprite then
      g.setColor(1, 1, 1, fade)
      g.draw(sprite, b.x, BTN_Y)
    end
  end

  -- Focus ring around the focused button (drawn on top; SELFOCUS is a hollow
  -- rectangle, so the button stays visible). Stretched to the button bounds.
  local fb = self.buttons[self.cursor]
  if self.focus and fb and fb.up then
    g.setColor(1, 1, 1, fade)
    g.draw(self.focus, fb.x - FOCUS_PAD, BTN_Y - FOCUS_PAD, 0,
      (fb.w + FOCUS_PAD * 2) / self.focus:getWidth(),
      (fb.h + FOCUS_PAD * 2) / self.focus:getHeight())
  end

  g.pop()
  g.setColor(1, 1, 1, 1)
end

return MissionMenu
