-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json        = require "lib.json"
local MapCompiler = require "engine.game.map_compiler"

-- What the map editor can place, read from the pack: one entry per sprite and
-- kind of an art set (a mission's stages), with the classes the original sets
-- on the same spot kept together as one entry (a turret on its hull, a gun on
-- its base, a tank under its hangar). Also resolves a map type to what the
-- editor draws and lists for it. Labels, categories and layers come from
-- data/editor.json.
local Catalog = {}

local DATA_PATH  = "data/editor.json"
local RULES_PATH = "data/enemy_weapons.json"

local BASE_FLAG = 0x40

-- Which class of a stack an entry is filed under.
local KIND_RANK = { tank = 5, structure = 4, flak_turret = 3, radar = 2, ground_decal = 1 }
-- Kinds that are not listed on their own when they mostly ride on another class.
local PART_KINDS = { flak_turret = true, radar = true, ground_decal = true }

-- Kinds of the objective marks, which never count as part of a stack.
local MARK_KINDS = {
    [MapCompiler.KIND_POW_MARKER] = true, [MapCompiler.KIND_PERSON] = true, [MapCompiler.KIND_PAD] = true,
}

local KIND_LAYER = {
    tank = "units", truck = "units", soldier = "units", soldier_aggressive = "units", enemy_helicopter = "units",
    flak_turret = "guns", radar = "guns", structure = "buildings", tree = "scenery", scenery = "scenery",
    ground_decal = "ground", powerup_marker = "objectives", unknown_14 = "objectives", civilian = "objectives",
}

local data, rules
local images     = {}   -- path -> Image or false
local by_art     = {}   -- art -> { list, by_category, by_key }
local type_infos = setmetatable({}, { __mode = "k" })   -- map type -> info

function Catalog.data()
    if not data then
        local raw = love.filesystem.read(DATA_PATH)
        if not raw then error("missing " .. DATA_PATH) end
        data = json.decode(raw)
    end
    return data
end

local function enemy_rules()
    if not rules then rules = json.decode(love.filesystem.read(RULES_PATH) or "{}") end
    return rules
end

local function has_flag(flags, bit)
    return math.floor((flags or 0) / bit) % 2 == 1
end

Catalog.has_flag = has_flag

function Catalog.image(dir, file)
    local path = "assets/" .. dir .. "/" .. file
    local img  = images[path]
    if img == nil then
        img = love.filesystem.getInfo(path) and love.graphics.newImage(path) or false
        if img then img:setFilter("nearest", "nearest") end
        images[path] = img
    end
    return img or nil
end

-- Art sets of the editor: { art, label, present }.
function Catalog.arts()
    local out = {}
    for _, item in ipairs(Catalog.data().art) do
        out[#out + 1] = { art = item.art, label = item.label, present = #Catalog.stages(item.art) > 0 }
    end
    return out
end

function Catalog.art_label(art)
    for _, item in ipairs(Catalog.data().art) do
        if tostring(item.art) == tostring(art) then return item.label end
    end
    return "ART " .. tostring(art)
end

-- Pack stages of an art set (stageA0..stageA3), those present.
function Catalog.stages(art)
    local out = {}
    for _, item in ipairs(love.filesystem.getDirectoryItems("assets")) do
        local name = item:match("^(stage" .. tostring(art) .. "%d)%.json$")
        if name then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

local function all_stages()
    local out = {}
    for _, item in ipairs(love.filesystem.getDirectoryItems("assets")) do
        local name = item:match("^(stage%d%d)%.json$")
        if name then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

function Catalog.label(stem, kind_name)
    local names = Catalog.data().names
    if kind_name == "soldier_aggressive" and stem == "enemy" then return "SOLDIER (MISSILE)" end
    return names[stem] or stem:upper()
end

function Catalog.layer_of(cls, stem)
    local home = Catalog.data().home_pad
    if cls.kind_name == "ground_decal" and (stem == home.pad or stem == home.mark) then return "base" end
    if cls.kind_name == "structure" and has_flag(cls.flags, BASE_FLAG) then return "base" end
    return KIND_LAYER[cls.kind_name] or "scenery"
end

-- What a map type resolves to: its class fields with the type's changes, its
-- sprite and the layer it is filed under. ok is false when this pack lacks it.
function Catalog.type_info(map_type)
    local info = type_infos[map_type]
    if info then return info end
    local cls, pack = MapCompiler.type_source(map_type)
    if not cls then
        info = { ok = false, cls = {}, kind_name = "missing", stem = map_type.sprite or "?", layer = "scenery",
                 w = 16, h = 16, ox = -8, oy = -8, label = (map_type.sprite or "?"):upper() }
    else
        local fields = {}
        for k, v in pairs(cls) do fields[k] = v end
        for k, v in pairs(map_type.set or {}) do fields[k] = v end
        local stem   = MapCompiler.asset_stem(pack, cls) or "?"
        local render = cls.render
        local img    = render and Catalog.image(pack.name, render.image)
        local w, h   = 16, 16
        if img then w, h = img:getDimensions() end
        info = {
            ok = true, cls = fields, kind = fields.kind, kind_name = fields.kind_name, stem = stem,
            img = img, ox = render and render.ox or -8, oy = render and render.oy or -8, w = w, h = h,
            layer = Catalog.layer_of(fields, stem), label = Catalog.label(stem, fields.kind_name),
        }
    end
    type_infos[map_type] = info
    return info
end

local function category_of(kind_name)
    for _, category in ipairs(Catalog.data().categories) do
        for _, kind in ipairs(category.kinds) do
            if kind == kind_name then return category.id end
        end
    end
    return nil
end

local function is_ride(cls)
    local modes = enemy_rules().movement[cls.kind_name]
    local mode  = modes and modes[tostring(cls.behaviour or 0)]
    return mode and mode.ride_heading ~= nil
end

-- How plain a class is: the template of an entry is the variant without
-- objective or base duties, which the inspector then adds.
local function plain(cls)
    if cls.kind_name == "structure" then
        return (has_flag(cls.flags, BASE_FLAG) or (cls.pows or 0) > 0 or cls.is_target or (cls.behaviour or 0) ~= 0)
            and 0 or 1
    end
    return 1
end

local function part_of(pack, index)
    return { from = pack.name, class = index, sprite = MapCompiler.asset_stem(pack, pack.classes[index + 1]) }
end

local function add_stage(found, pack)
    local share = Catalog.data().stack_share
    local home  = Catalog.data().home_pad
    -- The stack each class leads, and how often a class rides on another.
    local lead, rides = {}, {}
    for _, found_stack in pairs(pack.stacks) do
        -- Objective marks and the home pad are placed by the editor itself: a
        -- flag over its building or a pad on its circle is no stack.
        local stack = { classes = {}, count = found_stack.count }
        for _, index in ipairs(found_stack.classes) do
            local cls  = pack.classes[index + 1]
            local stem = MapCompiler.asset_stem(pack, cls)
            if not MARK_KINDS[cls.kind] and stem ~= home.pad and stem ~= home.mark then
                stack.classes[#stack.classes + 1] = index
            end
        end
        if #stack.classes > 1 then
            local main, rank = nil, -1
            for _, index in ipairs(stack.classes) do
                local r = KIND_RANK[pack.classes[index + 1].kind_name] or 0
                if r > rank then main, rank = index, r end
            end
            if not lead[main] or stack.count > lead[main].count then lead[main] = stack end
            for _, index in ipairs(stack.classes) do
                if index ~= main then rides[index] = (rides[index] or 0) + stack.count end
            end
        end
    end

    for index, uses in pairs(pack.uses) do
        local cls      = pack.classes[index + 1]
        local stem     = MapCompiler.asset_stem(pack, cls)
        local category = category_of(cls.kind_name)
        local is_home  = cls.kind_name == "ground_decal" and (stem == home.pad or stem == home.mark)
        local is_part  = PART_KINDS[cls.kind_name] and (rides[index] or 0) >= share * uses
        if stem and category and cls.render and not is_part and not is_home then
            local stack = lead[index]
            if stack and stack.count < share * uses then stack = nil end
            local parts, main = {}, 1
            for i, member in ipairs(stack and stack.classes or { index }) do
                parts[i] = part_of(pack, member)
                if member == index then main = i end
            end
            local key   = stem .. "/" .. cls.kind_name
            local label = Catalog.label(stem, cls.kind_name)
            if cls.kind_name == "tank" and is_ride(cls) then
                key   = key .. "/ride"
                label = "HANGAR " .. label
            elseif cls.kind_name == "structure" and has_flag(cls.flags, BASE_FLAG) then
                key      = key .. "/base"
                category = "base"
            end
            local score = (#parts > 1 and 1000000 or 0) + plain(cls) * 100000 + uses
            local best  = found[key]
            if not best or score > best.score then
                found[key] = { key = key, label = label, category = category, kind_name = cls.kind_name,
                               parts = parts, main = main, score = score }
            end
        elseif is_home and stem == home.pad and cls.render then
            -- The home pad, with the heliport mark the stage stamps on it when it has one.
            local parts = { part_of(pack, index) }
            for _, stack in pairs(pack.stacks) do
                local has_pad, mark = false, nil
                for _, member in ipairs(stack.classes) do
                    local s = MapCompiler.asset_stem(pack, pack.classes[member + 1])
                    if member == index then has_pad = true elseif s == home.mark then mark = member end
                end
                if has_pad and mark and pack.classes[mark + 1].render then parts[2] = part_of(pack, mark) end
            end
            local best = found["home"]
            if not best or #parts > #best.parts then
                found["home"] = { key = "home", label = "HOME PAD", category = "base", kind_name = "ground_decal",
                                  parts = parts, main = 1, home = true, score = 0 }
            end
        end
    end
end

-- The entries of an art set: { list, by_category = { id -> entries }, by_key }.
function Catalog.entries(art)
    art = tostring(art)
    if by_art[art] then return by_art[art] end
    local found = {}
    for _, name in ipairs(Catalog.stages(art)) do
        local pack = MapCompiler.pack_stage(name)
        if pack then add_stage(found, pack) end
    end
    -- An art set whose stages never stamp a home pad borrows one.
    if not found["home"] then
        local pad = Catalog.feature(art, "home")
        if pad then
            found["home"] = { key = "home", label = "HOME PAD", category = "base", kind_name = "ground_decal",
                              parts = { pad }, main = 1, home = true, score = 0 }
        end
    end
    local list, by_category = {}, {}
    for _, entry in pairs(found) do list[#list + 1] = entry end
    table.sort(list, function(a, b)
        if (a.home or false) ~= (b.home or false) then return a.home or false end
        if a.label ~= b.label then return a.label < b.label end
        return a.key < b.key
    end)
    -- Two entries of one name in a category differ by kind: say which.
    local seen = {}
    for _, entry in ipairs(list) do
        local id = entry.category .. ":" .. entry.label
        seen[id] = (seen[id] or 0) + 1
    end
    for _, entry in ipairs(list) do
        if seen[entry.category .. ":" .. entry.label] > 1 then
            entry.label = entry.label .. " (" .. entry.kind_name:upper():gsub("_", " ") .. ")"
        end
        entry.art = art
        by_category[entry.category] = by_category[entry.category] or {}
        table.insert(by_category[entry.category], entry)
    end
    by_art[art] = { list = list, by_category = by_category, by_key = found }
    return by_art[art]
end

local FEATURES = {
    flag       = function(cls) return cls.kind == MapCompiler.KIND_POW_MARKER end,
    pickup_pad = function(cls) return cls.kind == MapCompiler.KIND_PAD and cls.behaviour == 1 end,
    drop_pad   = function(cls) return cls.kind == MapCompiler.KIND_PAD and cls.behaviour ~= 1 end,
    any_pad    = function(cls) return cls.kind == MapCompiler.KIND_PAD end,
    person     = function(cls) return cls.kind == MapCompiler.KIND_PERSON end,
    home       = function(cls, stem)
        return cls.kind_name == "ground_decal" and stem == Catalog.data().home_pad.pad
    end,
}

local feature_cache = {}

-- A class the objectives need (a POW flag, a landing pad, a waiting person, a
-- home pad): a part { from, class, sprite } from the art set's own stages when
-- one of them has it, else from any stage of the pack. nil when none does.
function Catalog.feature(art, what)
    local key = tostring(art) .. "/" .. what
    if feature_cache[key] ~= nil then return feature_cache[key] or nil end
    local test  = FEATURES[what]
    local names = Catalog.stages(art)
    for _, name in ipairs(all_stages()) do names[#names + 1] = name end
    local hit
    for _, name in ipairs(names) do
        local pack = MapCompiler.pack_stage(name)
        for _, cls in ipairs(pack and pack.classes or {}) do
            if cls.render and (pack.uses[cls.index] or 0) > 0 and test(cls, MapCompiler.asset_stem(pack, cls)) then
                hit = part_of(pack, cls.index)
                break
            end
        end
        if hit then break end
    end
    feature_cache[key] = hit or false
    return hit
end

-- Inspector choices

local function weapon_label(name)
    return Catalog.data().weapons[name] or tostring(name):upper():gsub("ENEMY_", ""):gsub("_", " ")
end

-- The firing routines a gun can run: { label, value }.
function Catalog.routines()
    local out = {}
    for key, routine in pairs(enemy_rules().routines or {}) do
        local shots = routine.shots or {}
        local text  = weapon_label(shots[1] and shots[1].weapon)
        if #shots > 1 then text = text .. " X" .. #shots end
        if routine.burst then text = text .. ", BURST " .. routine.burst end
        out[#out + 1] = { label = string.format("%d  %s", tonumber(key), text), value = tonumber(key) }
    end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

function Catalog.soldier_modes()
    local out = {}
    local soldier = enemy_rules().soldier or {}
    for key, weapon in pairs(soldier.weapons or {}) do
        local text = weapon_label(weapon)
        if soldier.wander and soldier.wander[key] then text = text .. ", WANDERS" end
        out[#out + 1] = { label = text, value = tonumber(key) }
    end
    out[#out + 1] = { label = "PROXIMITY MINE", value = 2 }
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

function Catalog.heli_modes()
    local out = {}
    for key, mode in pairs((enemy_rules().helicopter or {}).modes or {}) do
        local text = weapon_label(mode.weapon)
        if mode.turn_scale then text = text .. ", AGILE" end
        out[#out + 1] = { label = text, value = tonumber(key) }
    end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

-- How a route unit of this kind can move: { label, value } for the class
-- behaviours that are not a hangar ride.
function Catalog.movements(kind_name)
    local out, plain_loop = {}, false
    for key, mode in pairs(enemy_rules().movement[kind_name] or {}) do
        if type(mode) == "table" and not mode.ride_heading then
            local text = mode.once and "ROUTE, ONCE" or "ROUTE, ROUND AND ROUND"
            if mode.pause then text = "ROUTE, WITH A STOP" end
            out[#out + 1] = { label = text, value = tonumber(key) }
            if tonumber(key) == 0 then plain_loop = true end
        end
    end
    -- A behaviour the table does not list drives its route round and round.
    if not plain_loop then out[#out + 1] = { label = "ROUTE, ROUND AND ROUND", value = 0 } end
    table.sort(out, function(a, b) return a.value < b.value end)
    return out
end

Catalog.is_ride = is_ride

return Catalog
