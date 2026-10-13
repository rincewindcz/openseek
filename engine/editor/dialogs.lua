-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local MapFile    = require "engine.game.map_file"
local Loadout    = require "engine.game.loadout"
local Vehicles   = require "engine.game.vehicles"
local Score      = require "engine.game.score"
local Difficulty = require "engine.game.difficulty"
local Catalog    = require "engine.editor.catalog"
local Generate   = require "engine.editor.generate"
local Cards      = require "engine.editor.cards"
local Goals      = require "engine.editor.goals"
local Validate   = require "engine.editor.validate"
local MissionMenu = require "engine.ui.mission_menu"

-- The dialogs of the map editor: map settings, new map, open, save as, ground
-- generator, key help and the yes / no questions. editor.dialog holds the open
-- one as { kind, ... }; Dialogs.draw asks the widget kit for it each frame.
local Dialogs = {}

local LABEL_W     = 150
local PARAGRAPHS  = 3     -- briefing paragraphs: the briefing screen has three text slots
local NAME_MAX    = 40
local TEXT_MAX    = 400
local CAPTION_MAX = 16    -- typed; Cards.caption cuts it to what fits across a card
local CARD_ZOOM   = 1.5   -- briefing cards shown this much larger in the settings
local MAX_LIVES   = 9
local GOAL_H      = 84    -- one objective in the settings' list
local RULES_H     = 138   -- the rules under that list

local function close(editor)
    editor.dialog = nil
    editor.kit:blur()
end

local function labelled(kit, x, y, text)
    kit:label(text, x, y, LABEL_W, kit.theme.row, { color = kit.theme.text_dim, size = kit.theme.font_small })
end

local function art_choices(with_default)
    local out = {}
    if with_default then out[1] = { label = "AS THE ART SET", value = "" } end
    for _, art in ipairs(Catalog.arts()) do
        out[#out + 1] = { label = art.label, value = tostring(art.art) }
    end
    return out
end

local function present_arts()
    local out = {}
    for _, art in ipairs(Catalog.arts()) do
        if art.present then out[#out + 1] = { label = art.label, value = tostring(art.art) } end
    end
    return out
end

local function size_choices()
    local out = {}
    for _, size in ipairs(Catalog.data().sizes) do
        out[#out + 1] = { label = string.format("%d X %d", size, size), value = size }
    end
    return out
end

local function stage_choices(art)
    local out = {}
    for _, name in ipairs(Catalog.stages(art)) do out[#out + 1] = { label = name:upper(), value = name } end
    return out
end

-- map settings

local SETTINGS_TABS = {
    { label = "GENERAL", value = "general" }, { label = "ENVIRONMENT", value = "environment" },
    { label = "LOADOUT", value = "loadout" }, { label = "DIFFICULTY", value = "difficulty" },
    { label = "OBJECTIVES", value = "objectives" }, { label = "BRIEFING", value = "briefing" },
}

-- Replace one key of the map's environment as a single undo step.
local function set_environment(editor, key, value)
    local env = {}
    for k, v in pairs(editor.doc.map.environment) do env[k] = v end
    env[key] = value
    editor.doc:set_map("environment", env, "ENVIRONMENT")
end

local function settings_general(editor, kit, x, y, w)
    local theme = kit.theme
    local doc   = editor.doc
    local map   = doc.map
    local fw    = w - LABEL_W
    labelled(kit, x, y, "NAME")
    local name, _, name_done = kit:field("set_name", x + LABEL_W, y, fw, map.name, { max = NAME_MAX, commit = true })
    if name_done and name ~= "" then doc:set_map("name", name) end
    y = y + theme.row + 6
    labelled(kit, x, y, "AUTHOR")
    local author, _, author_done = kit:field("set_author", x + LABEL_W, y, fw, map.author, { max = NAME_MAX, commit = true })
    if author_done then doc:set_map("author", author) end
    y = y + theme.row + 6
    labelled(kit, x, y, "MAP SIZE")
    local size, size_changed = kit:choice("set_size", x + LABEL_W, y, fw, size_choices(), map.size,
        { empty = tostring(map.size) })
    if size_changed then
        editor:ask("CHANGE THE MAP SIZE?", "OBJECTS PAST THE NEW EDGE WRAP AROUND TO THE OTHER SIDE. "
            .. "THIS CANNOT BE UNDONE.", {
            { label = "RESIZE", primary = true, action = function()
                doc:resize(size)
                editor.selection:clear()
                editor:open_dialog("settings")
            end },
            { label = "CANCEL", action = function() editor:open_dialog("settings") end },
        })
    end
    y = y + theme.row + 14
    if map.based_on then
        kit:label("A COPY OF " .. map.based_on:upper() .. ". THE FILE HOLDS THAT STAGE'S LAYOUT.", x, y, w, theme.row,
            { color = theme.text_dim, size = theme.font_small })
    end
end

local function settings_environment(editor, kit, x, y, w)
    local theme = kit.theme
    local doc   = editor.doc
    local env   = doc.map.environment
    local fw    = w - LABEL_W
    labelled(kit, x, y, "ART SET")
    local art, art_changed = kit:choice("set_art", x + LABEL_W, y, fw, present_arts(), doc:art())
    if art_changed then
        -- The base stage carries the art set's own projectiles, people and dust.
        local stages = Catalog.stages(art)
        doc:begin("ART SET")
        set_environment(editor, "art", tonumber(art))
        if stages[1] then doc:set_map("base", stages[1]) end
        doc:commit()
        editor.catalog_art = art
    end
    y = y + theme.row + 6
    labelled(kit, x, y, "TIME OF DAY")
    local times = { { label = "AS THE ART SET", value = "" }, { label = "DAY", value = "day", icon = "day" },
                    { label = "NIGHT", value = "night", icon = "night" } }
    local time = env.night == nil and "" or (env.night and "night" or "day")
    local new_time, time_changed = kit:choice("set_time", x + LABEL_W, y, fw, times, time)
    if time_changed then
        local night = nil
        if new_time ~= "" then night = new_time == "night" end
        set_environment(editor, "night", night)
    end
    y = y + theme.row + 6
    labelled(kit, x, y, "WEATHER")
    local weathers = { { label = "AS THE ART SET", value = "" }, { label = "CLEAR", value = "none", icon = "day" },
                       { label = "SNOW", value = "snow", icon = "snow" }, { label = "RAIN", value = "rain", icon = "rain" } }
    local weather, weather_changed = kit:choice("set_weather", x + LABEL_W, y, fw, weathers, env.weather or "")
    if weather_changed then set_environment(editor, "weather", weather ~= "" and weather or nil) end
    y = y + theme.row + 6
    labelled(kit, x, y, "COLOUR GRADE")
    local look, look_changed = kit:choice("set_look", x + LABEL_W, y, fw, art_choices(true),
        env.look and tostring(env.look) or "")
    if look_changed then set_environment(editor, "look", look ~= "" and tonumber(look) or nil) end
    y = y + theme.row + 6
    labelled(kit, x, y, "MUSIC")
    local music, music_changed = kit:choice("set_music", x + LABEL_W, y, fw, art_choices(true),
        env.music and tostring(env.music) or "")
    if music_changed then set_environment(editor, "music", music ~= "" and tonumber(music) or nil) end
    y = y + theme.row + 14
    kit:paragraph("ANY TIME OF DAY AND WEATHER CAN BE LAID OVER ANY ART SET. THE EDITOR ALWAYS SHOWS THE MAP UNLIT; "
        .. "TRY IT WITH F5.", x, y, w, { color = theme.text_dim, size = theme.font_small })
end

-- loadout

local function weapon_label(name)
    return (name:upper():gsub("_", " "))
end

-- What a map first fixes for a vehicle: the chain gun and the vehicle's
-- starting weapon, as a new game hands them out.
local function default_loadout(vehicle)
    return { vehicle = vehicle, weapons = { chaingun = 1, [Vehicles.STARTING_WEAPON[vehicle]] = 1 },
             special = Vehicles.SPECIAL_WEAPONS[vehicle][1], loads = 1, fuel = 50, armor = 50,
             lives = Score.START_LIVES }
end

-- Replace one key of the map's loadout (or one weapon's level) as a single undo step.
local function set_loadout(editor, key, value, weapon)
    local old, new = editor.doc.map.loadout, {}
    for k, v in pairs(old) do new[k] = v end
    new.weapons = {}
    for k, v in pairs(old.weapons or {}) do new.weapons[k] = v end
    if weapon then new.weapons[weapon] = value > 0 and value or nil else new[key] = value end
    editor.doc:set_map("loadout", new, "LOADOUT")
end

local function settings_loadout(editor, kit, x, y, w)
    local theme   = kit.theme
    local doc     = editor.doc
    local map     = doc.map
    local loadout = map.loadout
    local fw      = w - LABEL_W
    labelled(kit, x, y, "EQUIPMENT")
    local modes = { { label = "THE PLAYER BUYS AND EQUIPS", value = "player" }, { label = "SET BY THE MAP", value = "map" } }
    local mode, mode_changed = kit:choice("load_mode", x + LABEL_W, y, fw, modes, loadout and "map" or "player")
    if mode_changed then
        doc:set_map("loadout", mode == "map" and default_loadout(map.vehicle or "chopper") or nil, "LOADOUT")
        return
    end
    y = y + theme.row + 6
    if not loadout then
        labelled(kit, x, y, "VEHICLE")
        local vehicles = { { label = "PLAYER CHOOSES", value = "" }, { label = "CHOPPER ONLY", value = "chopper" },
                           { label = "TANK ONLY", value = "tank" } }
        local vehicle, vehicle_changed = kit:choice("set_vehicle", x + LABEL_W, y, fw, vehicles, map.vehicle or "")
        if vehicle_changed then doc:set_map("vehicle", vehicle ~= "" and vehicle or nil) end
        y = y + theme.row + 14
        kit:paragraph("THE PLAYER GETS " .. Loadout.START_MEDALS .. " MEDALS FOR THE SHOP AND LOADS THE BAYS ON THE "
            .. "EQUIP SCREEN, AS FOR A SINGLE MISSION.", x, y, w, { color = theme.text_dim, size = theme.font_small })
        return
    end

    labelled(kit, x, y, "VEHICLE")
    local vehicles = { { label = "CHOPPER", value = "chopper" }, { label = "TANK", value = "tank" } }
    local vehicle, vehicle_changed = kit:choice("load_vehicle", x + LABEL_W, y, fw, vehicles, loadout.vehicle)
    if vehicle_changed then
        local fresh = default_loadout(vehicle)
        fresh.loads, fresh.fuel, fresh.armor, fresh.lives = loadout.loads, loadout.fuel, loadout.armor, loadout.lives
        doc:set_map("loadout", fresh, "LOADOUT")
        return
    end
    y = y + theme.row + 6

    local half = (w - 16) / 2
    local nw   = half - LABEL_W
    local function number(id, label, column, key, opts)
        local nx = x + column * (half + 16)
        labelled(kit, nx, y, label)
        local value, changed = kit:number(id, nx + LABEL_W, y, nw, loadout[key] or opts.default, opts)
        if changed then set_loadout(editor, key, value) end
    end
    number("load_lives", "VEHICLES", 0, "lives", { min = 1, max = MAX_LIVES, default = Score.START_LIVES })
    number("load_loads", "AMMUNITION", 1, "loads", { min = 1, max = Loadout.MAX_LOADS, default = 1, suffix = " X" })
    y = y + theme.row + 6
    number("load_fuel", "FUEL", 0, "fuel", { min = 0, max = 100, step = 5, big = 25, default = 50 })
    number("load_armor", "ARMOUR", 1, "armor", { min = 0, max = 100, step = 5, big = 25, default = 50 })
    y = y + theme.row + 4
    kit:label("MORE FUEL AND ARMOUR MAKE THE VEHICLE SLOWER, AS ON THE EQUIP SCREEN.", x, y, w, theme.row,
        { color = theme.text_dim, size = theme.font_small })
    y = y + theme.row + 6

    local weapons = editor.app.combat.weapons
    for i, name in ipairs(Vehicles.BAY_WEAPONS[loadout.vehicle]) do
        local column = (i - 1) % 2
        local wx     = x + column * (half + 16)
        local top    = math.max(1, weapons[name] and weapons[name].levels and #weapons[name].levels or 1)
        local levels = {}
        if name ~= "chaingun" then levels[1] = { label = "NOT CARRIED", value = 0 } end
        for level = 1, top do
            levels[#levels + 1] = { label = top == 1 and "CARRIED" or ("LEVEL " .. level), value = level }
        end
        local current = math.min(top, loadout.weapons[name] or 0)
        if name == "chaingun" then current = math.max(1, current) end
        labelled(kit, wx, y, weapon_label(name))
        local level, changed = kit:choice("load_" .. name, wx + LABEL_W, y, nw, levels, current)
        if changed then set_loadout(editor, nil, level, name) end
        if column == 1 or i == #Vehicles.BAY_WEAPONS[loadout.vehicle] then y = y + theme.row + 6 end
    end

    labelled(kit, x, y, "SPECIAL")
    local specials = { { label = "NONE", value = "" } }
    for _, name in ipairs(Vehicles.SPECIAL_WEAPONS[loadout.vehicle]) do
        specials[#specials + 1] = { label = weapon_label(name), value = name }
    end
    local special, special_changed = kit:choice("load_special", x + LABEL_W, y, fw, specials, loadout.special or "")
    if special_changed then set_loadout(editor, "special", special ~= "" and special or nil) end
end

-- difficulty

local LEVELS = { { label = "AS ON EASY", value = "easy" }, { label = "AS ON MEDIUM", value = "medium" },
                 { label = "AS ON HARD", value = "hard" } }
local PICKUP_TIMES = { { label = "LONG", value = "easy" }, { label = "MEDIUM", value = "medium" },
                       { label = "SHORT", value = "hard" } }

local function set_difficulty(editor, key, value)
    local new = {}
    for k, v in pairs(editor.doc.map.difficulty) do new[k] = v end
    new[key] = value
    editor.doc:set_map("difficulty", new, "DIFFICULTY")
end

local function settings_difficulty(editor, kit, x, y, w)
    local theme = kit.theme
    local doc   = editor.doc
    local own   = doc.map.difficulty
    local fw    = w - LABEL_W
    labelled(kit, x, y, "DIFFICULTY")
    local modes = { { label = "THE PLAYER'S OWN SETTING", value = "" } }
    for _, choice in ipairs(Difficulty.preset_choices()) do
        if not choice.hidden then modes[#modes + 1] = { label = choice.label, value = choice.value } end
    end
    local current = own and Difficulty.match_preset(own) or ""
    if current == "custom" then modes[#modes + 1] = { label = "THE MAP'S OWN", value = "custom" } end
    local mode, mode_changed = kit:choice("diff_mode", x + LABEL_W, y, fw, modes, current)
    if mode_changed then
        doc:set_map("difficulty", mode ~= "" and Difficulty.preset_values(mode) or nil, "DIFFICULTY")
        return
    end
    y = y + theme.row + 14
    if not own then
        kit:paragraph("THE MAP IS PLAYED ON THE DIFFICULTY THE PLAYER HAS SET IN THE OPTIONS. PICK ONE HERE AND THE MAP "
            .. "PLAYS THE SAME FOR EVERYONE, WHICH IS WHAT A CHALLENGE NEEDS. EVERY VALUE CAN THEN BE CHANGED.",
            x, y, w, { color = theme.text_dim, size = theme.font_small })
        return
    end

    local half   = (w - 16) / 2
    local nw     = half - LABEL_W
    local ranges = Catalog.data().difficulty
    local function level(id, label, key, choices)
        labelled(kit, x, y, label)
        local value, changed = kit:choice(id, x + LABEL_W, y, nw, choices, own[key] or "medium")
        if changed then set_difficulty(editor, key, value) end
    end
    local function percent(id, label, column, key)
        local nx = x + column * (half + 16)
        labelled(kit, nx, y, label)
        local range = ranges[key]
        local value, changed = kit:number(id, nx + LABEL_W, y, nw, math.floor((own[key] or 1) * 100 + 0.5),
            { min = range.min, max = range.max, step = range.step, big = range.step * 5, suffix = " %" })
        if changed then set_difficulty(editor, key, value / 100) end
    end
    level("diff_damage", "ENEMY HITS", "enemy_damage_level", LEVELS)
    percent("diff_damage_scale", "HIT STRENGTH", 1, "enemy_damage")
    y = y + theme.row + 6
    level("diff_fire", "ENEMY FIRE", "enemy_fire_level", LEVELS)
    percent("diff_fire_rate", "RATE OF FIRE", 1, "enemy_fire_rate")
    y = y + theme.row + 6
    level("diff_pickups", "PICKUPS LIE FOR", "pickup_level", PICKUP_TIMES)
    percent("diff_aggression", "ENEMY SIGHT", 1, "enemy_aggression")
    y = y + theme.row + 10
    local medals, medals_changed = kit:check("diff_medals", x, y, w, "MEDALS ARE ONLY PICKED UP BY LANDING ON THEM",
        own.land_for_medals == true)
    if medals_changed then set_difficulty(editor, "land_for_medals", medals) end
    y = y + theme.row + 2
    local supplies, supplies_changed = kit:check("diff_supplies", x, y, w,
        "FUEL AND ARMOUR ARE ONLY PICKED UP BY LANDING ON THEM", own.land_for_supplies == true)
    if supplies_changed then set_difficulty(editor, "land_for_supplies", supplies) end
    y = y + theme.row + 12
    kit:paragraph("ENEMY HITS AND ENEMY FIRE PICK THE ORIGINAL'S TABLES FOR A LEVEL: THE DAMAGE OF EVERY ENEMY WEAPON, "
        .. "AND THE RELOADS, BURSTS AND MISSILE TRACKING. THE PERCENTAGES SCALE THEM FURTHER. ENEMY SIGHT IS HOW FAR "
        .. "THE ENEMY NOTICES AND ENGAGES THE PLAYER.", x, y, w, { color = theme.text_dim, size = theme.font_small })
end

-- objectives

local function clock_text(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local GOAL_ABOUT = {
    targets  = { "THE MISSION TARGET ON THE MAP", "THE %d MISSION TARGETS ON THE MAP" },
    rescue   = { "THE ONE WAITING ON THE MAP", "THE %d PEOPLE WAITING ON THE MAP" },
    sabotage = { "THE BUILDING AN AGENT GOES INTO", "THE %d BUILDINGS AN AGENT GOES INTO" },
}

-- What an objective that follows from the map's content is about, in a line;
-- nil when nothing of it is on the map.
local function goal_about(goal, summary)
    local count = summary[Goals.TYPES[goal.type].count]
    if count == 0 then return nil end
    return string.format(GOAL_ABOUT[goal.type][count == 1 and 1 or 2], count)
end

-- One objective of the list. Returns true when it changed the list, which
-- ends this frame's drawing of it.
local function goal_card(editor, kit, rows, i, x, y, w, summary)
    local theme  = kit.theme
    local doc    = editor.doc
    local goal   = rows[i]
    local def    = Goals.TYPES[goal.type]
    local limits = Goals.limits()
    local pad    = theme.pad
    local id     = "goal" .. i .. "_"
    kit:rect(x, y, w, GOAL_H - 6, theme.panel_head, 3)

    kit:label(i .. ".  " .. def.title, x + pad, y + 2, w - 90, theme.row, { color = theme.accent, size = theme.font_small })
    local bx = x + w - pad - 22
    if not def.count or summary[def.count] == 0 then
        if kit:button(id .. "remove", bx, y + 2, 22, theme.row, { icon = "trash", flat = true, tip = "REMOVE THIS OBJECTIVE" }) then
            Goals.remove(doc, rows, i)
            return true
        end
    end
    bx = bx - 24
    if kit:button(id .. "down", bx, y + 2, 22, theme.row, { icon = "chevron_down", flat = true, disabled = i == #rows,
        tip = "LATER IN THE ORDER" }) then
        Goals.move(doc, rows, i, 1)
        return true
    end
    bx = bx - 24
    if kit:button(id .. "up", bx, y + 2, 22, theme.row, { icon = "chevron_up", flat = true, disabled = i == 1,
        tip = "EARLIER IN THE ORDER" }) then
        Goals.move(doc, rows, i, -1)
        return true
    end

    local ry = y + theme.row + 4
    kit:label("SHOWN AS", x + pad, ry, 70, theme.row, { color = theme.text_dim, size = theme.font_small })
    local optional = goal.type ~= "protect"
    local label, _, done = kit:field(id .. "label", x + pad + 72, ry, w - pad * 2 - 72 - (optional and 110 or 0),
        goal.label or "", { hint = def.wording, max = NAME_MAX, commit = true })
    if done and label:upper() ~= (goal.label or "") then
        Goals.set(doc, rows, i, "label", label ~= "" and label:upper() or nil)
        return true
    end
    if optional then
        local value, changed = kit:check(id .. "optional", x + w - pad - 102, ry, 102, "OPTIONAL", goal.optional == true,
            { tip = "THE PHASE CAN BE WON WITHOUT IT" })
        if changed then
            Goals.set(doc, rows, i, "optional", value or nil)
            return true
        end
    end

    ry = ry + theme.row + 4
    local cx = x + pad
    local function note(text, color)
        kit:label(text, cx, ry, x + w - pad - cx, theme.row, { color = color or theme.text_dim, size = theme.font_small })
    end
    local function number(key, caption, width, value, opts)
        local lw = kit:text_width(caption, theme.font_small) + 6
        kit:label(caption, cx, ry, lw, theme.row, { color = theme.text_dim, size = theme.font_small })
        local new, changed = kit:number(id .. key, cx + lw, ry, width, value, opts)
        cx = cx + lw + width + 12
        if changed then Goals.set(doc, rows, i, key, new) end
        return changed
    end
    -- How many of `total` are asked for: all of them, or a number.
    local function amount(total)
        local all, changed = kit:check(id .. "all", cx, ry, 116, "ALL OF THEM", goal.count == nil)
        cx = cx + 122
        if changed then
            Goals.set(doc, rows, i, "count", (not all) and math.max(1, total) or nil)
            return true
        end
        return goal.count ~= nil and number("count", "AT LEAST", 86, math.min(goal.count, math.max(1, total)),
            { min = 1, max = math.max(1, total) })
    end
    -- The objects an objective is about: taken from the selection, shown on the map.
    local function objects()
        local found  = Goals.objects(doc, goal)
        local picked = Goals.pick(doc, editor.selection.list)
        kit:label(#found .. (#found == 1 and " OBJECT" or " OBJECTS"), cx, ry, 78, theme.row,
            { color = #found > 0 and theme.text or theme.warn, size = theme.font_small })
        cx = cx + 80
        if kit:button(id .. "take", cx, ry, 172, theme.row, { text = "USE THE SELECTION", disabled = #picked == 0,
            tip = "THE OBJECTS SELECTED ON THE MAP BECOME THIS OBJECTIVE'S" }) then
            Goals.set(doc, rows, i, "objects", picked)
            return nil, true
        end
        cx = cx + 176
        if kit:button(id .. "show", cx, ry, 62, theme.row, { text = "SHOW", disabled = #found == 0,
            tip = "SELECT THEM ON THE MAP" }) then
            close(editor)
            editor:show_objects(found)
            return nil, true
        end
        cx = cx + 70
        return found, false
    end

    if def.count then
        local about = goal_about(goal, summary)
        note(about or "NOTHING OF IT IS ON THE MAP: THE OBJECTIVE IS LEFT OUT", not about and theme.warn or nil)
    elseif goal.type == "destroy" and goal.kinds then
        local kind, changed = kit:choice(id .. "kind", cx, ry, 170, Goals.kind_choices(), Goals.kind_id(goal.kinds))
        cx = cx + 178
        if changed then
            Goals.set(doc, rows, i, "kinds", Goals.kinds(kind))
            return true
        end
        local total = Goals.count_kinds(doc, goal.kinds)
        if amount(total) then return true end
        note(total .. " ON THE MAP", total == 0 and theme.warn or nil)
    elseif goal.type == "destroy" then
        local found, changed = objects()
        if changed then return true end
        if amount(#found) then return true end
    elseif goal.type == "protect" then
        local found, changed = objects()
        if changed then return true end
        if number("losses", "MAY LOSE", 92, math.min(goal.losses or 0, math.max(0, #found - 1)),
            { min = 0, max = math.max(0, #found - 1) }) then
            return true
        end
    elseif goal.type == "reach" then
        if kit:button(id .. "place", cx, ry, 176, theme.row, { text = "PICK ON THE MAP", icon = "pin",
            tip = "CLICK THE PLACE ON THE MAP" }) then
            editor:start_place_pick(i)
            return true
        end
        cx = cx + 184
        local range = limits.radius
        if number("radius", "WITHIN", 100, goal.radius or range.default,
            { min = range.min, max = range.max, step = range.step, big = range.step * 4, suffix = " PX" }) then
            return true
        end
        local land, changed = kit:check(id .. "land", cx, ry, x + w - pad - cx, "DOWN OR STOPPED THERE", goal.land == true,
            { tip = "A CHOPPER HAS TO LAND IN THE PLACE, A TANK TO STOP IN IT" })
        if changed then
            Goals.set(doc, rows, i, "land", land or nil)
            return true
        end
    elseif goal.type == "survive" then
        local range = limits.seconds
        if number("seconds", "SECONDS", 110, goal.seconds or range.default,
            { min = range.min, max = range.max, step = range.step, big = range.step * 6 }) then
            return true
        end
        note(clock_text(goal.seconds or range.default) .. " ON THE CLOCK, FROM THE MOMENT THE OBJECTIVE COMES UP")
    elseif goal.type == "collect" then
        local range = limits.medals
        if number("count", "MEDALS", 100, goal.count or range.default, { min = range.min, max = range.max }) then
            return true
        end
        note("PICKED UP DURING THE PHASE")
    elseif goal.type == "air" then
        local range = limits.helicopters
        local air   = Goals.air(doc)
        if number("count", "HELICOPTERS", 100, goal.count or range.default, { min = range.min, max = range.max }) then
            return true
        end
        if air.posts == 0 then
            note("NO HELICOPTER POST ON THE MAP: THE OBJECTIVE IS LEFT OUT", theme.warn)
        elseif air.returning then
            note(air.posts .. (air.posts == 1 and " POST" or " POSTS") .. " ON THE MAP, AND THEY COME BACK")
        else
            note(air.posts .. " ON THE MAP, NONE COMES BACK", (goal.count or range.default) > air.posts and theme.warn or nil)
        end
    end
    return false
end

local function add_goal_menu(editor, kit, rows, x, y)
    local doc    = editor.doc
    local limits = Goals.limits()
    local picked = Goals.pick(doc, editor.selection.list)
    local function add(goal)
        local index = Goals.add(doc, rows, goal)
        kit:scroll_to("goals_list", index * GOAL_H, (index + 1) * GOAL_H, 0)
        return index
    end
    kit:open_menu("goal_add", x, y, {
        { label = "DESTROY THE SELECTED OBJECTS", icon = "target", disabled = #picked == 0,
          action = function() add({ type = "destroy", objects = picked }) end },
        { label = "DESTROY ENEMIES OF A KIND", icon = "units",
          action = function() add({ type = "destroy", kinds = limits.kinds[1].kinds }) end },
        { label = "KEEP THE SELECTED OBJECTS INTACT", icon = "lock", disabled = #picked == 0,
          action = function() add({ type = "protect", objects = picked }) end },
        {},
        { label = "GET TO A PLACE", icon = "pin", action = function()
            local size = doc:size()
            local index = add({ type = "reach", x = math.floor(editor.view.x % size), y = math.floor(editor.view.y % size),
                                radius = limits.radius.default })
            editor:start_place_pick(index)
        end },
        { label = "HOLD OUT FOR A TIME", icon = "refresh",
          action = function() add({ type = "survive", seconds = limits.seconds.default }) end },
        { label = "COLLECT MEDALS", icon = "ok",
          action = function() add({ type = "collect", count = limits.medals.default }) end },
        { label = "SHOOT DOWN HELICOPTERS", icon = "helicopter",
          action = function() add({ type = "air", count = limits.helicopters.default }) end },
    })
end

local function settings_objectives(editor, kit, x, y, w, h)
    local theme   = kit.theme
    local doc     = editor.doc
    local map     = doc.map
    local summary = Validate.summary(doc)
    local rows    = Goals.rows(doc, summary)

    if kit:button("goal_add", x, y, 150, theme.row + 2, { text = "ADD OBJECTIVE", icon = "plus" })
    and not kit:popup_open("goal_add") then
        add_goal_menu(editor, kit, rows, x, y + theme.row + 2)
    end
    kit:label("TARGETS, PEOPLE AND AGENTS ARE SET ON THE OBJECTS THEMSELVES", x + 160, y, w - 160, theme.row + 2,
        { color = theme.text_dim, size = theme.font_small })
    y = y + theme.row + 8

    local list_h = h - theme.row - 8 - RULES_H
    kit:rect(x, y, w, list_h, theme.field, 3)
    local offset = kit:scroll_begin("goals_list", x, y, w, list_h, #rows * GOAL_H + 2)
    for i = 1, #rows do
        local cy = y + 4 + (i - 1) * GOAL_H - offset
        if cy + GOAL_H > y and cy < y + list_h and goal_card(editor, kit, rows, i, x + 4, cy, w - 16, summary) then
            kit:blur()
            break
        end
    end
    if #rows == 0 then
        kit:label("NO OBJECTIVE YET", x, y, w, list_h, { align = "center", color = theme.text_dim })
    end
    kit:scroll_end()
    y = y + list_h + 8

    local ordered, ordered_changed = kit:check("set_ordered", x, y, w,
        "IN ORDER: AN OBJECTIVE COMES UP ONCE THOSE BEFORE IT ARE DONE", map.ordered == true)
    if ordered_changed then doc:set_map("ordered", ordered or nil) end
    y = y + theme.row + 2
    local range = Goals.limits().time_limit
    local timed, timed_changed = kit:check("set_timed", x, y, w - 230, "TIME LIMIT: THE PHASE FAILS WHEN IT RUNS OUT",
        map.time_limit ~= nil)
    if timed_changed then doc:set_map("time_limit", timed and range.default or nil) end
    if map.time_limit then
        local seconds, changed = kit:number("set_time_limit", x + w - 220, y, 120, map.time_limit,
            { min = range.min, max = range.max, step = range.step, big = range.step * 4, suffix = " S" })
        if changed then doc:set_map("time_limit", seconds) end
        kit:label(clock_text(map.time_limit), x + w - 92, y, 92, theme.row,
            { align = "right", color = theme.text_dim, size = theme.font_small })
    end
    y = y + theme.row + 2
    local no_return, return_changed = kit:check("set_no_return", x, y, w,
        "NO FLIGHT HOME: THE PHASE ENDS WITH THE LAST OBJECTIVE", map.no_return == true)
    if return_changed then doc:set_map("no_return", no_return or nil) end
    y = y + theme.row + 2
    local hold, hold_changed = kit:check("set_hold", x, y, w, "AGENTS STAY INSIDE UNTIL EVERY BUILDING HAS ONE",
        map.hold_agents == true)
    if hold_changed then doc:set_map("hold_agents", hold) end
    y = y + theme.row + 2
    local commander, commander_changed = kit:check("set_commander", x, y, w,
        "COMMANDER RULE: THE COMMANDERS BUILDING APPEARS LAST AND ENDS THE PHASE", map.commander == true)
    if commander_changed then doc:set_map("commander", commander) end
end

local function settings_briefing(editor, kit, x, y, w, h)
    local theme  = kit.theme
    local doc    = editor.doc
    local images = editor:card_images()
    local card_w = Cards.W * CARD_ZOOM
    local card_h = Cards.H * CARD_ZOOM
    local tx     = x + card_w + 14
    local tw     = w - card_w - 14
    local block  = math.floor(h / PARAGRAPHS)
    for i = 1, PARAGRAPHS do
        local top  = y + (i - 1) * block
        local card = doc.map.briefing_cards[i] or { kind = "none" }

        -- The picture beside the paragraph, as the briefing shows it.
        kit:rect(x, top, card_w + 4, card_h + 4, theme.field, 3)
        local image = images[i - 1]
        if image then
            -- A game card may carry more art than the square: only the square shows here.
            kit:clip(x + 2, top + 2, card_w, card_h)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(image.image, x + 2, top + 2, 0, CARD_ZOOM, CARD_ZOOM)
            kit:unclip()
        else
            kit:label("NO PICTURE", x, top, card_w + 4, card_h + 4,
                { align = "center", color = theme.text_dim, size = theme.font_small })
        end

        -- The paragraph, and how much of its slot it fills as the briefing sets it.
        local text   = doc.map.briefing[i] or ""
        local area_h = block - theme.row * 2 - 16
        local new, _, done = kit:area("brief_" .. i, tx, top, tw, area_h, text,
            { hint = "PARAGRAPH " .. i .. ". ENTER STARTS A NEW LINE.", max = TEXT_MAX })
        if done and new:upper() ~= text then
            local briefing = {}
            for k = 1, PARAGRAPHS do briefing[k] = doc.map.briefing[k] or "" end
            briefing[i] = new:upper()
            while #briefing > 0 and briefing[#briefing] == "" do table.remove(briefing) end
            doc:set_map("briefing", briefing, "BRIEFING")
        end
        local lines = #MissionMenu.lines(text, image and image.w or nil)
        local room  = MissionMenu.SLOT_LINES
        kit:label(lines > room and string.format("%d LINES: %d MORE THAN THE SLOT HOLDS, THE NEXT PARAGRAPH MOVES DOWN",
            lines, lines - room) or string.format("%d OF %d LINES", lines, room), tx, top + area_h + 2, tw, theme.row - 4,
            { color = lines > room and theme.warn or theme.text_dim, size = theme.font_small })

        local by = top + block - theme.row - 12
        local bx = tx
        if kit:button("card_map_" .. i, bx, by, 142, theme.row, { text = "FROM THE MAP", icon = "crosshair",
            tip = "CLICK A SPOT ON THE MAP: THE PICTURE SHOWS IT, AND FOLLOWS THE MAP WHEN IT CHANGES" }) then
            editor:start_card_pick(i)
        end
        bx = bx + 146
        if kit:button("card_game_" .. i, bx, by, 122, theme.row, { text = "GAME CARD", icon = "image",
            tip = "A CARD OF AN ORIGINAL BRIEFING" }) then
            editor.dialog = { kind = "cards", slot = i }
        end
        bx = bx + 126
        if kit:button("card_none_" .. i, bx, by, 60, theme.row, { text = "NONE", disabled = card.kind == "none" }) then
            editor:set_card(i, nil)
        end
        bx = bx + 70
        if card.kind == "view" then
            local label, _, label_done = kit:field("card_label_" .. i, bx, by, tx + tw - bx, card.label or "",
                { hint = "CAPTION", max = CAPTION_MAX, commit = true })
            label = Cards.caption(label)
            if label_done and label ~= (card.label or "") then
                editor:set_card(i, { kind = "view", x = card.x, y = card.y, size = card.size,
                                     label = label ~= "" and label or nil })
            end
        end
    end
end

-- The cards of the original briefings, to put one beside a paragraph.
local function draw_cards(editor, kit, dialog)
    local cards = Cards.originals()
    kit:dialog("PICK A CARD", 640, 470, function(_, x, y, w, h)
        local theme   = kit.theme
        local cell_w  = Cards.W + 30
        local cell_h  = Cards.H + 8
        local columns = math.floor(w / cell_w)
        local list_h  = h - theme.row - 12
        local rows    = math.ceil(#cards / columns)
        kit:rect(x, y, w, list_h, theme.field, 3)
        local offset = kit:scroll_begin("cards_list", x, y, w, list_h, rows * cell_h + 8)
        for i, card in ipairs(cards) do
            local cx = x + 4 + ((i - 1) % columns) * cell_w
            local cy = y + 4 + math.floor((i - 1) / columns) * cell_h - offset
            if cy + cell_h > y and cy < y + list_h then
                local id = "pick_card_" .. i
                local clicked, hover = kit:click(id, cx, cy, cell_w - 4, cell_h - 4)
                if hover then
                    kit:rect(cx, cy, cell_w - 4, cell_h - 4, theme.widget_hot, 3)
                    kit:set_tip(id, card.stage:upper())
                end
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(card.image, card.quad, cx + 2, cy + 2)
                if clicked then
                    editor:set_card(dialog.slot, { kind = "card", stage = card.stage, slot = card.slot })
                    editor:open_dialog("settings")
                    editor.dialog.tab = "briefing"
                end
            end
        end
        if #cards == 0 then
            kit:label("THIS GAME DATA HAS NO BRIEFING CARDS", x, y, w, list_h, { align = "center", color = theme.text_dim })
        end
        kit:scroll_end()
        if kit:button("cards_cancel", x + w - 100, y + h - theme.row - 2, 100, theme.row + 2, { text = "CANCEL" }) then
            editor:open_dialog("settings")
            editor.dialog.tab = "briefing"
        end
    end)
end

local SETTINGS_PAGES = {
    general = settings_general, environment = settings_environment, loadout = settings_loadout,
    difficulty = settings_difficulty, objectives = settings_objectives, briefing = settings_briefing,
}

local function draw_settings(editor, kit, dialog)
    kit:dialog("MAP SETTINGS", 660, 540, function(_, x, y, w, h)
        local theme = kit.theme
        dialog.tab = kit:tabs("set_tabs", x, y, w, SETTINGS_TABS, dialog.tab or "general")
        SETTINGS_PAGES[dialog.tab](editor, kit, x, y + theme.row + 16, w, h - theme.row * 2 - 30)
        local bottom = y + h - theme.row - 2
        if dialog.tab == "briefing" and kit:button("set_preview", x, bottom, 190, theme.row + 2,
            { text = "PREVIEW THE BRIEFING", icon = "eye", tip = "THE BRIEFING AS THE PLAYER WILL SEE IT (F6)" }) then
            editor:preview_briefing()
        end
        if kit:button("set_close", x + w - 100, bottom, 100, theme.row + 2, { text = "CLOSE", primary = true }) then
            close(editor)
        end
    end)
end

-- new map

function Dialogs.new_state()
    local arts = present_arts()
    local art  = arts[1] and arts[1].value or "0"
    return { kind = "new", name = "NEW MAP", start = "blank", art = art, size = MapFile.DEFAULT_SIZE,
             ground = true, stage = Catalog.stages(art)[1] }
end

local function draw_new(editor, kit, dialog)
    kit:dialog("NEW MAP", 520, 330, function(_, x, y, w, h)
        local theme  = kit.theme
        local fw     = w - LABEL_W
        local bottom = y + h - theme.row - 2
        labelled(kit, x, y, "NAME")
        dialog.name = kit:field("new_name", x + LABEL_W, y, fw, dialog.name, { max = NAME_MAX })
        y = y + theme.row + 8
        labelled(kit, x, y, "START FROM")
        local starts = { { label = "A BLANK MAP", value = "blank" }, { label = "A COPY OF A STAGE", value = "copy" } }
        dialog.start = kit:choice("new_start", x + LABEL_W, y, fw, starts, dialog.start)
        y = y + theme.row + 8
        labelled(kit, x, y, "ART SET")
        local art, art_changed = kit:choice("new_art", x + LABEL_W, y, fw, present_arts(), dialog.art)
        if art_changed then
            dialog.art   = art
            dialog.stage = Catalog.stages(art)[1]
        end
        y = y + theme.row + 8
        if dialog.start == "copy" then
            labelled(kit, x, y, "STAGE")
            dialog.stage = kit:choice("new_stage", x + LABEL_W, y, fw, stage_choices(dialog.art), dialog.stage)
            y = y + theme.row + 8
            kit:paragraph("THE COPY HOLDS THE STAGE'S WHOLE LAYOUT AND IS MARKED AS A COPY OF IT.", x, y, w,
                { color = theme.text_dim, size = theme.font_small })
        else
            labelled(kit, x, y, "MAP SIZE")
            dialog.size = kit:choice("new_size", x + LABEL_W, y, fw, size_choices(), dialog.size)
            y = y + theme.row + 8
            dialog.ground = kit:check("new_ground", x + LABEL_W, y, fw, "COVER THE GROUND WITH SCENERY", dialog.ground)
            y = y + theme.row + 4
            if dialog.ground then
                labelled(kit, x, y, "SCENERY AS IN")
                dialog.stage = kit:choice("new_stage", x + LABEL_W, y, fw, stage_choices(dialog.art), dialog.stage)
            end
        end
        if kit:button("new_create", x + w - 100, bottom, 100, theme.row + 2,
            { text = "CREATE", primary = true, disabled = dialog.name == "" or not dialog.stage }) then
            close(editor)
            editor:new_map(dialog)
        end
        if kit:button("new_cancel", x + w - 208, bottom, 100, theme.row + 2, { text = "CANCEL" }) then
            close(editor)
            if dialog.on_cancel then dialog.on_cancel() end
        end
    end)
end

-- open

local function draw_open(editor, kit, dialog)
    dialog.maps = dialog.maps or MapFile.list()
    kit:dialog("OPEN MAP", 520, 420, function(_, x, y, w, h)
        local theme  = kit.theme
        local bottom = y + h - theme.row - 2
        local list_h = h - theme.row - 12
        kit:rect(x, y, w, list_h, theme.field, 3)
        local offset = kit:scroll_begin("open_list", x, y, w, list_h, #dialog.maps * (theme.row + 2) + 4)
        for i, item in ipairs(dialog.maps) do
            local ry = y + 2 + (i - 1) * (theme.row + 2) - offset
            if kit:button("open_" .. i, x + 2, ry, w - 8, theme.row,
                { text = item.map.name, flat = true, align = "left", on = dialog.pick == item }) then
                if dialog.pick == item then
                    close(editor)
                    editor:open_map(item.name)
                else
                    dialog.pick = item
                end
            end
            kit:label(Catalog.art_label(item.map.environment.art or 0) .. "  " .. #item.map.objects .. " OBJECTS",
                x, ry, w - 12, theme.row, { align = "right", size = theme.font_small, color = theme.text_dim })
        end
        if #dialog.maps == 0 then
            kit:label("NO MAPS YET", x, y, w, list_h, { align = "center", color = theme.text_dim })
        end
        kit:scroll_end()
        if kit:button("open_ok", x + w - 100, bottom, 100, theme.row + 2,
            { text = "OPEN", primary = true, disabled = not dialog.pick }) then
            close(editor)
            editor:open_map(dialog.pick.name)
        end
        if kit:button("open_cancel", x + w - 208, bottom, 100, theme.row + 2, { text = "CANCEL" }) then close(editor) end
    end)
end

-- save as

local function draw_save_as(editor, kit, dialog)
    kit:dialog("SAVE MAP AS", 460, 150, function(_, x, y, w, h)
        local theme  = kit.theme
        local bottom = y + h - theme.row - 2
        labelled(kit, x, y, "NAME")
        local name, _, done = kit:field("save_name", x + LABEL_W, y, w - LABEL_W, dialog.name, { max = NAME_MAX })
        dialog.name = name
        kit:label("SAVED INTO THE MAPS FOLDER OF THE GAME'S SAVE DIRECTORY", x, y + theme.row + 8, w, theme.row,
            { color = theme.text_dim, size = theme.font_small })
        local ok = kit:button("save_ok", x + w - 100, bottom, 100, theme.row + 2,
            { text = "SAVE", primary = true, disabled = dialog.name == "" })
        if (ok or (done and love.keyboard.isDown("return", "kpenter"))) and dialog.name ~= "" then
            close(editor)
            editor:save_as(dialog.name, dialog.after)
        end
        if kit:button("save_cancel", x + w - 208, bottom, 100, theme.row + 2, { text = "CANCEL" }) then close(editor) end
    end)
end

-- prefab

local function draw_prefab(editor, kit, dialog)
    dialog.name = dialog.name or ""
    kit:dialog("SAVE AS A PREFAB", 460, 150, function(_, x, y, w, h)
        local theme  = kit.theme
        local bottom = y + h - theme.row - 2
        local held   = editor.selection
        labelled(kit, x, y, "NAME")
        local name, _, done = kit:field("prefab_name", x + LABEL_W, y, w - LABEL_W, dialog.name,
            { max = NAME_MAX, hint = "GUN NEST" })
        dialog.name = name:upper()
        local parts = {}
        if held:count() > 0 then parts[#parts + 1] = held:count() .. (held:count() == 1 and " OBJECT" or " OBJECTS") end
        if #held.roads > 0 then parts[#parts + 1] = #held.roads .. (#held.roads == 1 and " ROAD" or " ROADS") end
        kit:label(table.concat(parts, " AND ") .. ", KEPT IN THE PREFABS FOLDER FOR EVERY MAP", x, y + theme.row + 8, w,
            theme.row, { color = theme.text_dim, size = theme.font_small })
        local ok = kit:button("prefab_ok", x + w - 100, bottom, 100, theme.row + 2,
            { text = "SAVE", primary = true, disabled = dialog.name == "" })
        if (ok or (done and love.keyboard.isDown("return", "kpenter"))) and dialog.name ~= "" then
            close(editor)
            editor:save_prefab(dialog.name)
        end
        if kit:button("prefab_cancel", x + w - 208, bottom, 100, theme.row + 2, { text = "CANCEL" }) then close(editor) end
    end)
end

-- ground generator

local function draw_generate(editor, kit, dialog)
    local art = editor.doc:art()
    dialog.stage   = dialog.stage or Catalog.stages(art)[1]
    dialog.density = dialog.density or 100
    if dialog.trees == nil then dialog.trees, dialog.scenery = true, true end
    kit:dialog("GENERATE GROUND", 520, 300, function(_, x, y, w, h)
        local theme  = kit.theme
        local fw     = w - LABEL_W
        local bottom = y + h - theme.row - 2
        kit:paragraph("SCATTERS THE STONES, TUFTS AND TREES OF A STAGE OVER THE WHOLE MAP, AS THICK AS THAT STAGE "
            .. "HAS THEM, KEEPING CLEAR OF EVERYTHING ELSE.", x, y, w, { color = theme.text_dim, size = theme.font_small })
        y = y + 36
        labelled(kit, x, y, "SCENERY AS IN")
        dialog.stage = kit:choice("gen_stage", x + LABEL_W, y, fw, stage_choices(art), dialog.stage)
        y = y + theme.row + 8
        labelled(kit, x, y, "DENSITY")
        dialog.density = kit:number("gen_density", x + LABEL_W, y, 130, dialog.density,
            { min = 10, max = 300, step = 10, big = 50, suffix = " %" })
        y = y + theme.row + 8
        dialog.scenery = kit:check("gen_scenery", x + LABEL_W, y, fw, "STONES, TUFTS AND GROUND TEXTURE", dialog.scenery)
        y = y + theme.row + 2
        dialog.trees = kit:check("gen_trees", x + LABEL_W, y, fw, "TREES", dialog.trees)
        if dialog.stage then
            local names = {}
            for i, item in ipairs(Generate.clutter(dialog.stage)) do names[i] = item.sprite:upper() end
            kit:label(kit:fit(table.concat(names, ", "), w), x, y + theme.row + 8, w, theme.row,
                { color = theme.text_dim, size = theme.font_small })
        end
        if kit:button("gen_go", x + w - 110, bottom, 110, theme.row + 2,
            { text = "GENERATE", primary = true, disabled = not dialog.stage }) then
            local count = Generate.ground(editor.doc, dialog.stage,
                { density = dialog.density / 100, trees = dialog.trees, scenery = dialog.scenery })
            close(editor)
            editor:say(count .. " OBJECTS ADDED")
        end
        if kit:button("gen_clear", x + w - 248, bottom, 132, theme.row + 2, { text = "CLEAR SCENERY", danger = true }) then
            local count = Generate.clear(editor.doc)
            editor.selection:prune(editor.doc)
            editor:say(count .. " OBJECTS REMOVED")
        end
        if kit:button("gen_close", x, bottom, 90, theme.row + 2, { text = "CLOSE" }) then close(editor) end
    end)
end

-- questions

local function draw_ask(editor, kit, dialog)
    kit:dialog(dialog.title, 500, 170, function(_, x, y, w, h)
        local theme = kit.theme
        kit:paragraph(dialog.text, x, y + 4, w)
        local bx = x + w
        for _, button in ipairs(dialog.buttons) do
            local bw = math.max(96, kit:text_width(button.label) + 28)
            bx = bx - bw
            if kit:button("ask_" .. button.label, bx, y + h - theme.row - 2, bw, theme.row + 2,
                { text = button.label, primary = button.primary, danger = button.danger }) then
                close(editor)
                if button.action then button.action() end
            end
            bx = bx - 8
        end
    end)
end

-- keys

local KEYS = {
    { "V  P  B  E  R  L  O  U", "SELECT, PLACE, SCATTER, ERASE, ROUTE, LINE, ROAD, MEASURE" },
    { "WHEEL", "ZOOM ABOUT THE POINTER" },
    { "RIGHT OR MIDDLE DRAG, SPACE + DRAG", "MOVE THE VIEW" },
    { "W A S D", "MOVE THE VIEW" },
    { "ARROWS", "NUDGE THE SELECTION (SHIFT: 8 PX)" },
    { "SHIFT + CLICK", "ADD TO OR TAKE FROM THE SELECTION" },
    { "CLICK AGAIN", "REACH THE OBJECT UNDERNEATH" },
    { "TAB", "SELECT SINGLE PARTS OR WHOLE GROUPS" },
    { "CTRL + C  X  V  D", "COPY, CUT, PASTE, DUPLICATE" },
    { "DEL", "DELETE THE SELECTION, OR A ROUTE POINT" },
    { "CTRL + Z  /  CTRL + Y", "UNDO, REDO" },
    { "CTRL + S", "SAVE" },
    { "G  /  CTRL + G", "GRID, SNAP TO GRID" },
    { "HOME  F  M", "GO TO THE HOME PAD, SHOW THE SELECTION, OVERVIEW MAP" },
    { "ENTER  /  BACKSPACE", "FINISH A ROUTE, LINE OR ROAD, TAKE BACK ITS LAST POINT" },
    { "CLICK AN END", "CARRY A ROUTE, LINE OR ROAD ON FROM THERE" },
    { "CTRL WHILE DRAWING OR DRAGGING", "ROUTE AND LINE SEGMENTS IN 45 DEGREE STEPS; A MOVE ALONG ONE AXIS" },
    { "CTRL + [  ]  /  SHIFT + H  V", "TURN THE SELECTION A QUARTER, MIRROR IT" },
    { "F5  /  SHIFT + F5", "TRY THE MAP FROM THE HOME PAD, OR FROM HERE (ESC COMES BACK)" },
    { "F6", "PREVIEW THE BRIEFING" },
}

local function draw_help(editor, kit)
    kit:dialog("KEYS", 660, 588, function(_, x, y, w, h)
        local theme = kit.theme
        for i, item in ipairs(KEYS) do
            local ry = y + (i - 1) * (theme.row + 2)
            kit:label(item[1], x, ry, 270, theme.row, { color = theme.accent, size = theme.font_small })
            kit:label(item[2], x + 276, ry, w - 276, theme.row, { size = theme.font_small })
        end
        if kit:button("help_close", x + w - 100, y + h - theme.row - 2, 100, theme.row + 2, { text = "CLOSE", primary = true }) then
            close(editor)
        end
    end)
end

local DRAW = { settings = draw_settings, cards = draw_cards, new = draw_new, open = draw_open,
               save_as = draw_save_as, prefab = draw_prefab, generate = draw_generate, ask = draw_ask,
               help = draw_help }

function Dialogs.draw(editor, kit)
    local dialog = editor.dialog
    if dialog then DRAW[dialog.kind](editor, kit, dialog) end
end

Dialogs.close = close

return Dialogs
