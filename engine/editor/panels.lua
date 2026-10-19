-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Roads    = require "engine.game.roads"
local Catalog  = require "engine.editor.catalog"
local Ops      = require "engine.editor.ops"
local Prefabs  = require "engine.editor.prefabs"
local Validate = require "engine.editor.validate"

-- The panels of the map editor's dock: OBJECTS (the catalog), PROPERTIES (the
-- inspector of the selection, or the map's summary), LAYERS and CHECKS. Each
-- is a function drawing into a rect with the widget kit; editor is the editor
-- scene.
local Panels = {}

local COLUMNS     = 3
local THUMB       = 52
local CELL_H      = 74
local LABEL_W     = 112
local BASE_FLAG   = 0x40
local RADAR_FLAG  = 0x10
local TOWER_FLAG  = 0x20
local TARGET_FLAG = 0x01
local COMMANDER   = 2    -- structure class behaviour of the commander building
local MEDAL       = 1    -- structure class behaviour of a forced medal drop
local MAX_PEOPLE  = 9
local MAX_CREW    = 6

-- objects

-- The parts of an entry drawn as they stand on the map, fitted into a box.
local function draw_entry(kit, entry, x, y, w, h)
    local x0, y0, x1, y1 = 0, 0, 0, 0
    local infos = {}
    for i, part in ipairs(entry.parts) do
        local info = Catalog.type_info(Catalog.part_type(part))
        infos[i] = info
        x0, y0 = math.min(x0, info.ox), math.min(y0, info.oy)
        x1, y1 = math.max(x1, info.ox + info.w), math.max(y1, info.oy + info.h)
    end
    local k  = math.min(w / (x1 - x0), h / (y1 - y0), 2)
    local cx = x + (w - (x1 - x0) * k) / 2 - x0 * k
    local cy = y + (h - (y1 - y0) * k) / 2 - y0 * k
    love.graphics.setColor(1, 1, 1, 1)
    for _, info in ipairs(infos) do
        if info.img then
            love.graphics.draw(info.img, cx + info.ox * k, cy + info.oy * k, 0, k, k)
        else
            kit:icon("helicopter", x + (w - 20) / 2, y + (h - 20) / 2, 20, kit.theme.accent)
        end
    end
end

Panels.draw_entry = draw_entry

local function by_depth(a, b)
    if a.dy ~= b.dy then return a.dy < b.dy end
    return a.dx < b.dx
end

-- A prefab drawn as it will stand on the map, fitted into a box: its roads'
-- borders, the ground under its objects, then the objects.
local function draw_prefab(clip, x, y, w, h)
    local g = love.graphics
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local decals, objects = {}, {}
    for _, item in ipairs(clip.items) do
        local info = Catalog.type_info(item.map_type)
        local list = info.kind_name == "ground_decal" and decals or objects
        list[#list + 1] = { info = info, dx = item.dx, dy = item.dy }
        x0, y0 = math.min(x0, item.dx + info.ox), math.min(y0, item.dy + info.oy)
        x1, y1 = math.max(x1, item.dx + info.ox + info.w), math.max(y1, item.dy + info.oy + info.h)
    end
    -- The roads are built where they lie from the prefab's middle, shifted
    -- into the positive numbers the builder's grid wants.
    local reach = 0
    for _, road in ipairs(clip.roads) do
        for _, p in ipairs(road.points) do
            reach = math.max(reach, math.abs(p[1]) + road.width, math.abs(p[2]) + road.width)
        end
    end
    local lanes = {}
    for i, road in ipairs(clip.roads) do
        local points = {}
        for k, p in ipairs(road.points) do points[k] = { p[1] + reach, p[2] + reach } end
        lanes[i] = { points = points, width = road.width, pitch = 0, edge = road.edge }
    end
    local segments = Roads.build(lanes, reach * 4 + 1).segments
    for _, s in ipairs(segments) do
        x0, y0 = math.min(x0, s.x1 - reach, s.x2 - reach), math.min(y0, s.y1 - reach, s.y2 - reach)
        x1, y1 = math.max(x1, s.x1 - reach, s.x2 - reach), math.max(y1, s.y1 - reach, s.y2 - reach)
    end
    if x0 >= x1 or y0 >= y1 then return end
    table.sort(decals, by_depth)
    table.sort(objects, by_depth)
    local k  = math.min(w / (x1 - x0), h / (y1 - y0), 2)
    local cx = x + (w - (x1 - x0) * k) / 2 - x0 * k
    local cy = y + (h - (y1 - y0) * k) / 2 - y0 * k
    g.setLineWidth(1)
    for _, s in ipairs(segments) do
        g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255, 1)
        g.line(cx + (s.x1 - reach) * k, cy + (s.y1 - reach) * k, cx + (s.x2 - reach) * k, cy + (s.y2 - reach) * k)
    end
    g.setColor(1, 1, 1, 1)
    for _, list in ipairs({ decals, objects }) do
        for _, item in ipairs(list) do
            local info = item.info
            if info.img then g.draw(info.img, cx + (item.dx + info.ox) * k, cy + (item.dy + info.oy) * k, 0, k, k) end
        end
    end
end

-- The prefabs: a button to save the selection as one, then the saved ones. A
-- click arms the place tool with a prefab; the bin on a cell deletes it.
local function prefab_list(editor, kit, x, y, w, h, needle)
    local theme = kit.theme
    local pad   = theme.pad
    if kit:button("prefab_save", x + pad, y, w - pad * 2, theme.row + 2, { text = "SAVE THE SELECTION AS A PREFAB",
        icon = "prefab", disabled = not editor.selection:any(),
        tip = "THE SELECTED OBJECTS AND ROADS, TO PLACE AGAIN ON ANY MAP" }) then
        editor:open_dialog("prefab")
    end
    local cy     = y + theme.row + 2 + theme.gap
    local list_h = y + h - cy
    local found  = {}
    for _, prefab in ipairs(Prefabs.list()) do
        if needle == "" or prefab.label:upper():find(needle, 1, true) then found[#found + 1] = prefab end
    end
    local cell_w = (w - pad * 2 - 4) / COLUMNS
    local rows   = math.ceil(#found / COLUMNS)
    local offset = kit:scroll_begin("prefab_list", x, cy, w, list_h, rows * CELL_H + pad)
    for i, prefab in ipairs(found) do
        local col, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        local ex, ey = x + pad + col * cell_w, cy + row * CELL_H - offset
        if ey + CELL_H > cy and ey < cy + list_h then
            local id      = "prefab_" .. prefab.name
            local current = editor.placing ~= nil and editor.placing.key == "prefab/" .. prefab.name
            -- The bin sits on the cell and is asked first, so its click is its own.
            local binned, bin_hover = kit:click(id .. "#bin", ex + cell_w - 22, ey + 2, 18, 18)
            local clicked, hover    = kit:click(id, ex, ey, cell_w - 2, CELL_H - 2)
            if bin_hover then kit:set_tip(id .. "#bin", "DELETE THIS PREFAB")
            elseif hover then kit:set_tip(id, prefab.label) end
            kit:rect(ex, ey, cell_w - 2, CELL_H - 2, (hover or bin_hover) and theme.widget_hot or theme.widget, 3)
            if current then kit:frame(ex, ey, cell_w - 2, CELL_H - 2, theme.accent, 3) end
            kit:clip(ex + 2, ey + 2, cell_w - 6, THUMB + 2)
            draw_prefab(prefab.clip, ex + 4, ey + 3, cell_w - 10, THUMB)
            kit:unclip()
            kit:label(prefab.label, ex, ey + THUMB + 4, cell_w - 2, 14,
                { align = "center", size = theme.font_small, color = current and theme.accent or theme.text, pad = 2 })
            if hover or bin_hover then
                kit:rect(ex + cell_w - 22, ey + 2, 18, 18, { 0, 0, 0, 0.6 }, 3)
                kit:icon("trash", ex + cell_w - 21, ey + 3, 16, bin_hover and theme.danger or theme.text_dim)
            end
            if binned then editor:delete_prefab(prefab)
            elseif clicked then editor:pick_prefab(prefab) end
        end
    end
    if #found == 0 then
        kit:paragraph(needle == "" and "NO PREFAB YET. SELECT WHAT BELONGS TOGETHER, A GUN NEST OR A COMPOUND WITH ITS "
            .. "ROADS, AND SAVE IT HERE TO PLACE IT AGAIN." or "NO PREFAB OF THAT NAME", x + pad, cy + 8, w - pad * 2,
            { color = theme.text_dim })
    end
    kit:scroll_end()
end

function Panels.objects(editor, kit, x, y, w, h)
    local theme = kit.theme
    local pad   = theme.pad
    local cy    = y + pad

    -- Art set: the map's own, or another one's sprites mixed in.
    local arts = {}
    for _, art in ipairs(Catalog.arts()) do
        if art.present then arts[#arts + 1] = { label = art.label, value = tostring(art.art) } end
    end
    kit:label("ART SET", x + pad, cy, 70, theme.row, { color = theme.text_dim, size = theme.font_small })
    editor.catalog_art = kit:choice("cat_art", x + pad + 70, cy, w - pad * 2 - 70, arts, editor.catalog_art)
    cy = cy + theme.row + theme.gap

    local tabs = {}
    for _, category in ipairs(Catalog.data().categories) do
        tabs[#tabs + 1] = { value = category.id, icon = category.icon, tip = category.label }
    end
    editor.category = kit:tabs("cat_tabs", x, cy, w, tabs, editor.category)
    cy = cy + theme.row + 4 + theme.gap

    editor.search = kit:field("cat_search", x + pad, cy, w - pad * 2, editor.search, { hint = "SEARCH", max = 24 })
    cy = cy + theme.row + theme.gap

    local entries = {}
    local needle  = editor.search:upper()
    if editor.category == "prefabs" then
        prefab_list(editor, kit, x, cy, w, y + h - cy, needle)
        return
    end
    local catalog = Catalog.entries(editor.catalog_art)
    for _, entry in ipairs(needle ~= "" and catalog.list or (catalog.by_category[editor.category] or {})) do
        if needle == "" or entry.label:find(needle, 1, true) then entries[#entries + 1] = entry end
    end

    local list_h = y + h - cy
    local cell_w = (w - pad * 2 - 4) / COLUMNS
    local rows   = math.ceil(#entries / COLUMNS)
    local offset = kit:scroll_begin("cat_list", x, cy, w, list_h, rows * CELL_H + pad)
    local scattering = editor.tool == "scatter"
    for i, entry in ipairs(entries) do
        local col, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        local ex, ey = x + pad + col * cell_w, cy + row * CELL_H - offset
        if ey + CELL_H > cy and ey < cy + list_h then
            local id      = "cat_" .. entry.art .. "_" .. entry.key
            local ticked  = editor.scatter.set[entry.key] ~= nil
            local current = (scattering and ticked) or (not scattering and editor.placing == entry)
            local clicked, hover = kit:click(id, ex, ey, cell_w - 2, CELL_H - 2)
            if hover then kit:set_tip(id, entry.label) end
            kit:rect(ex, ey, cell_w - 2, CELL_H - 2, hover and theme.widget_hot or theme.widget, 3)
            if current then kit:frame(ex, ey, cell_w - 2, CELL_H - 2, theme.accent, 3) end
            draw_entry(kit, entry, ex + 4, ey + 3, cell_w - 10, THUMB)
            kit:label(entry.label, ex, ey + THUMB + 4, cell_w - 2, 14,
                { align = "center", size = theme.font_small, color = current and theme.accent or theme.text, pad = 2 })
            if scattering and ticked then kit:icon("check", ex + cell_w - 20, ey + 2, 16, theme.accent) end
            if clicked then editor:pick_entry(entry) end
        end
    end
    if #entries == 0 then
        kit:label("NOTHING HERE IN THIS GAME DATA", x, cy + 8, w, theme.row, { align = "center", color = theme.text_dim })
    end
    kit:scroll_end()
end

-- properties

-- The value all objects share, or nil and true when they differ.
local function shared(objects, get)
    local value = get(objects[1])
    for i = 2, #objects do
        if get(objects[i]) ~= value then return nil, true end
    end
    return value, false
end

local function has_flag(flags, bit)
    return math.floor((flags or 0) / bit) % 2 == 1
end

local function with_flag(flags, bit, on)
    flags = flags or 0
    if has_flag(flags, bit) == on then return flags end
    return on and flags + bit or flags - bit
end

-- A row laid out as label and widget; returns the y below it.
local function row(kit, x, y, label)
    kit:label(label, x, y, LABEL_W, kit.theme.row, { color = kit.theme.text_dim, size = kit.theme.font_small })
    return y + kit.theme.row + 2
end

local Fields = {}

function Fields.number(editor, kit, x, y, w, objects, label, field, opts)
    local doc = editor.doc
    local value, mixed = shared(objects, function(o) return doc:info(o).cls[field] or 0 end)
    local shown = mixed and (doc:info(objects[1]).cls[field] or 0) or value
    local id    = "prop_" .. field .. "_" .. doc:info(objects[1]).kind_name
    local new, changed = kit:number(id, x + LABEL_W, y, w - LABEL_W, shown, opts)
    if changed then doc:set_class_fields(objects, { [field] = new }, label) end
    if mixed then kit:label("MIXED", x + 62, y, 48, kit.theme.row, { size = kit.theme.font_small, color = kit.theme.warn }) end
    return row(kit, x, y, label)
end

function Fields.choice(editor, kit, x, y, w, objects, label, field, choices)
    local doc = editor.doc
    local value = shared(objects, function(o) return doc:info(o).cls[field] or 0 end)
    local id    = "prop_" .. field .. "_" .. doc:info(objects[1]).kind_name
    local new, changed = kit:choice(id, x + LABEL_W, y, w - LABEL_W, choices, value, { empty = "MIXED", list_w = 230 })
    if changed then doc:set_class_fields(objects, { [field] = new }, label) end
    return row(kit, x, y, label)
end

function Fields.flag(editor, kit, x, y, w, objects, label, bit, extra)
    local doc   = editor.doc
    local value = shared(objects, function(o) return has_flag(doc:info(o).cls.flags, bit) end)
    local new, changed = kit:check("prop_flag" .. bit, x, y, w, label, value == true)
    if changed then
        doc:begin(label)
        for _, o in ipairs(objects) do
            local changes = { flags = with_flag(doc:info(o).cls.flags, bit, new) }
            for k, v in pairs(extra and extra(new) or {}) do changes[k] = v end
            doc:set_class_fields({ o }, changes, label)
        end
        doc:commit()
    end
    return y + kit.theme.row + 2
end

local function route_row(editor, kit, x, y, w, objects)
    local doc     = editor.doc
    local choices = { { label = "NONE: STANDS STILL", value = 0 } }
    for i, route in ipairs(doc.map.routes) do
        choices[#choices + 1] = { label = string.format("ROUTE %d  (%d POINTS)", i, #route.points), value = route.id }
    end
    local value = shared(objects, function(o) return o.route or 0 end)
    local bw    = 58
    local new, changed = kit:choice("prop_route", x + LABEL_W, y, w - LABEL_W - bw - 4, choices, value,
        { empty = "MIXED", list_w = 200 })
    if changed then doc:set_field(objects, "route", new ~= 0 and new or nil, "ROUTE") end
    if kit:button("prop_route_draw", x + w - bw, y, bw, kit.theme.row,
        { text = "DRAW", tip = "DRAW A NEW ROUTE FOR THE SELECTED UNITS" }) then
        editor:set_tool("route")
    end
    return row(kit, x, y, "ROUTE")
end

local SECTIONS = {}

local function common_rows(editor, kit, x, y, w, objects)
    y = Fields.number(editor, kit, x, y, w, objects, "TOUGHNESS", "toughness", { min = 0, max = 999 })
    y = Fields.number(editor, kit, x, y, w, objects, "SCORE", "hit_points", { min = 0, max = 9999, step = 10, big = 100 })
    return y
end

local function target_row(editor, kit, x, y, w, objects)
    local doc   = editor.doc
    local value = shared(objects, function(o) return doc:info(o).cls.is_target == true end)
    local new, changed = kit:check("prop_target", x, y, w, "MISSION TARGET", value == true,
        { tip = "DESTROYING EVERY MISSION TARGET IS AN OBJECTIVE OF THE MAP" })
    if changed then
        doc:begin("MISSION TARGET")
        for _, o in ipairs(objects) do
            doc:set_class_fields({ o }, { is_target = new, flags = with_flag(doc:info(o).cls.flags, TARGET_FLAG, new) })
        end
        doc:commit()
    end
    return y + kit.theme.row + 2
end

function SECTIONS.structure(editor, kit, x, y, w, objects)
    local doc   = editor.doc
    local theme = kit.theme
    y = common_rows(editor, kit, x, y, w, objects)
    y = target_row(editor, kit, x, y, w, objects)

    -- What it leaves behind: nothing, a random pickup, or always a medal.
    local drops = { { label = "NOTHING", value = "none" }, { label = "RANDOM PICKUP", value = "random" },
                    { label = "MEDAL", value = "medal" } }
    local drop = shared(objects, function(o)
        local cls = doc:info(o).cls
        if cls.behaviour == MEDAL then return "medal" end
        return (cls.drop or -1) >= 0 and "random" or "none"
    end)
    local new_drop, drop_changed = kit:choice("prop_drop", x + LABEL_W, y, w - LABEL_W, drops, drop, { empty = "MIXED" })
    if drop_changed then
        doc:begin("DROPS")
        for _, o in ipairs(objects) do
            local behaviour = doc:info(o).cls.behaviour or 0
            if new_drop == "medal" then behaviour = MEDAL elseif behaviour == MEDAL then behaviour = 0 end
            doc:set_class_fields({ o }, { drop = new_drop == "none" and -1 or 0, behaviour = behaviour })
        end
        doc:commit()
    end
    y = row(kit, x, y, "DROPS")

    local guides = { { label = "NOTHING", value = 0 }, { label = "GROUND MISSILES", value = RADAR_FLAG },
                     { label = "HELICOPTER MISSILES", value = TOWER_FLAG } }
    local guide = shared(objects, function(o)
        local flags = doc:info(o).cls.flags
        return has_flag(flags, RADAR_FLAG) and RADAR_FLAG or (has_flag(flags, TOWER_FLAG) and TOWER_FLAG or 0)
    end)
    local new_guide, guide_changed = kit:choice("prop_guide", x + LABEL_W, y, w - LABEL_W, guides, guide,
        { empty = "MIXED", list_w = 190, tip = "ENEMY MISSILES TRACK WORSE ONCE THEIR RADARS OR RADIO TOWERS ARE GONE" })
    if guide_changed then
        doc:begin("GUIDES")
        for _, o in ipairs(objects) do
            local flags = with_flag(with_flag(doc:info(o).cls.flags, RADAR_FLAG, new_guide == RADAR_FLAG),
                TOWER_FLAG, new_guide == TOWER_FLAG)
            doc:set_class_fields({ o }, { flags = flags })
        end
        doc:commit()
    end
    y = row(kit, x, y, "GUIDES")

    y = Fields.flag(editor, kit, x, y, w, objects, "OWN BASE BUILDING", BASE_FLAG)

    local commander = shared(objects, function(o) return doc:info(o).cls.behaviour == COMMANDER end)
    local new_commander, commander_changed = kit:check("prop_commander", x, y, w, "COMMANDERS BUILDING",
        commander == true, { tip = "HELD BACK UNTIL EVERY OTHER TARGET IS DESTROYED; THE PHASE ENDS WHEN IT FALLS" })
    if commander_changed then
        doc:begin("COMMANDERS BUILDING")
        for _, o in ipairs(objects) do
            local flags = with_flag(doc:info(o).cls.flags, TARGET_FLAG, new_commander or doc:info(o).cls.is_target)
            doc:set_class_fields({ o }, { behaviour = new_commander and COMMANDER or 0,
                is_target = new_commander or doc:info(o).cls.is_target, flags = flags })
        end
        if new_commander then doc:set_map("commander", true) end
        doc:commit()
    end
    y = y + theme.row + 2

    -- The objective marks ride on single buildings.
    if #objects == 1 then
        local building = objects[1]
        kit:separator(x, y + 2, w)
        y = y + 7
        local people = doc:info(building).cls.pows or 0
        local new_people, people_changed = kit:number("prop_people", x + LABEL_W, y, w - LABEL_W, people,
            { min = 0, max = MAX_PEOPLE })
        if people_changed and not Ops.set_people(doc, building, new_people) then
            editor:say("THIS GAME DATA HAS NO POW FLAG OR LANDING PAD SPRITE")
        end
        y = row(kit, x, y, "PEOPLE INSIDE")

        local agent = #Ops.drop_pads(doc, building) > 0
        local new_agent, agent_changed = kit:check("prop_agent", x, y, w, "AGENT TARGET", agent,
            { tip = "A VEHICLE LANDS ON ITS PAD TO SEND AN AGENT IN, AND AGAIN TO TAKE THE AGENT HOME" })
        if agent_changed and not Ops.set_agent_target(doc, building, new_agent) then
            editor:say("THIS GAME DATA HAS NO LANDING PAD SPRITE")
        end
        y = y + theme.row + 2

        local crew = #Ops.crew(doc, building)
        local new_crew, crew_changed = kit:number("prop_crew", x + LABEL_W, y, w - LABEL_W, crew,
            { min = 0, max = MAX_CREW })
        if crew_changed and not Ops.set_crew(doc, building, new_crew) then
            editor:say("THIS GAME DATA HAS NO SPRITE FOR WAITING PEOPLE")
        end
        y = row(kit, x, y, "CREW WAITING")
    end
    return y
end

function SECTIONS.flak_turret(editor, kit, x, y, w, objects)
    y = common_rows(editor, kit, x, y, w, objects)
    y = Fields.choice(editor, kit, x, y, w, objects, "FIRES", "behaviour", Catalog.routines())
    return target_row(editor, kit, x, y, w, objects)
end

local function mover_section(kind)
    return function(editor, kit, x, y, w, objects)
        y = common_rows(editor, kit, x, y, w, objects)
        local riding = false
        for _, o in ipairs(objects) do
            if Catalog.is_ride(editor.doc:info(o).cls) then riding = true end
        end
        if riding then
            kit:label("RIDES OUT OF ITS HANGAR TO FIRE", x, y, w, kit.theme.row, { color = kit.theme.text_dim })
            y = y + kit.theme.row + 2
        else
            y = Fields.choice(editor, kit, x, y, w, objects, "MOVES", "behaviour", Catalog.movements(kind))
            y = route_row(editor, kit, x, y, w, objects)
        end
        return target_row(editor, kit, x, y, w, objects)
    end
end

SECTIONS.tank  = mover_section("tank")
SECTIONS.truck = mover_section("truck")

local function soldier_section(editor, kit, x, y, w, objects)
    y = Fields.number(editor, kit, x, y, w, objects, "TOUGHNESS", "toughness", { min = 0, max = 999 })
    return Fields.choice(editor, kit, x, y, w, objects, "WEAPON", "behaviour", Catalog.soldier_modes())
end

SECTIONS.soldier            = soldier_section
SECTIONS.soldier_aggressive = soldier_section

function SECTIONS.enemy_helicopter(editor, kit, x, y, w, objects)
    y = common_rows(editor, kit, x, y, w, objects)
    y = Fields.choice(editor, kit, x, y, w, objects, "WEAPON", "behaviour", Catalog.heli_modes())
    y = Fields.number(editor, kit, x, y, w, objects, "RESPAWN", "field_2c", { min = 0, max = 9999, step = 10, big = 100 })
    y = Fields.number(editor, kit, x, y, w, objects, "LEASH", "field_2e", { min = 0, max = 9999, step = 10, big = 100 })
    return y
end

-- A pickup the map lays out: what it holds, and who can use it.
function SECTIONS.pickup(editor, kit, x, y, w, objects)
    local doc   = editor.doc
    local theme = kit.theme
    local value = shared(objects, function(o) return Catalog.pickup_value(doc.map.types[o.t]) end)
    local only  = shared(objects, function(o) return doc.map.types[o.t].ammo_only == true end)
    local new, changed = kit:choice("prop_pickup", x + LABEL_W, y, w - LABEL_W, Catalog.pickup_choices(), value,
        { empty = "MIXED", list_w = 200 })
    if changed then
        local map_type = Catalog.pickup_type(new)
        map_type.ammo_only = map_type.weapon and only or nil
        doc:set_field(objects, "t", doc:intern(map_type), "PICKUP")
    end
    y = row(kit, x, y, "HOLDS")
    local weapon = value and Catalog.pickup_type(value).weapon
    local text   = "LIES THERE UNTIL IT IS TAKEN."
    if weapon then
        local gives, gives_changed = kit:check("prop_pickup_gives", x, y, w, "GIVES THE WEAPON", only == false,
            { tip = "TAKEN BY A VEHICLE WITHOUT THE WEAPON, IT GIVES THE WEAPON. OFF: AMMUNITION ONLY." })
        if gives_changed then
            local map_type = Catalog.pickup_type(value)
            map_type.ammo_only = not gives or nil
            doc:set_field(objects, "t", doc:intern(map_type), "PICKUP")
        end
        y = y + kit.theme.row + 2
        local users = {}
        for i, vehicle in ipairs(Catalog.weapon_users(weapon)) do users[i] = "THE " .. vehicle:upper() end
        text = "AMMUNITION FOR " .. table.concat(users, " AND ") .. ". "
            .. (only == false and "GIVES THE WEAPON WHEN IT IS NOT ABOARD. LEFT OUT WHEN THE VEHICLE CANNOT USE IT."
                or "LEFT OUT WHEN NOBODY CARRIES THE WEAPON.")
    end
    return y + kit:paragraph(text, x, y + 2, w, { color = theme.text_dim, size = theme.font_small }) + 4
end

-- The selected roads: their width and whether they carry a centre line.
local function roads_section(editor, kit, x, y, w, roads)
    local doc    = editor.doc
    local limits = Catalog.data().roads
    local style  = Catalog.road_style(doc:art())
    local width, mixed = shared(roads, function(road) return road.width end)
    local new, changed = kit:number("prop_road_width", x + LABEL_W, y, w - LABEL_W, mixed and roads[1].width or width,
        { min = limits.min_width, max = limits.max_width, step = 2, big = 8 })
    if changed then
        doc:begin("ROAD WIDTH")
        for _, road in ipairs(roads) do doc:set_road(road, "width", new) end
        doc:commit()
    end
    if mixed then kit:label("MIXED", x + 62, y, 48, kit.theme.row, { size = kit.theme.font_small, color = kit.theme.warn }) end
    y = row(kit, x, y, "WIDTH")
    local marks = shared(roads, function(road) return (road.pitch or 0) > 0 end)
    local new_marks, marks_changed = kit:check("prop_road_marks", x, y, w, "CENTRE LINE", marks == true)
    if marks_changed then
        doc:begin("ROAD CENTRE LINE")
        for _, road in ipairs(roads) do doc:set_road(road, "pitch", new_marks and style.pitch or 0) end
        doc:commit()
    end
    return y + kit.theme.row + 2
end

-- A player's start: nothing to set, only what it is for.
function SECTIONS.start(editor, kit, x, y, w, objects)
    local number = editor.doc:info(objects[1]).start
    return y + kit:paragraph("THE VEHICLE OF PLAYER " .. number .. " IS PUT HERE AT THE START AND AFTER A CRASH. "
        .. "WITHOUT ONE THE PLAYER STARTS ON THE HOME PAD, WHICH STAYS THE PLACE TO RETURN TO.", x, y, w,
        { color = kit.theme.text_dim, size = kit.theme.font_small }) + 4
end

local KIND_TITLES = {
    structure = "BUILDING", flak_turret = "GUN", tank = "TANK HULL", truck = "TRUCK", soldier = "SOLDIER",
    soldier_aggressive = "SOLDIER", enemy_helicopter = "HELICOPTER POST", scenery = "SCENERY", tree = "TREE",
    ground_decal = "GROUND", radar = "RADAR DISH", powerup_marker = "POW FLAG", unknown_14 = "LANDING PAD",
    civilian = "WAITING PERSON", pickup = "PICKUP", start = "PLAYER START", missing = "MISSING SPRITE",
}

local KIND_ORDER = { "structure", "tank", "truck", "flak_turret", "radar", "soldier", "soldier_aggressive",
                     "enemy_helicopter", "powerup_marker", "unknown_14", "civilian", "pickup", "start", "ground_decal",
                     "scenery", "tree", "missing" }

local function map_summary(editor, kit, x, y, w)
    local theme = kit.theme
    local doc   = editor.doc
    local map   = doc.map
    local sum   = Validate.summary(doc)
    y = kit:header("MAP", x - theme.pad, y, w + theme.pad * 2)
    local function line(label, value)
        kit:label(label, x, y, LABEL_W, theme.row, { color = theme.text_dim, size = theme.font_small })
        kit:label(value, x + LABEL_W, y, w - LABEL_W, theme.row)
        y = y + theme.row
    end
    line("NAME", map.name)
    line("ART SET", Catalog.art_label(doc:art()))
    line("SIZE", string.format("%d X %d", map.size, map.size))
    if map.based_on then line("COPY OF", map.based_on:upper()) end
    line("OBJECTS", tostring(#map.objects))
    y = y + 4
    y = kit:header("OBJECTIVES", x - theme.pad, y, w + theme.pad * 2)
    line("TARGETS", tostring(sum.targets))
    line("PEOPLE", tostring(sum.people))
    line("AGENT TARGETS", tostring(sum.agents))
    y = y + 6
    if kit:button("open_settings", x, y, w, theme.row + 2, { text = "MAP SETTINGS", icon = "settings" }) then
        editor:open_dialog("settings")
    end
    y = y + theme.row + 8
    if kit:button("open_generate", x, y, w, theme.row + 2, { text = "GENERATE GROUND", icon = "generate" }) then
        editor:open_dialog("generate")
    end
end

function Panels.properties(editor, kit, x, y, w, h)
    local theme = kit.theme
    local doc   = editor.doc
    local pad   = theme.pad
    local ix, iw = x + pad, w - pad * 2
    local roads = editor.selection.roads
    if editor.selection:count() == 0 then
        if #roads == 0 then
            map_summary(editor, kit, ix, y, iw)
            return
        end
        -- Roads alone: their own rows, and what can be done with them.
        local cy = kit:header(#roads == 1 and "ROAD" or (#roads .. " ROADS"), x, y, w) + 4
        cy = roads_section(editor, kit, ix, cy, iw, roads) + 6
        kit:separator(x, cy, w)
        cy = cy + 6
        local bw = (iw - 4) / 2
        if kit:button("prop_road_dup", ix, cy, bw, theme.row + 2, { text = "COPY", icon = "duplicate",
            tip = "DUPLICATE (CTRL+D)" }) then
            editor:duplicate()
        end
        if kit:button("prop_road_delete", ix + bw + 4, cy, bw, theme.row + 2, { text = "DELETE", icon = "trash",
            danger = true, tip = "DELETE (DEL)" }) then
            editor:delete_selection()
        end
        cy = cy + theme.row + 10
        kit:paragraph("DRAG A ROAD TO MOVE IT. ITS POINTS ARE EDITED WITH THE ROAD TOOL (O).", ix, cy, iw,
            { color = theme.text_dim, size = theme.font_small })
        return
    end

    local by_kind = {}
    for _, o in ipairs(editor.selection.list) do
        local kind = doc:info(o).kind_name
        by_kind[kind] = by_kind[kind] or {}
        table.insert(by_kind[kind], o)
    end

    local offset = kit:scroll_begin("props", x, y, w, h, editor.props_height or h)
    local top    = y - offset
    local cy     = top
    local first  = editor.selection.list[1]
    local info   = doc:info(first)
    local title  = editor.selection:count() == 1 and info.label
        or (first.group and #doc:members(first) == editor.selection:count() and info.label .. " +" .. (editor.selection:count() - 1))
        or (editor.selection:count() .. " OBJECTS")
    cy = kit:header(title, x, cy, w)
    cy = cy + 4

    -- Position of the first object; a change moves the whole selection.
    local half = (iw - LABEL_W - 4) / 2
    local nx, x_changed = kit:number("prop_x", ix + LABEL_W, cy, half, first.x, { min = 0, max = doc:size() - 1 })
    local ny, y_changed = kit:number("prop_y", ix + LABEL_W + half + 4, cy, half, first.y,
        { min = 0, max = doc:size() - 1 })
    if x_changed or y_changed then doc:move(editor.selection.list, nx - first.x, ny - first.y) end
    cy = row(kit, ix, cy, "POSITION")
    local held = editor.selection:count() == 1 and editor:goal_marks().held[first.id]
    if held then
        kit:label("NOT ON THE MAP UNTIL " .. held, ix, cy, iw, theme.row,
            { color = theme.warn, size = theme.font_small })
        cy = cy + theme.row
    end

    for _, kind in ipairs(KIND_ORDER) do
        local objects = by_kind[kind]
        if objects then
            cy = cy + 2
            cy = kit:header((KIND_TITLES[kind] or kind:upper()) .. (#objects > 1 and ("  X" .. #objects) or ""),
                x, cy, w, { color = theme.text })
            cy = cy + 4
            local section = SECTIONS[kind]
            if section then
                cy = section(editor, kit, ix, cy, iw, objects)
            elseif kind == "missing" then
                kit:label("THIS GAME DATA LACKS ITS SPRITE", ix, cy, iw, theme.row, { color = theme.danger })
                cy = cy + theme.row
            else
                local owner = #objects == 1 and objects[1].owner and doc.by_id[objects[1].owner]
                if owner then
                    kit:label("BELONGS TO " .. doc:info(owner).label, ix, cy, iw, theme.row, { color = theme.text_dim })
                    cy = cy + theme.row
                end
            end
        end
    end

    if #roads > 0 then
        cy = cy + 2
        cy = kit:header(#roads == 1 and "ROAD" or ("ROADS  X" .. #roads), x, cy, w, { color = theme.text }) + 4
        cy = roads_section(editor, kit, ix, cy, iw, roads)
    end

    cy = cy + 6
    kit:separator(x, cy, w)
    cy = cy + 6
    local bw = (iw - 8) / 3
    if kit:button("prop_dup", ix, cy, bw, theme.row + 2, { text = "COPY", icon = "duplicate", tip = "DUPLICATE (CTRL+D)" }) then
        editor:duplicate()
    end
    local grouped = first.group ~= nil
    if kit:button("prop_group", ix + bw + 4, cy, bw, theme.row + 2,
        { text = grouped and "SPLIT" or "JOIN", icon = grouped and "ungroup" or "group",
          tip = grouped and "UNGROUP (CTRL+SHIFT+G)" or "GROUP (CTRL+G)", disabled = not grouped and editor.selection:count() < 2 }) then
        if grouped then Ops.ungroup(doc, editor.selection.list) else Ops.group(doc, editor.selection.list) end
    end
    if kit:button("prop_delete", ix + (bw + 4) * 2, cy, bw, theme.row + 2,
        { text = "DELETE", icon = "trash", danger = true, tip = "DELETE (DEL)" }) then
        editor:delete_selection()
    end
    cy = cy + theme.row + 10
    editor.props_height = cy - top
    kit:scroll_end()
end

-- layers

function Panels.layers(editor, kit, x, y, w)
    local theme  = kit.theme
    local counts = Validate.summary(editor.doc).layers
    counts.routes = #editor.doc.map.routes
    counts.lines  = #editor.doc.map.lines
    counts.roads  = #editor.doc.map.roads
    local cy = kit:header("LAYERS", x, y, w)
    for _, layer in ipairs(Catalog.data().layers) do
        local state = editor.layers[layer.id]
        if kit:button("layer_eye_" .. layer.id, x + 4, cy, 24, theme.row,
            { icon = state.visible and "eye" or "eye_off", flat = true, tip = "SHOW OR HIDE" }) then
            state.visible = not state.visible
            editor.selection:clear()
        end
        if kit:button("layer_lock_" .. layer.id, x + 30, cy, 24, theme.row,
            { icon = state.locked and "lock" or "unlock", flat = true, on = state.locked,
              tip = "A LOCKED LAYER IS NOT PICKED BY THE SELECT TOOL" }) then
            state.locked = not state.locked
            editor.selection:clear()
        end
        kit:label(layer.label, x + 60, cy, w - 120, theme.row, { color = state.visible and theme.text or theme.text_dim })
        kit:label(tostring(counts[layer.id] or 0), x, cy, w, theme.row, { align = "right", pad = theme.pad + 4, color = theme.text_dim })
        cy = cy + theme.row
    end
    cy = cy + 6
    cy = kit:header("VIEW", x, cy, w)
    cy = cy + 2
    local ix, iw = x + theme.pad, w - theme.pad * 2
    editor.grid.show = kit:check("view_grid", ix, cy, iw, "GRID (G)", editor.grid.show)
    cy = cy + theme.row
    editor.grid.snap = kit:check("view_snap", ix, cy, iw, "SNAP TO GRID (CTRL+G TOGGLES)", editor.grid.snap)
    cy = cy + theme.row
    local steps = {}
    for _, step in ipairs(Catalog.data().grid_steps) do steps[#steps + 1] = { label = step .. " PX", value = step } end
    editor.grid.step = kit:choice("view_step", ix + LABEL_W, cy, iw - LABEL_W, steps, editor.grid.step)
    cy = row(kit, ix, cy, "GRID STEP")
    editor.badges = kit:check("view_badges", ix, cy, iw, "OBJECTIVE BADGES", editor.badges)
    cy = cy + theme.row
    editor.minimap = kit:check("view_minimap", ix, cy, iw, "OVERVIEW MAP (M)", editor.minimap)
    cy = cy + theme.row
    editor.parts = kit:check("view_parts", ix, cy, iw, "SELECT SINGLE PARTS (TAB)", editor.parts)
end

-- checks

function Panels.checks(editor, kit, x, y, w, h)
    local theme  = kit.theme
    local issues = editor:issues()
    local errors = Validate.errors(issues)
    local cy     = y
    if #issues == 0 then
        cy = kit:header("READY TO PLAY", x, cy, w, { color = theme.ok })
        kit:paragraph("NO PROBLEMS FOUND. PRESS F5 TO TRY THE MAP.", x + theme.pad, cy + 6, w - theme.pad * 2,
            { color = theme.text_dim })
        return
    end
    cy = kit:header(errors > 0 and (errors .. (errors == 1 and " ERROR" or " ERRORS") .. ": THE MAP CANNOT BE PLAYED YET")
        or "WARNINGS ONLY: THE MAP CAN BE PLAYED", x, cy, w, { color = errors > 0 and theme.danger or theme.warn })
    local offset = kit:scroll_begin("checks", x, cy, w, y + h - cy, editor.checks_height or h)
    local top    = cy - offset
    cy = top + 4
    for i, item in ipairs(issues) do
        local text_w = w - theme.pad * 2 - 24
        local text_h = kit:paragraph(item.text, 0, 0, text_w, { dry = true, size = theme.font_small })
        local row_h  = math.max(theme.row, text_h + 8)
        local id     = "issue_" .. i
        local clicked, hover = kit:click(id, x + 2, cy, w - 4, row_h)
        if hover then
            kit:rect(x + 2, cy, w - 4, row_h, theme.widget_hot, 3)
            if item.objects then kit:set_tip(id, "CLICK TO SELECT AND SHOW") end
        end
        kit:icon(item.level == "error" and "error" or "warning", x + theme.pad, cy + (row_h - 16) / 2, 16,
            item.level == "error" and theme.danger or theme.warn)
        kit:paragraph(item.text, x + theme.pad + 22, cy + 4, text_w, { size = theme.font_small })
        if clicked and item.objects then editor:show_objects(item.objects) end
        cy = cy + row_h + 2
    end
    editor.checks_height = cy - top
    kit:scroll_end()
end

return Panels
