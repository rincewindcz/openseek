-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local MapFile  = require "engine.game.map_file"
local Catalog  = require "engine.editor.catalog"
local Generate = require "engine.editor.generate"

-- The dialogs of the map editor: map settings, new map, open, save as, ground
-- generator, key help and the yes / no questions. editor.dialog holds the open
-- one as { kind, ... }; Dialogs.draw asks the widget kit for it each frame.
local Dialogs = {}

local LABEL_W    = 150
local PARAGRAPHS = 3     -- briefing paragraphs: the briefing screen has three text slots
local NAME_MAX   = 40
local TEXT_MAX   = 260

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
    y = y + theme.row + 6
    labelled(kit, x, y, "VEHICLE")
    local vehicles = { { label = "PLAYER CHOOSES", value = "" }, { label = "CHOPPER ONLY", value = "chopper" },
                       { label = "TANK ONLY", value = "tank" } }
    local vehicle, vehicle_changed = kit:choice("set_vehicle", x + LABEL_W, y, fw, vehicles, map.vehicle or "")
    if vehicle_changed then doc:set_map("vehicle", vehicle ~= "" and vehicle or nil) end
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

local GOALS = {
    { key = "destroy",  title = "DESTROY THE MISSION TARGETS", hint = "DESTROY TARGETS" },
    { key = "rescue",   title = "PICK UP THE PEOPLE", hint = "RESCUE", optional = true },
    { key = "sabotage", title = "AGENTS IN AND OUT", hint = "RECOVER AGENTS" },
}

local function set_goal(editor, key, field, value)
    local goals = {}
    for k, v in pairs(editor.doc.map.objectives) do goals[k] = v end
    local goal = {}
    for k, v in pairs(goals[key] or {}) do goal[k] = v end
    goal[field] = value
    goals[key] = next(goal) and goal or nil
    editor.doc:set_map("objectives", goals, "OBJECTIVES")
end

local function settings_objectives(editor, kit, x, y, w)
    local theme = kit.theme
    local doc   = editor.doc
    local map   = doc.map
    kit:paragraph("OBJECTIVES FOLLOW FROM WHAT IS ON THE MAP. HERE THEY ARE WORDED FOR THE PLAYER.", x, y, w,
        { color = theme.text_dim, size = theme.font_small })
    y = y + 30
    for _, goal in ipairs(GOALS) do
        local own = map.objectives[goal.key] or {}
        kit:label(goal.title, x, y, w, theme.row, { color = theme.accent, size = theme.font_small })
        y = y + theme.row
        labelled(kit, x, y, "SHOWN AS")
        local label, _, done = kit:field("goal_" .. goal.key, x + LABEL_W, y, w - LABEL_W, own.label or "",
            { hint = goal.hint, max = NAME_MAX, commit = true })
        if done then set_goal(editor, goal.key, "label", label ~= "" and label:upper() or nil) end
        y = y + theme.row + 4
        if goal.optional then
            local optional, changed = kit:check("goal_opt_" .. goal.key, x + LABEL_W, y, w - LABEL_W,
                "OPTIONAL: THE PHASE CAN BE WON WITHOUT IT", own.optional == true)
            if changed then set_goal(editor, goal.key, "optional", optional or nil) end
            y = y + theme.row + 4
        end
        y = y + 6
    end
    kit:separator(x, y, w)
    y = y + 8
    local hold, hold_changed = kit:check("set_hold", x, y, w, "AGENTS STAY INSIDE UNTIL EVERY BUILDING HAS ONE",
        map.hold_agents == true)
    if hold_changed then doc:set_map("hold_agents", hold) end
    y = y + theme.row + 2
    local commander, commander_changed = kit:check("set_commander", x, y, w,
        "COMMANDER RULE: THE COMMANDERS BUILDING APPEARS LAST AND ENDS THE PHASE", map.commander == true)
    if commander_changed then doc:set_map("commander", commander) end
end

local function settings_briefing(editor, kit, x, y, w, h)
    local theme = kit.theme
    local doc   = editor.doc
    kit:paragraph("UP TO THREE PARAGRAPHS, SHOWN ON THE BRIEFING SCREEN BEFORE THE PHASE.", x, y, w,
        { color = theme.text_dim, size = theme.font_small })
    y = y + 22
    local box_h = math.floor((h - 22 - PARAGRAPHS * (theme.row + 12)) / PARAGRAPHS)
    for i = 1, PARAGRAPHS do
        local text = doc.map.briefing[i] or ""
        local new, _, done = kit:field("brief_" .. i, x, y, w, text,
            { hint = "PARAGRAPH " .. i, max = TEXT_MAX, commit = true })
        if done and new ~= text then
            local briefing = {}
            for k = 1, PARAGRAPHS do briefing[k] = doc.map.briefing[k] or "" end
            briefing[i] = new:upper()
            while #briefing > 0 and briefing[#briefing] == "" do table.remove(briefing) end
            doc:set_map("briefing", briefing, "BRIEFING")
        end
        y = y + theme.row + 4
        kit:paragraph(text, x + theme.pad, y, w - theme.pad * 2, { color = theme.text_dim, size = theme.font_small })
        y = y + box_h + 8
    end
end

local SETTINGS_PAGES = {
    general = settings_general, environment = settings_environment,
    objectives = settings_objectives, briefing = settings_briefing,
}

local function draw_settings(editor, kit, dialog)
    kit:dialog("MAP SETTINGS", 600, 470, function(_, x, y, w, h)
        local theme = kit.theme
        dialog.tab = kit:tabs("set_tabs", x, y, w, SETTINGS_TABS, dialog.tab or "general")
        SETTINGS_PAGES[dialog.tab](editor, kit, x, y + theme.row + 16, w, h - theme.row * 2 - 30)
        if kit:button("set_close", x + w - 100, y + h - theme.row - 2, 100, theme.row + 2, { text = "CLOSE", primary = true }) then
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
    { "V  P  B  E  R  L", "SELECT, PLACE, SCATTER, ERASE, ROUTE, LINE" },
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
    { "ENTER  /  BACKSPACE", "FINISH A ROUTE OR LINE, TAKE BACK ITS LAST POINT" },
    { "F5", "TRY THE MAP (ESC COMES BACK)" },
}

local function draw_help(editor, kit)
    kit:dialog("KEYS", 620, 470, function(_, x, y, w, h)
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

local DRAW = { settings = draw_settings, new = draw_new, open = draw_open, save_as = draw_save_as,
               generate = draw_generate, ask = draw_ask, help = draw_help }

function Dialogs.draw(editor, kit)
    local dialog = editor.dialog
    if dialog then DRAW[dialog.kind](editor, kit, dialog) end
end

Dialogs.close = close

return Dialogs
