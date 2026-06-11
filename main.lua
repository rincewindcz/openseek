-- Seek and Destroy level viewer.
-- Renders a stage exported by tools/export_love2d.py: every entity as
-- its canonical sprite (the class's frame_base pose), ground decals first,
-- the rest sorted by y. Single orientation, no animation.
--
-- Rotation-arc art is offset by one step: frame k of an arc is the true
-- pose rotated clockwise by (k+1)*(360/angle_steps) degrees, so no file
-- frame is exactly axis-aligned, and every non-90-degree copy carries
-- rotation deformities from the prerendering. The exporter picks the
-- arc's exact 90 degree frame (the only lossless copy, e.g. f15 for
-- steps=64) and the viewer rotates it back by -90 degrees about its
-- anchor, which is again lossless (see SPRITES.md).
--
-- Road/path segments are drawn in their real colors: the segment record's
-- value field is the palette index the engine passes to its line drawer at
-- 0x1df450 (the exporter resolves it to RGB via the mission's PAL1.BIN).
-- They render above ground decals and below everything else. The white
-- corner studs visible in-game are ordinary entities (post.bin).
--
-- Run:  love .            (defaults to first available stage)
--       love . stage02
--
-- Controls: WASD/arrows pan, wheel or +/- zoom (anchored at mouse),
--           Tab stage picker, PgUp/PgDn cycle stages, L segments,
--           G grid, Esc quit.

local json = require "json"

-- Ground fill per mission (stage name "stage{M}{P}", M = mission digit).
-- The engine clears with palette entry 49 of STAGE0M/PAL1.BIN; these RGB
-- values are sampled from DOSBox-X gameplay screenshots of all 5 missions
-- and match that entry exactly (6-bit DAC -> 8-bit: (c<<2)|(c>>4)).
local MISSION_GROUND = {
  ["0"] = { 178 / 255, 125 / 255, 81 / 255 },  -- tan
  ["1"] = { 195 / 255, 195 / 255, 215 / 255 }, -- snow
  ["2"] = { 138 / 255, 125 / 255, 81 / 255 },  -- olive
  ["3"] = { 81 / 255, 28 / 255, 0 },           -- volcanic
  ["4"] = { 150 / 255, 125 / 255, 97 / 255 },  -- grey-tan
}
local DEFAULT_GROUND = { 0.3, 0.5, 0 }

local function groundColor(name)
  local m = name and name:match("^stage(%d)")
  return MISSION_GROUND[m] or DEFAULT_GROUND
end

-- Discrete zoom ladder: integer-friendly steps render crisply with
-- nearest-neighbor filtering; arbitrary fractional zooms shimmer.
local ZOOMS = { 0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8 }

local stages = {}    -- available stage names, sorted
local stage          -- decoded JSON of the current stage
local stageName
local stageIndex = 1
local images = {}    -- asset index+1 -> Image or false
local drawDecals = {}  -- ground decals (kind 15), below the segment lines
local drawObjects = {} -- everything else, above the lines
local cam = { x = 2048, y = 2048, zi = 4 } -- zi indexes ZOOMS
local showSegments = true
local showGrid = false
local picker = false

local function zoom() return ZOOMS[cam.zi] end

local function discoverStages()
  stages = {}
  for _, item in ipairs(love.filesystem.getDirectoryItems("assets")) do
    local name = item:match("^(stage%d+)%.json$")
    if name then stages[#stages + 1] = name end
  end
  table.sort(stages)
  if #stages == 0 then
    error("no assets/stageXX.json found - run tools/export_love2d.py first")
  end
end

local function loadStage(name)
  local data = love.filesystem.read("assets/" .. name .. ".json")
  if not data then return end
  stage = json.decode(data)
  stageName = name
  for i, s in ipairs(stages) do
    if s == name then stageIndex = i end
  end

  -- per-class canonical image (frame_base pose) with exact draw offsets
  images = {}
  local cache = {}
  for i, c in ipairs(stage.classes) do
    if c.render then
      local path = "assets/" .. name .. "/" .. c.render.image
      if not cache[path] and love.filesystem.getInfo(path) then
        cache[path] = love.graphics.newImage(path)
      end
      local rot = c.angle_steps > 1 and -math.pi / 2 or 0
      images[i] = cache[path] and
        { img = cache[path], ox = c.render.ox, oy = c.render.oy, rot = rot }
        or nil
    end
  end

  -- decals (kind 15) below the segment lines, the rest above; y-sorted
  drawDecals, drawObjects = {}, {}
  for _, e in ipairs(stage.entities) do
    local list = stage.classes[e.class + 1].kind == 15 and drawDecals
      or drawObjects
    list[#list + 1] = e
  end
  local byY = function(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
  end
  table.sort(drawDecals, byY)
  table.sort(drawObjects, byY)

  love.window.setTitle("Seek & Destroy - " .. name .. " (" ..
    #stage.entities .. " entities)")
end

function love.load(args)
  love.graphics.setDefaultFilter("nearest", "nearest")
  discoverStages()
  loadStage(args[1] or stages[1])
end

function love.update(dt)
  if picker then return end
  local speed = 600 / zoom() * dt
  local kb = love.keyboard.isDown
  if kb("a") or kb("left") then cam.x = cam.x - speed end
  if kb("d") or kb("right") then cam.x = cam.x + speed end
  if kb("w") or kb("up") then cam.y = cam.y - speed end
  if kb("s") or kb("down") then cam.y = cam.y + speed end
  cam.x = math.max(0, math.min(stage.world_size, cam.x))
  cam.y = math.max(0, math.min(stage.world_size, cam.y))
end

-- Change zoom level keeping the world point under (mx, my) fixed.
local function setZoom(zi, mx, my)
  zi = math.max(1, math.min(#ZOOMS, zi))
  if zi == cam.zi then return end
  local w, h = love.graphics.getDimensions()
  mx = mx or w / 2
  my = my or h / 2
  local oldz = zoom()
  local wx = cam.x + (mx - w / 2) / oldz
  local wy = cam.y + (my - h / 2) / oldz
  cam.zi = zi
  local newz = zoom()
  cam.x = wx - (mx - w / 2) / newz
  cam.y = wy - (my - h / 2) / newz
  cam.x = math.max(0, math.min(stage.world_size, cam.x))
  cam.y = math.max(0, math.min(stage.world_size, cam.y))
end

function love.wheelmoved(_, dy)
  if picker then return end
  local mx, my = love.mouse.getPosition()
  setZoom(cam.zi + (dy > 0 and 1 or -1), mx, my)
end

function love.keypressed(key)
  if picker then
    if key == "escape" or key == "tab" then
      picker = false
    elseif key == "up" then
      stageIndex = (stageIndex - 2) % #stages + 1
    elseif key == "down" then
      stageIndex = stageIndex % #stages + 1
    elseif key == "return" then
      picker = false
      loadStage(stages[stageIndex])
    end
    return
  end

  if key == "escape" then love.event.quit() end
  if key == "tab" then picker = true end
  if key == "pagedown" then
    loadStage(stages[stageIndex % #stages + 1])
  end
  if key == "pageup" then
    loadStage(stages[(stageIndex - 2) % #stages + 1])
  end
  if key == "l" then showSegments = not showSegments end
  if key == "g" then showGrid = not showGrid end
  if key == "+" or key == "=" or key == "kp+" then setZoom(cam.zi + 1) end
  if key == "-" or key == "kp-" then setZoom(cam.zi - 1) end
end

local function drawWorld()
  local g = love.graphics
  local w, h = g.getDimensions()
  local z = zoom()

  g.clear(groundColor(stageName))
  g.push()
  g.translate(w / 2, h / 2)
  g.scale(z)
  g.translate(-cam.x, -cam.y)

  local half_w, half_h = w / 2 / z, h / 2 / z
  local x0, x1 = cam.x - half_w - 64, cam.x + half_w + 64
  local y0, y1 = cam.y - half_h - 64, cam.y + half_h + 64

  local function drawEntities(list)
    g.setColor(1, 1, 1)
    for _, e in ipairs(list) do
      if e.x >= x0 and e.x <= x1 and e.y >= y0 and e.y <= y1 then
        local r = images[e.class + 1]
        if r then
          g.draw(r.img, e.x, e.y, r.rot, 1, 1, -r.ox, -r.oy)
        else
          g.setColor(1, 0, 1)
          g.circle("fill", e.x, e.y, 3)
          g.setColor(1, 1, 1)
        end
      end
    end
  end

  drawEntities(drawDecals)

  if showSegments then
    g.setLineStyle("rough")
    g.setLineWidth(1)
    for _, s in ipairs(stage.segments) do
      g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255)
      g.line(s.x1, s.y1, s.x2, s.y2)
    end
    g.setColor(1, 1, 1)
  end

  drawEntities(drawObjects)

  if showGrid then
    g.setColor(0, 0, 0, 0.2)
    g.setLineWidth(1 / z)
    for i = 0, stage.world_size, 256 do
      g.line(i, 0, i, stage.world_size)
      g.line(0, i, stage.world_size, i)
    end
    g.setColor(1, 1, 1)
  end

  g.pop()
end

local function drawPicker()
  local g = love.graphics
  local w, h = g.getDimensions()
  local lh = 28
  local bw, bh = 280, #stages * lh + 50
  local bx, by = (w - bw) / 2, (h - bh) / 2
  g.setColor(0, 0, 0, 0.85)
  g.rectangle("fill", bx, by, bw, bh, 6)
  g.setColor(1, 1, 1)
  g.print("Select stage (Enter)", bx + 16, by + 12)
  for i, name in ipairs(stages) do
    local y = by + 40 + (i - 1) * lh
    if i == stageIndex then
      g.setColor(1, 1, 0)
      g.rectangle("line", bx + 10, y - 4, bw - 20, lh - 4)
    else
      g.setColor(0.8, 0.8, 0.8)
    end
    g.print(name, bx + 20, y)
  end
  g.setColor(1, 1, 1)
end

function love.draw()
  local g = love.graphics
  drawWorld()

  g.setColor(0, 0, 0, 0.6)
  g.rectangle("fill", 0, 0, 440, 22)
  g.setColor(1, 1, 1)
  g.print(string.format(
    "%s  cam %d,%d  zoom %gx  [Tab] stages [PgUp/PgDn] [L]ines [G]rid",
    stageName, cam.x, cam.y, zoom()), 4, 4)

  if picker then drawPicker() end
end
