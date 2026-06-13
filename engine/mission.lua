local Class = require "engine.class"
local json  = require "lib.json"

local Mission = Class()

local defs = {}   -- stage_name -> mission def, loaded once

function Mission.load(path)
  local raw = love.filesystem.read(path)
  defs = raw and json.decode(raw) or {}
end

-- Build a mission for the named stage, or nil if it has no defined objectives.
function Mission.for_stage(world, player, stage_name)
  local def = defs[stage_name]
  if not def then return nil end
  return Mission:new(world, player, def)
end

-- True if entity e satisfies a spec's filters: asset (.bin) filename, kind_name,
-- and a minimum sprite size (largest dimension), any of which may be omitted.
local function entity_matches(world, e, spec)
  if spec.target then
    local f = world:asset_file(e.class_idx)
    if not f or f:lower() ~= spec.target:lower() then return false end
  end
  if spec.kind then
    local cls = world.stage.classes[e.class_idx + 1]
    if not cls or cls.kind_name ~= spec.kind then return false end
  end
  if spec.min_size then
    local r = world.images[e.class_idx + 1]
    local w, h = 0, 0
    if r and r.img then w, h = r.img:getDimensions() end
    if math.max(w, h) < spec.min_size then return false end
  end
  return true
end

function Mission:init(world, player, def)
  self.world       = world
  self.player      = player
  self.def         = def
  self.briefing    = def.briefing
  self.home_radius  = def.home_radius or 48
  self.state       = "active"   -- active -> return_to_base -> won | failed
  self.objectives  = {}
  for _, spec in ipairs(def.objectives or {}) do
    self.objectives[#self.objectives + 1] = self:_make_objective(spec)
  end

  -- Return-to-base point: an explicit pad sprite for stages whose friendly base
  -- is not the auto-detected basecirc.bin / h.bin, otherwise the world's home pad.
  if def.home_base_asset then
    for _, e in ipairs(self:_collect({ target = def.home_base_asset })) do
      self.home_x, self.home_y = e.x, e.y
      break
    end
  end
  if not self.home_x then self.home_x, self.home_y = world:home_base() end
end

function Mission:_collect(spec)
  local list = {}
  for _, e in ipairs(self.world.entities) do
    if entity_matches(self.world, e, spec) then list[#list + 1] = e end
  end
  return list
end

function Mission:_make_objective(spec)
  local o = { spec = spec, type = spec.type, done = false, progress = 0 }
  if spec.type == "destroy" then
    o.matching = self:_collect(spec)
    o.counted  = {}
    o.target   = (spec.count == nil or spec.count == "all")
      and #o.matching or math.min(spec.count, #o.matching)
  elseif spec.type == "rescue" then
    o.zones     = self:_collect(spec)
    o.collected = {}
    o.radius    = spec.radius or 40
    o.target    = spec.count or #o.zones
  elseif spec.type == "sabotage" then
    o.targets = {}
    for _, e in ipairs(self:_collect(spec)) do
      o.targets[#o.targets + 1] = { ent = e, state = "pending", timer = 0 }
    end
    o.radius      = spec.deploy_radius or 40
    o.deploy_time = spec.deploy_time or 1.5
    o.deployed    = 0
    o.evacuated   = 0
    o.detonated   = false
  end
  -- An objective with nothing to act on is satisfied so it can never block a win.
  if (o.target == 0) or (spec.type == "sabotage" and #o.targets == 0)
  or not (spec.type == "destroy" or spec.type == "rescue" or spec.type == "sabotage") then
    o.done = true
  end
  return o
end

-- ── per-frame progress ─────────────────────────────────────────────────────────

function Mission:update(dt)
  if self.state == "won" or self.state == "failed" then return end
  if self.player.death then self.state = "failed"; return end

  local all_done = true
  for _, o in ipairs(self.objectives) do
    if not o.done then
      self:_update_objective(o, dt)
      if not o.done then all_done = false end
    end
  end

  if all_done then
    if self.state == "active" then self.state = "return_to_base" end
    if self:_at_home_base() then self.state = "won" end
  end
end

function Mission:_update_objective(o, dt)
  if     o.type == "destroy"  then self:_update_destroy(o)
  elseif o.type == "rescue"   then self:_update_rescue(o)
  elseif o.type == "sabotage" then self:_update_sabotage(o, dt) end
end

function Mission:_update_destroy(o)
  for _, e in ipairs(o.matching) do
    if not o.counted[e.id] and not e:is_alive() then
      o.counted[e.id] = true
      o.progress = o.progress + 1
    end
  end
  if o.progress >= o.target then o.done = true end
end

function Mission:_update_rescue(o)
  if self.player:is_stationary() then
    for _, z in ipairs(o.zones) do
      if not o.collected[z.id] then
        local dx, dy = self.player.x - z.x, self.player.y - z.y
        if dx * dx + dy * dy <= o.radius * o.radius then
          o.collected[z.id] = true
          o.progress = o.progress + 1
          self.player.pows = (self.player.pows or 0) + 1
        end
      end
    end
  end
  if o.progress >= o.target then o.done = true end
end

-- Land in front of each marked building to plant a charge; once every charge is
-- set the buildings blow, then the player must return to each to recover the
-- unit (evacuate). Charges and recovery accumulate dwell time while stationary.
function Mission:_update_sabotage(o, dt)
  local near = nil
  if self.player:is_stationary() then
    for _, t in ipairs(o.targets) do
      local dx, dy = self.player.x - t.ent.x, self.player.y - t.ent.y
      if dx * dx + dy * dy <= o.radius * o.radius then near = t; break end
    end
  end

  if not o.detonated then
    if near and near.state == "pending" then
      near.timer = near.timer + dt
      if near.timer >= o.deploy_time then
        near.state = "deployed"
        o.deployed = o.deployed + 1
      end
    end
    if o.deployed >= #o.targets then
      for _, t in ipairs(o.targets) do
        if t.ent:is_alive() then t.ent:take_damage(t.ent.hp + 1) end
        t.state = "armed"
      end
      o.detonated = true
    end
  else
    if near and near.state == "armed" then
      near.timer = near.timer + dt
      if near.timer >= o.deploy_time * 2 then
        near.state = "evacuated"
        o.evacuated = o.evacuated + 1
      end
    end
    if o.evacuated >= #o.targets then o.done = true end
  end
end

function Mission:_at_home_base()
  if not self.home_x then return true end   -- no pad on this stage: win on objectives
  if not self.player:is_stationary() then return false end
  local dx, dy = self.player.x - self.home_x, self.player.y - self.home_y
  return dx * dx + dy * dy <= self.home_radius * self.home_radius
end

-- ── presentation ───────────────────────────────────────────────────────────────

function Mission:objective_label(o)
  local s = o.spec
  if o.type == "destroy" then
    return string.format("%s  %d/%d",
      s.label or ("Destroy " .. (s.target or s.kind or "targets")), o.progress, o.target)
  elseif o.type == "rescue" then
    return string.format("%s  %d/%d", s.label or "Rescue people", o.progress, o.target)
  elseif o.type == "sabotage" then
    if not o.detonated then
      return string.format("%s  %d/%d planted", s.label or "Plant charges", o.deployed, #o.targets)
    end
    return string.format("Evacuate units  %d/%d", o.evacuated, #o.targets)
  end
  return s.label or o.type
end

return Mission
