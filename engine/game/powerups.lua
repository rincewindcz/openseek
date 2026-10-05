-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class      = require "engine.core.class"
local json       = require "lib.json"
local Animation  = require "engine.core.animation"
local Config     = require "engine.core.config"
local Vehicles   = require "engine.game.vehicles"
local Difficulty = require "engine.game.difficulty"

-- Power-ups as the original runs them. A destroyed building's drop is drawn
-- from a 16-entry table built per player when the phase starts: half armor,
-- half fuel, then about ten entries handed out evenly to the weapons the player
-- carries (so ammo only drops for those). Low fuel or armor biases the draw
-- and critical levels force it. A pickup lasts by the difficulty's pickup
-- level, blinks before it goes, and is taken inside a small box around the
-- vehicle. Tuning is data/powerups.json, times in ticks of 1 / tick_rate s.
-- EXTRA (weapon_finds): now and then the drop is a weapon the player does not
-- carry; taking it adds the weapon for the rest of the phase.
local Powerups = Class()

local DATA_PATH = "data/powerups.json"

function Powerups:init(world, camera, weapons)
    self.world     = world
    self.camera    = camera
    self.weapons   = weapons or {}
    self.player    = nil
    self.players   = {}   -- all players that can collect (1 normally, 2 in split)
    self.list      = {}   -- {x, y, kind, weapon, frame, find, age, ttl}
    self.tables    = {}   -- player -> its drop table
    -- F6 override: collect everything by flying over it, whatever the difficulty
    -- landing rules (Config.land_for_medals / land_for_supplies) say.
    self.easy_mode = false
    self._frames   = nil
    local raw = love.filesystem.read(DATA_PATH)
    if not raw then error("powerups: missing " .. DATA_PATH) end
    self.data = json.decode(raw)
end

function Powerups:_seconds(ticks)
    return ticks / (self.data.tick_rate or 70)
end

function Powerups:reset(player)
    self:set_players(player and { player } or {})
end

-- The collectors of the phase (two in split screen). Builds each one's drop
-- table, so it needs their weapon lists set.
function Powerups:set_players(players)
    self.players = players or {}
    self.player  = self.players[1]
    self.list    = {}
    self.tables  = {}
    for _, p in ipairs(self.players) do self.tables[p] = self:_build_table(p) end
end

function Powerups:_pickup_frames()
    if self._frames == nil then
        local clip = Animation.clip("pickup")
        self._frames = clip and clip.frames or false
    end
    return self._frames or nil
end

-- tables

function Powerups:_carried(p)
    return p.weapon_list or Vehicles.WEAPONS[p.vehicle] or {}
end

-- PICKUPS frame of a weapon's ammo for a vehicle, nil when it has none (the
-- chain gun and the air strike never drop).
function Powerups:_ammo_frame(weapon, vehicle)
    local frame = self.data.ammo_frames[weapon]
    if type(frame) == "table" then frame = frame[vehicle] end
    return frame
end

-- p's drop table: armor and fuel alternating, then ammo_share entries split
-- evenly among the carried weapons that have a pickup, each written over a
-- random entry still holding a supply.
function Powerups:_build_table(p)
    local d    = self.data
    local size = d.table_size or 16
    local drop = {}
    for i = 1, size do
        drop[i] = { kind = (i % 2 == 1) and "armor" or "fuel" }
    end
    local ammo = {}
    for _, weapon in ipairs(self:_carried(p)) do
        if self:_ammo_frame(weapon, p.vehicle) then ammo[#ammo + 1] = weapon end
    end
    local share = #ammo > 0 and math.floor((d.ammo_share or 10) / #ammo) or 0
    for _, weapon in ipairs(ammo) do
        for _ = 1, share do
            local i = self.world.rng:random(1, size)
            while drop[i].kind == "ammo" do i = i % size + 1 end
            drop[i] = { kind = "ammo", weapon = weapon }
        end
    end
    return drop
end

-- drops

function Powerups:_nearest_player(x, y)
    local best, best_d2
    for _, p in ipairs(self.players) do
        local dx, dy = self.world:delta(p.x, p.y, x, y)
        local d2 = dx * dx + dy * dy
        if not best_d2 or d2 < best_d2 then best, best_d2 = p, d2 end
    end
    return best
end

-- Weapons of p's vehicle that have a pickup and that p does not carry.
function Powerups:_missing_weapons(p)
    local carried = {}
    for _, weapon in ipairs(self:_carried(p)) do carried[weapon] = true end
    local out, seen = {}, {}
    for _, group in ipairs({ Vehicles.BAY_WEAPONS, Vehicles.SPECIAL_WEAPONS }) do
        for _, weapon in ipairs(group[p.vehicle] or {}) do
            if not carried[weapon] and not seen[weapon] and self.weapons[weapon]
            and self:_ammo_frame(weapon, p.vehicle) then
                seen[weapon] = true
                out[#out + 1] = weapon
            end
        end
    end
    return out
end

-- What a destroyed building drops for p: an entry of its table, with every
-- other entry turned to the supply p is low on, and a critical level forcing
-- that supply (fuel wins).
function Powerups:_roll(p)
    local d     = self.data
    local drop  = self.tables[p]
    local i     = self.world.rng:random(1, #drop)
    local entry = drop[i]
    local fuel  = p.max_fuel > 0 and p.fuel / p.max_fuel or 1
    if i % 2 == 0 then
        if fuel < d.low.fuel then
            entry = { kind = "fuel" }
        elseif p.armor < d.low.armor then
            entry = { kind = "armor" }
        end
    end
    if fuel < d.critical.fuel then return { kind = "fuel" } end
    if p.armor < d.critical.armor then return { kind = "armor" } end
    -- EXTRA (weapon_finds)
    local find = d.find or {}
    if Config.weapon_finds and self.world.rng:random() < (find.chance or 0) then
        local missing = self:_missing_weapons(p)
        if #missing > 0 then
            return { kind = "ammo", weapon = missing[self.world.rng:random(1, #missing)], find = true }
        end
    end
    return entry
end

-- forced is a kind name (a bunker's medal) or true for the table's draw.
function Powerups:_spawn(x, y, forced)
    local d = self.data
    local p = self:_nearest_player(x, y)
    if not p then return end
    local entry = type(forced) == "string" and { kind = forced } or self:_roll(p)
    local frame = d.frames[entry.kind]
    if entry.kind == "ammo" then frame = self:_ammo_frame(entry.weapon, p.vehicle) end
    if not frame then return end
    self.list[#self.list + 1] = {
        x = x, y = y, kind = entry.kind, weapon = entry.weapon, frame = frame, find = entry.find,
        age = 0, ttl = self:_seconds(d.lifetime[Difficulty.pickup_level()]),
    }
end

-- update

function Powerups:_needs_landing(kind)
    if kind == "medal" then return Config.land_for_medals end
    if kind == "fuel" or kind == "armor" then return Config.land_for_supplies end
    return false
end

-- True while any player is up: the pickups wait out a downed player.
function Powerups:_running()
    for _, p in ipairs(self.players) do
        if not p.death then return true end
    end
    return false
end

function Powerups:update(dt)
    -- Spawn from freshly destroyed buildings. drop_powerup is true (random) or a
    -- kind name string (forced drop, e.g. bunker -> medal).
    for _, e in ipairs(self.world.droppers) do
        if e.drop_powerup then
            local forced = e.drop_powerup
            e.drop_powerup = false
            self:_spawn(e.x, e.y, forced)
        end
    end
    if not self:_running() then return end

    local reach = self.data.reach or 16
    local live  = {}
    for _, pu in ipairs(self.list) do
        pu.age = pu.age + dt
        local taken = false
        for _, p in ipairs(self.players) do
            local dx, dy = self.world:delta(p.x, p.y, pu.x, pu.y)
            if not p.death and math.abs(dx) < reach and math.abs(dy) < reach then
                -- A pickup the difficulty says to land on needs the chopper landed on
                -- it (a tank is always grounded, so it collects either way); the rest
                -- are collected by flying over.
                local grounded = (not p.is_flyer) or (not p:is_flyer()) or p.land_state == "grounded"
                if self.easy_mode or grounded or not self:_needs_landing(pu.kind) then
                    self:_apply(pu, p)
                    taken = true
                    break
                end
            end
        end
        if not taken then
            if pu.age < pu.ttl then live[#live + 1] = pu else self.world:count("expired") end
        end
    end
    self.list = live
end

-- True once a pickup is in its blinking last seconds.
function Powerups:expiring(pu)
    return pu.ttl - pu.age < self:_seconds(self.data.blink or 300)
end

-- EXTRA (weapon_finds): p takes a weapon it does not carry and its vehicle can
-- use. It joins p's list for the rest of the phase with find.ammo of its
-- starting load (one round at least), and its ammo starts to drop. Returns
-- false when p already has it or cannot use it.
function Powerups:_grant(weapon, p)
    for _, name in ipairs(self:_carried(p)) do
        if name == weapon then return false end
    end
    local usable = false
    for _, name in ipairs(self:_missing_weapons(p)) do
        if name == weapon then usable = true end
    end
    if not usable then return false end
    -- The lists may be the equip loadout's own: extend copies.
    local list = {}
    for i, name in ipairs(self:_carried(p)) do list[i] = name end
    list[#list + 1] = weapon
    p.weapon_list = list
    if p.weapon_levels and not p.weapon_levels[weapon] then
        local levels = {}
        for name, level in pairs(p.weapon_levels) do levels[name] = level end
        levels[weapon] = 1
        p.weapon_levels = levels
    end
    local def = self.weapons[weapon]
    if def and def.ammo_max then
        local share = (self.data.find or {}).ammo or 0.15
        p.ammo[weapon] = math.max(1, math.floor(def.ammo_max * share + 0.5))
    end
    self.tables[p] = self:_build_table(p)
    return true
end

function Powerups:_apply(pu, p)
    local d = self.data
    self.world:pickup_taken(p, pu.kind)
    self.world:sound(pu.kind == "medal" and "pickup.medal" or "pickup.item", p.x, p.y)
    if pu.kind == "fuel" then
        p:refuel(p.max_fuel * (d.fuel_gain or 0.5))
    elseif pu.kind == "armor" then
        p:repair(p.max_armor * (d.armor_gain or 0.5))
    elseif pu.kind == "medal" then
        p.medals = (p.medals or 0) + 1
    elseif pu.kind == "ammo" then
        if not (pu.find and self:_grant(pu.weapon, p)) then
            local w = self.weapons[pu.weapon]
            p:add_ammo(pu.weapon, (w and w.ammo_pickup) or 0, d.ammo_cap)
        end
    end
end

-- draw

-- The frame a pickup shows now: the medal flips between its two frames, a
-- found weapon alternates its icon with the "GET" / "ME" frames.
function Powerups:_frame(pu)
    local d    = self.data
    local step = math.floor(pu.age / self:_seconds(d.medal_flip or 32))
    if type(pu.frame) == "table" then return pu.frame[step % #pu.frame + 1] end
    local call = pu.find and d.find and d.find.frames
    if call and step % 2 == 1 then return call[(step - 1) / 2 % #call + 1] end
    return pu.frame
end

function Powerups:draw()
    if #self.list == 0 then return end
    local frames = self:_pickup_frames()
    if not frames then return end
    local g = love.graphics
    g.push()
    self.camera:apply()
    -- Optionally keep pickups screen-upright (original behaviour) by cancelling the
    -- camera's world rotation; otherwise they rotate with the world.
    local rot        = Config.axis_aligned_pickups and -(self.camera.angle or 0) or 0
    local screen_rot = rot + (self.camera.angle or 0)
    local detailfx   = self.world.detailfx
    for _, t in ipairs(self.camera:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        for _, pu in ipairs(self.list) do
            local visible = not self:expiring(pu) or (math.floor(pu.age * 8) % 2 == 0)
            local img     = visible and frames[self:_frame(pu) + 1]
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1)
                g.draw(img, pu.x, pu.y, rot, 1, 1, iw / 2, ih / 2)
                if detailfx and not self:expiring(pu) then   -- EXTRA (pickup_glint)
                    detailfx:draw_glint(img, pu.x, pu.y, rot, screen_rot, pu.age)
                end
            end
        end
        g.pop()
    end
    g.setColor(1, 1, 1)
    g.pop()
end

return Powerups
