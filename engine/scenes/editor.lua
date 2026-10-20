-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json        = require "lib.json"
local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local Log         = require "engine.core.log"
local Config      = require "engine.core.config"
local World       = require "engine.game.world"
local Mission     = require "engine.game.mission"
local MapFile     = require "engine.game.map_file"
local MapCompiler = require "engine.game.map_compiler"
local Sound       = require "engine.game.sound"
local Kit         = require "engine.ui.kit"
local MissionMenu = require "engine.ui.mission_menu"
local Catalog     = require "engine.editor.catalog"
local Document    = require "engine.editor.document"
local Selection   = require "engine.editor.selection"
local View        = require "engine.editor.view"
local Tools       = require "engine.editor.tools"
local Ops         = require "engine.editor.ops"
local Panels      = require "engine.editor.panels"
local Dialogs     = require "engine.editor.dialogs"
local Validate    = require "engine.editor.validate"
local Generate    = require "engine.editor.generate"
local Cards       = require "engine.editor.cards"
local Goals       = require "engine.editor.goals"
local Prefabs     = require "engine.editor.prefabs"
local Loadout     = require "engine.game.loadout"
local Campaign    = require "engine.game.campaign"
local PlayerTag   = require "engine.ui.player_tag"

-- The map editor: a free view of the map with a tool strip on the left, a
-- dock on the right (objects, properties, layers, checks), menus on top and a
-- status line below. It edits a Document (engine/editor/document.lua) and
-- never the loaded world; F5 compiles the map and plays it, Esc comes back.
--
-- enter(opts): { map = file name } opens a map, { new = true } asks for a new
-- one, nothing returns to the map already open (after a try).
local Editor = Class(Scene)

local TOP_H     = 30
local TOOLS_W   = 40
local OPTIONS_H = 28
local DOCK_W    = 340
local STATUS_H  = 22
local MINIMAP   = 168

local PAN_SPEED    = 700    -- window px per second with W A S D
local RIGHT_DRAG   = 4      -- window px a right press travels before it pans
local SAY_TIME     = 4
local BADGE_ZOOM   = 1      -- badges show from this zoom up
local MAP_REFRESH  = 0.4    -- seconds between overview map redraws while editing
local TEST_NAME    = "_playtest"
local BRIEFINGS    = "assets/mission_text.json"
local AUTO_PREFIX  = "_auto_"
local ARROW_SIZE   = 5      -- window px of the arrowhead on a route segment
local ARROW_MIN    = 28     -- window px a segment is long before it gets one

-- ARRANGE: the menu's entries, which the select tool also shows as buttons
-- while two objects or more are selected. ctrl / shift name the key; single
-- ones also work on one object.
local ARRANGE = {
    { label = "ALIGN LEFT", icon = "align_left", run = function(doc, list) Ops.align(doc, list, "left") end },
    { label = "ALIGN CENTRES IN A COLUMN", icon = "align_center",
      run = function(doc, list) Ops.align(doc, list, "center") end },
    { label = "ALIGN RIGHT", icon = "align_right", run = function(doc, list) Ops.align(doc, list, "right") end },
    { label = "ALIGN TOP", icon = "align_top", run = function(doc, list) Ops.align(doc, list, "top") end },
    { label = "ALIGN CENTRES IN A ROW", icon = "align_middle",
      run = function(doc, list) Ops.align(doc, list, "middle") end },
    { label = "ALIGN BOTTOM", icon = "align_bottom", run = function(doc, list) Ops.align(doc, list, "bottom") end },
    {},
    { label = "EVEN GAPS ACROSS", icon = "gaps_across",
      run = function(doc, list) return Ops.distribute(doc, list, "x") end },
    { label = "EVEN GAPS DOWN", icon = "gaps_down",
      run = function(doc, list) return Ops.distribute(doc, list, "y") end },
    {},
    { label = "TURN LEFT", icon = "turn_left", key = "CTRL+[", ctrl = "[", single = true,
      run = function(doc, list) Ops.turn(doc, list, -1) end },
    { label = "TURN RIGHT", icon = "turn_right", key = "CTRL+]", ctrl = "]", single = true,
      run = function(doc, list) Ops.turn(doc, list, 1) end },
    { label = "MIRROR LEFT TO RIGHT", icon = "mirror_across", key = "SHIFT+H", shift = "h",
      run = function(doc, list) Ops.mirror(doc, list, "x") end },
    { label = "MIRROR TOP TO BOTTOM", icon = "mirror_down", key = "SHIFT+V", shift = "v",
      run = function(doc, list) Ops.mirror(doc, list, "y") end },
}

function Editor:init(app)
    Scene.init(self, app)
    self.kit     = Kit:new()
    self.view    = View:new()
    self.selection     = Selection:new()
    self.doc     = nil
    self.tool    = "select"
    self.work    = nil      -- the tool's state while it is at something
    self.shape   = nil      -- the route or line last touched
    self.parts   = false    -- pick single parts instead of groups
    self.placing = nil      -- what the place tool puts down: a catalog entry, or { prefab, label, key }
    self.measure = nil      -- { x0, y0, x1, y1 }: the line the measure tool last dragged
    self.grid    = { show = false, snap = false, step = 16 }
    self.badges  = true
    self.minimap = true
    self.layers  = {}
    for _, layer in ipairs(Catalog.data().layers) do
        self.layers[layer.id] = { visible = true, locked = layer.locked == true }
    end
    local brush  = Catalog.data().scatter
    self.scatter = { radius = brush.radius, density = brush.density, gap = brush.gap, set = {}, list = {} }
    self.erase   = { radius = Catalog.data().erase.radius, all = false }
    -- The ground brush: art nil paints the map's own art set back.
    self.ground  = { radius = Catalog.data().terrain.radius, cell = Catalog.data().terrain.cell, art = nil,
                     clear = false }
    self.line_colors = Catalog.data().line_colors
    self.line_color  = self.line_colors[1]
    self.road        = { width = nil, marks = true }   -- the next road: nil is the art set's own width
    self.dock_tab    = "objects"
    self.category    = "buildings"
    self.catalog_art = "0"
    self.search      = ""
    self.dialog      = nil
    self.clip        = nil
    self.message     = nil      -- { text, left } shown on the status line
    self.hover_world = nil      -- pointer position in the world while over the view
    self.pan         = nil      -- a view drag in progress
    self.right       = nil      -- a right press that may become a pan
    self.checked     = { revision = -1, issues = {} }
    self.map_canvas  = nil
    self.map_stamp   = { revision = -1, at = 0 }
    self.auto_timer  = 0
    self.time        = 0
    self.try         = { god = false, vehicle = "chopper", players = 1 }   -- how TRY flies the map
    self.card_pick   = nil      -- { slot, size, label } while a briefing picture is being picked
    self.card_cache  = { revision = -1, cards = {} }
    self.place_pick  = nil      -- { radius, hint, on_pick, on_back } while a place is being picked
    self.goal_cache  = { revision = -1, marks = nil }
    self.briefing    = nil      -- the briefing screen, once previewed
    self.previewing  = nil      -- { settings } while the briefing preview is up
end

-- lifecycle

function Editor:enter(opts)
    opts = opts or {}
    Sound.play_music()
    love.keyboard.setKeyRepeat(true)
    self.kit.scale = self.ui_scale or Kit.scale_for(select(2, love.graphics.getDimensions()))
    self.kit:set_font(Config.editor_font)
    self.pan, self.right, self.work = nil, nil, nil
    self.previewing = nil
    Prefabs.refresh()
    if MapFile.exists(TEST_NAME) then MapFile.delete(TEST_NAME) end
    if opts.map then
        self:open_map(opts.map)
    elseif opts.new or not self.doc then
        self:_blank()
        self:_first_dialog()
        -- A new map that was never saved and not let go of properly: offer it back.
        if MapFile.exists(AUTO_PREFIX) then self:_offer_restore(nil) end
    end
end

-- NEW MAP as the editor opens on nothing: cancelling it leaves the editor.
function Editor:_first_dialog()
    self.dialog = Dialogs.new_state()
    self.dialog.on_cancel = function() self.app.scenes:switch("map_select") end
end

function Editor:leave()
    love.keyboard.setKeyRepeat(false)
    self.kit:blur()
    self.kit:close_popups()
end

-- An empty document behind the NEW MAP dialog, so there is always one to draw.
function Editor:_blank()
    local art   = "0"
    for _, item in ipairs(Catalog.arts()) do
        if item.present then art = tostring(item.art); break end
    end
    local stage = Catalog.stages(art)[1]
    self:_set_doc(Document:new(MapFile.new("NEW MAP", tonumber(art), stage), nil))
end

function Editor:_set_doc(doc)
    self.doc         = doc
    self.catalog_art = doc:art()
    self.placing     = nil
    self.shape       = nil
    self.work        = nil
    self.measure     = nil
    self.scatter.set, self.scatter.list = {}, {}
    self.selection:clear()
    self.checked.revision = -1
    self.map_stamp.revision = -1
    self.auto_revision = doc.revision
    self.view:restore(doc.map.view, doc:size())
    if not doc.map.view then
        local home = doc:home()
        self.view:look_at(home and home.x or doc:size() / 2, home and home.y or doc:size() / 2, doc:size())
    end
end

function Editor:say(text)
    self.message = { text = text, left = SAY_TIME }
end

function Editor:open_dialog(kind)
    self.kit:close_popups()
    self.kit:blur()
    if kind == "new" then
        self.dialog = Dialogs.new_state()
    elseif kind == "save_as" then
        self.dialog = { kind = kind, name = self.doc.map.name }
    else
        self.dialog = { kind = kind }
    end
end

function Editor:ask(title, text, buttons)
    self.kit:close_popups()
    self.kit:blur()
    self.dialog = { kind = "ask", title = title, text = text, buttons = buttons }
end

-- files

-- Run fn now, or after the open map's unsaved changes are saved or let go.
function Editor:guard(fn)
    if not (self.doc and self.doc.dirty) then
        fn()
        return
    end
    self:ask("UNSAVED CHANGES", "THE MAP " .. self.doc.map.name .. " HAS CHANGES THAT ARE NOT SAVED.", {
        { label = "SAVE", primary = true, action = function() self:save(fn) end },
        { label = "DISCARD", danger = true, action = function()
            self:_drop_autosave()
            fn()
        end },
        { label = "CANCEL" },
    })
end

function Editor:_auto_name(name)
    return AUTO_PREFIX .. (name or "")
end

function Editor:_drop_autosave()
    local name = self:_auto_name(self.doc and self.doc.name)
    if MapFile.exists(name) then MapFile.delete(name) end
end

function Editor:_offer_restore(name)
    local auto = self:_auto_name(name)
    self:ask("RESTORE UNSAVED CHANGES?", "THE EDITOR WAS LEFT WITH UNSAVED CHANGES TO THIS MAP. "
        .. "THEY WERE KEPT ASIDE.", {
        { label = "RESTORE", primary = true, action = function()
            local map = MapFile.read(auto)
            if map then
                self:_set_doc(Document:new(map, name))
                self.doc.dirty = true
            end
        end },
        { label = "DISCARD", danger = true, action = function()
            MapFile.delete(auto)
            if not name then self:_first_dialog() end
        end },
    })
end

function Editor:open_map(name)
    local map, err = MapFile.read(name)
    if not map then
        self:say("CANNOT OPEN " .. name:upper() .. ": " .. tostring(err):upper())
        if not self.doc then self:_blank() end
        return
    end
    self:_set_doc(Document:new(map, name))
    Log.info("editor", "opened %s (%d objects)", name, #map.objects)
    if MapFile.exists(self:_auto_name(name)) then self:_offer_restore(name) end
end

-- Create the map the NEW MAP dialog describes.
function Editor:new_map(spec)
    local map
    if spec.start == "copy" then
        map = MapCompiler.decompile(spec.stage, Mission.def(spec.stage))
        if not map then
            self:say("THIS GAME DATA HAS NO " .. tostring(spec.stage):upper())
            return
        end
        map.name = spec.name
        -- The stage's briefing comes along: each paragraph in its slot, and
        -- beside it the card the stage shows there.
        local text = love.filesystem.getInfo(BRIEFINGS) and love.filesystem.read(BRIEFINGS)
        local info = text and json.decode(text)[spec.stage]
        local last = 0
        for i, paragraph in ipairs(info and info.paragraphs or {}) do
            local slot = math.min(Cards.SLOTS, (paragraph.slot or i - 1) + 1)
            map.briefing[slot] = paragraph.text
            last = math.max(last, slot)
        end
        for i = 1, last do map.briefing[i] = map.briefing[i] or "" end
        map.briefing_cards = Cards.of_stage(spec.stage)
    else
        map = MapFile.new(spec.name, tonumber(spec.art), spec.stage or Catalog.stages(spec.art)[1])
        map.size = spec.size
    end
    local doc = Document:new(map, nil)
    if spec.start == "copy" then
        Ops.auto_group(doc)
    else
        local home = Catalog.entries(spec.art).by_key["home"]
        if home then Ops.place(doc, home, map.size / 2, map.size / 2) end
        if spec.ground and spec.stage then
            Generate.ground(doc, spec.stage, { density = 1, trees = true, scenery = true })
        end
    end
    doc.undo, doc.redo = {}, {}
    doc.dirty = true
    self:_drop_autosave()
    self:_set_doc(doc)
    Log.info("editor", "new map %s (%s)", map.name, spec.start)
end

function Editor:save(after)
    local doc = self.doc
    if not doc.name then
        self.dialog = { kind = "save_as", name = doc.map.name, after = after }
        return
    end
    doc.map.view = self.view:state()
    self:_drop_autosave()
    if doc:save() then
        self:say("SAVED")
        if after then after() end
    else
        self:say("COULD NOT SAVE THE MAP")
    end
end

function Editor:save_as(display_name, after)
    local doc = self.doc
    self:_drop_autosave()
    doc.map.name = display_name
    doc.map.view = self.view:state()
    if doc:save(MapFile.file_name(display_name)) then
        self:say("SAVED AS " .. doc.name:upper())
        if after then after() end
    else
        self:say("COULD NOT SAVE THE MAP")
    end
end

function Editor:exit()
    self:guard(function()
        self.doc = nil
        self.app.scenes:switch("map_select")
    end)
end

-- The place a key or a menu entry is about: under the pointer while it is
-- over the map, else the middle of the view.
function Editor:_here()
    local size = self.doc:size()
    local x, y = self.view.x, self.view.y
    if self.hover_world then x, y = self.hover_world[1], self.hover_world[2] end
    return math.floor(x) % size, math.floor(y) % size
end

-- How many players a try is flown by: what the map asks for, else the TRY choice.
function Editor:try_players()
    return self.doc.map.players or self.try.players
end

-- Play the map as it stands. Esc in the phase comes back here. here: the
-- vehicles start at Editor:_here (or the nearest free spot) instead of where
-- the map starts them. Two players fly it on the split screen.
function Editor:play_test(here)
    local app = self.app
    if Validate.errors(self:issues()) > 0 then
        self.dock_tab = "checks"
        self:say("THE MAP CANNOT BE PLAYED YET: SEE THE CHECKS")
        return
    end
    if not MapFile.write(self.doc.map, TEST_NAME) then
        self:say("COULD NOT WRITE THE MAP")
        return
    end
    app.world:load(World.map_stage(TEST_NAME))
    app.after_stage_load()
    local settings = app.settings
    local map      = self.doc.map
    local weapons  = app.combat.weapons
    app.campaign           = false
    app.coop_run           = nil
    settings.death_enabled = true   -- as a map plays from the list: vehicles can be lost
    -- The loadout the map fixes, as the player will get it. Otherwise every
    -- weapon the map allows, in the vehicle it asks for or the one picked for
    -- the try, with what it closes on the equip screen as it set that.
    local function equipped()
        if map.loadout then return Loadout.fixed(map.loadout, weapons) end
        local vehicle = map.vehicle or self.try.vehicle
        return vehicle, Loadout.everything(vehicle, map.equip, weapons)
    end
    app.play_return = { scene = "editor", test = true, god = self.try.god }
    if here then
        local x, y = self:_here()
        app.play_return.start = { x = x, y = y }
    end
    if self:try_players() == Campaign.PLAYERS then
        Campaign.start_team(app, app.world.stage.mission)
        for i = 1, Campaign.PLAYERS do
            settings.coop.vehicle[i], settings.coop.loadout[i] = equipped()
        end
        app.scenes:switch("coop_gameplay")
        return
    end
    settings.vehicle, settings.loadout = equipped()
    app.scenes:switch("gameplay")
end

-- briefing pictures

function Editor:set_card(slot, card)
    local cards = {}
    for i = 1, Cards.SLOTS do cards[i] = self.doc.map.briefing_cards[i] or { kind = "none" } end
    cards[slot] = card or { kind = "none" }
    self.doc:set_map("briefing_cards", cards, "BRIEFING PICTURE")
end

-- The map's briefing cards as images, redrawn when the map changed: { [slot] = { image, w } }.
function Editor:card_images()
    if self.card_cache.revision ~= self.doc.revision then
        self.card_cache = { revision = self.doc.revision, cards = Cards.for_map(self.doc) }
    end
    return self.card_cache.cards
end

-- Pick the square of the map a briefing card shows: the settings close, the
-- next click on the map sets it, and the settings come back.
function Editor:start_card_pick(slot)
    local card = self.doc.map.briefing_cards[slot] or {}
    self.card_pick = { slot = slot, size = card.kind == "view" and card.size or Cards.SIZES[1],
                       label = card.kind == "view" and card.label or nil }
    Dialogs.close(self)
    self:set_tool("card")
end

function Editor:finish_card_pick()
    self.card_pick = nil
    self.work      = nil
    self.tool      = "select"
    self:open_dialog("settings")
    self.dialog.tab = "briefing"
end

-- objectives

-- What the map's objectives point at (Goals.marks), recomputed when the map changed.
function Editor:goal_marks()
    if self.goal_cache.revision ~= self.doc.revision then
        self.goal_cache = { revision = self.doc.revision, marks = Goals.marks(self.doc) }
    end
    return self.goal_cache.marks
end

-- Hand the view over to picking a place inside a dialog: on_pick(x, y) gets
-- the place clicked (snapped, on the map), then on_back() opens the dialog
-- again, also when the pick is called off.
function Editor:pick_place(radius, hint, on_pick, on_back)
    self.place_pick = { radius = radius, hint = hint, on_pick = on_pick, on_back = on_back }
    Dialogs.close(self)
    self:set_tool("spot")
end

function Editor:finish_place_pick(wx, wy)
    local pick = self.place_pick
    self.place_pick = nil
    self.work       = nil
    self.tool       = "select"
    if not pick then return end
    if wx then
        local size = self.doc:size()
        local x, y = self:snap(wx, wy)
        pick.on_pick(x % size, y % size)
    end
    pick.on_back()
end

-- Pick the place of objective `index` on the map: the settings close, the
-- next click sets it, and the settings come back.
function Editor:start_place_pick(index)
    local doc  = self.doc
    local goal = doc.map.objectives[index]
    if not goal then return end
    self:pick_place(goal.radius or Goals.limits().radius.default,
        "CLICK THE PLACE THE PLAYER HAS TO GET TO.  RIGHT CLICK: BACK TO THE SETTINGS.",
        function(x, y)
            if not doc.map.objectives[index] then return end
            local rows = {}
            for i, item in ipairs(doc.map.objectives) do rows[i] = item end
            doc:begin("OBJECTIVE PLACE")
            Goals.set(doc, rows, index, "x", x)
            Goals.set(doc, rows, index, "y", y)
            doc:commit()
        end,
        function()
            self:open_dialog("settings")
            self.dialog.tab = "objectives"
        end)
end

-- briefing preview

-- Show the briefing as the player will see it; any key or click comes back,
-- to the map settings when it was asked for from there.
function Editor:preview_briefing()
    local map = self.doc.map
    self.briefing   = self.briefing or MissionMenu:new()
    self.previewing = { settings = self.dialog ~= nil and self.dialog.kind == "settings" }
    self.kit:close_popups()
    self.kit:blur()
    self.dialog = nil
    self.briefing:open("", { mission = tonumber(self.doc:art()) or 0, name = map.name, author = map.author,
                             paragraphs = map.briefing, cards = self:card_images(),
                             disabled = { save = true, load = true, shop = map.loadout ~= nil
                                          or (map.equip ~= nil and map.equip.no_shop == true) } })
end

function Editor:close_preview()
    local from = self.previewing
    self.previewing = nil
    self.briefing:close()
    if from and from.settings then
        self:open_dialog("settings")
        self.dialog.tab = "briefing"
    end
end

-- state the panels and tools ask for

function Editor:hidden(_o, info)
    return not self.layers[info.layer].visible
end

function Editor:pickable(_o, info)
    local layer = self.layers[info.layer]
    return layer.visible and not layer.locked
end

function Editor:roads_pickable()
    return self.layers.roads.visible and not self.layers.roads.locked
end

-- The road under a world position, for the select tool.
function Editor:road_at(wx, wy)
    if not self:roads_pickable() then return nil end
    local size = self.doc:size()
    return self.doc:road_at(wx % size, wy % size)
end

function Editor:snap(wx, wy)
    if self.grid.snap then
        local step = self.grid.step
        return math.floor(wx / step + 0.5) * step, math.floor(wy / step + 0.5) * step
    end
    return math.floor(wx + 0.5), math.floor(wy + 0.5)
end

function Editor:snap_delta(dx, dy)
    return self:snap(dx, dy)
end

function Editor:issues()
    if self.checked.revision ~= self.doc.revision then
        self.checked = { revision = self.doc.revision, issues = Validate.run(self.doc) }
    end
    return self.checked.issues
end

function Editor:set_tool(id)
    if self.work then Tools.defs[self.tool].cancel(self) end
    self.work = nil
    self.tool = id
    self.selection:prune(self.doc)
    if id == "place" or id == "scatter" then self.dock_tab = "objects" end
    if id == "select" then self.dock_tab = "properties" end
end

-- A catalog entry was clicked: the scatter brush ticks it, anything else places it.
function Editor:pick_entry(entry)
    if self.tool == "scatter" then
        local brush = self.scatter
        if brush.set[entry.key] then brush.set[entry.key] = nil else brush.set[entry.key] = entry end
        brush.list = {}
        for _, e in pairs(brush.set) do brush.list[#brush.list + 1] = e end
        table.sort(brush.list, function(a, b) return a.key < b.key end)
        return
    end
    self.placing = entry
    if self.tool ~= "place" then self:set_tool("place") end
end

-- A prefab was clicked: the place tool stamps it.
function Editor:pick_prefab(prefab)
    self.placing = { prefab = prefab.clip, label = prefab.label, key = "prefab/" .. prefab.name }
    if self.tool ~= "place" then self:set_tool("place") end
end

-- Keep the selection as a prefab under a name.
function Editor:save_prefab(label)
    local clip = Ops.copy(self.doc, self.selection.list, self.selection.roads)
    if not clip then return end
    if Prefabs.save(label, Ops.centre(clip)) then
        self.dock_tab, self.category, self.search = "objects", "prefabs", ""
        self:say("PREFAB SAVED: " .. label)
    else
        self:say("COULD NOT SAVE THE PREFAB")
    end
end

function Editor:delete_prefab(prefab)
    self:ask("DELETE THE PREFAB?", "THE PREFAB " .. prefab.label .. " IS DELETED FOR EVERY MAP. WHAT WAS PLACED "
        .. "FROM IT STAYS.", {
        { label = "DELETE", danger = true, action = function()
            if self.placing and self.placing.key == "prefab/" .. prefab.name then self.placing = nil end
            Prefabs.delete(prefab.name)
        end },
        { label = "CANCEL" },
    })
end

function Editor:delete_selection()
    if not self.selection:any() then return end
    local doc = self.doc
    doc:begin("DELETE")
    doc:remove(self.selection.list)
    for _, road in ipairs(self.selection.roads) do
        doc:remove_road(road)
        if self.shape == road then self.shape = nil end
    end
    doc:commit()
    self.selection:prune(doc)
end

function Editor:duplicate()
    if not self.selection:any() then return end
    self.selection:replace(Ops.duplicate(self.doc, self.selection.list, self.selection.roads))
end

function Editor:copy(cut)
    if not self.selection:any() then return end
    self.clip = Ops.copy(self.doc, self.selection.list, self.selection.roads)
    if cut then self:delete_selection() end
end

function Editor:paste()
    if not self.clip then return end
    local x, y = self.view.x, self.view.y
    if self.hover_world then x, y = self.hover_world[1], self.hover_world[2] end
    x, y = self:snap(x, y)
    self.selection:replace(Ops.paste(self.doc, self.clip, x, y))
    self:set_tool("select")
end

function Editor:select_all()
    local found = {}
    for _, o in ipairs(self.doc.map.objects) do
        if self:pickable(o, self.doc:info(o)) then found[#found + 1] = o end
    end
    self.selection:replace(found, self:roads_pickable() and self.doc.map.roads or {})
end

function Editor:undo()
    local label = self.doc:undo_step()
    self.selection:prune(self.doc)
    self.shape = nil
    self:say(label and ("UNDONE: " .. label) or "NOTHING TO UNDO")
end

function Editor:redo()
    local label = self.doc:redo_step()
    self.selection:prune(self.doc)
    self.shape = nil
    self:say(label and ("REDONE: " .. label) or "NOTHING TO REDO")
end

-- Select objects and bring them into view.
function Editor:show_objects(objects)
    for _, o in ipairs(objects) do
        local layer = self.layers[self.doc:info(o).layer]
        layer.visible, layer.locked = true, false
    end
    self.selection:replace(objects)
    self:frame_selection()
    self:set_tool("select")
end

function Editor:frame_selection()
    local first = self.selection.list[1]
    local road  = self.selection.roads[1]
    if first then
        self.view:look_at(first.x, first.y, self.doc:size())
    elseif road and road.points[1] then
        self.view:look_at(road.points[1][1], road.points[1][2], self.doc:size())
    end
end

function Editor:go_home()
    local home = self.doc:home()
    if home then
        self.view:look_at(home.x, home.y, self.doc:size())
    else
        self:say("THE MAP HAS NO HOME PAD")
    end
end

function Editor:nudge(dx, dy)
    if not self.selection:any() then return end
    local step = love.keyboard.isDown("lshift", "rshift") and 8 or 1
    if self.grid.snap then step = self.grid.step end
    local doc = self.doc
    doc:begin("MOVE")
    if self.selection:count() > 0 then doc:move(self.selection.list, dx * step, dy * step) end
    doc:move_roads(self.selection.roads, dx * step, dy * step)
    doc:commit()
end

-- Run an entry of ARRANGE on the selection.
function Editor:arrange(item)
    if self.selection:count() < (item.single and 1 or 2) then return end
    if item.run(self.doc, self.selection.list) == false then self:say("EVEN GAPS NEED THREE OBJECTS OR MORE") end
end

-- layout

-- Sizes in UI units: the window, and the view's rect between the panels.
function Editor:_layout()
    local sw, sh = self.kit:size()
    local s      = self.kit.scale
    local vx, vy = TOOLS_W, TOP_H + OPTIONS_H
    local vw, vh = sw - TOOLS_W - DOCK_W, sh - vy - STATUS_H
    self.view.rect = { x = math.floor(vx * s), y = math.floor(vy * s),
                       w = math.max(1, math.floor(vw * s)), h = math.max(1, math.floor(vh * s)) }
    return sw, sh, vx, vy, vw, vh
end

-- The overview map's rect in window pixels.
function Editor:_minimap_rect()
    local r = self.view.rect
    local m = MINIMAP * self.kit.scale
    return r.x + 10, r.y + r.h - m - 10, m, m
end

function Editor:_minimap_at(x, y)
    if not self.minimap then return nil end
    local mx, my, mw, mh = self:_minimap_rect()
    if x < mx or x >= mx + mw or y < my or y >= my + mh then return nil end
    local size = self.doc:size()
    return (x - mx) / mw * size, (y - my) / mh * size
end

-- input

local function ctrl_down()
    return love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
end

function Editor:update(dt)
    self.time = self.time + dt
    self.kit:update(dt)
    if self.previewing then
        self.briefing:update(dt)
        return
    end
    if self.message then
        self.message.left = self.message.left - dt
        if self.message.left <= 0 then self.message = nil end
    end
    local doc = self.doc
    local mx, my = love.mouse.getPosition()
    if self.view:contains(mx, my) and not self.kit:over(mx, my) and not self:_minimap_at(mx, my) then
        local wx, wy = self.view:to_world(mx, my)
        self.hover_world = { wx, wy }
    else
        self.hover_world = nil
    end
    if not self.kit:wants_keys() and not self.dialog and not ctrl_down() then
        local kb   = love.keyboard.isDown
        local step = PAN_SPEED * dt
        local dx   = (kb("a") and 1 or 0) - (kb("d") and 1 or 0)
        local dy   = (kb("w") and 1 or 0) - (kb("s") and 1 or 0)
        if dx ~= 0 or dy ~= 0 then self.view:pan(dx * step, dy * step, doc:size()) end
    end
    -- Unsaved changes are kept aside now and then, to offer back after a crash.
    self.auto_timer = self.auto_timer + dt
    if self.auto_timer >= Catalog.data().autosave_seconds then
        self.auto_timer = 0
        if doc.dirty and doc.revision ~= self.auto_revision and not self.work then
            doc.map.view = self.view:state()
            MapFile.write(doc.map, self:_auto_name(doc.name))
            self.auto_revision = doc.revision
        end
    end
end

function Editor:textinput(text)
    self.kit:textinput(text)
end

function Editor:captures_keys()
    return self.kit:wants_keys()
end

function Editor:keypressed(key)
    if self.previewing then
        self:close_preview()
        return
    end
    if self.kit:keypressed(key) then return end
    if self.dialog then
        if key == "escape" then
            local dialog = self.dialog
            Dialogs.close(self)
            if dialog.on_cancel then dialog.on_cancel() end
        end
        return
    end
    local tool = Tools.defs[self.tool]
    if ctrl_down() then
        local shift = love.keyboard.isDown("lshift", "rshift")
        if key == "z" then if shift then self:redo() else self:undo() end
        elseif key == "y" then self:redo()
        elseif key == "s" then if shift then self:open_dialog("save_as") else self:save() end
        elseif key == "o" then self:guard(function() self:open_dialog("open") end)
        elseif key == "n" then self:guard(function() self:open_dialog("new") end)
        elseif key == "c" then self:copy(false)
        elseif key == "x" then self:copy(true)
        elseif key == "v" then self:paste()
        elseif key == "d" then self:duplicate()
        elseif key == "a" then self:select_all()
        elseif key == "g" then
            if shift then Ops.ungroup(self.doc, self.selection.list) else self.grid.snap = not self.grid.snap end
        end
        for _, item in ipairs(ARRANGE) do
            if item.ctrl == key then self:arrange(item) end
        end
        return
    end
    if love.keyboard.isDown("lshift", "rshift") then
        for _, item in ipairs(ARRANGE) do
            if item.shift == key then
                self:arrange(item)
                return
            end
        end
    end
    if tool.keypressed and tool.keypressed(self, key) then return end
    if key == "escape" then
        if self.work or self.tool ~= "select" or self.selection:any() then
            tool.cancel(self)
        else
            self:exit()
        end
        return
    end
    for _, id in ipairs(Tools.ORDER) do
        if Tools.defs[id].key == key then
            self:set_tool(id)
            return
        end
    end
    if key == "delete" or key == "backspace" then self:delete_selection()
    elseif key == "left" then self:nudge(-1, 0)
    elseif key == "right" then self:nudge(1, 0)
    elseif key == "up" then self:nudge(0, -1)
    elseif key == "down" then self:nudge(0, 1)
    elseif key == "g" then self.grid.show = not self.grid.show
    elseif key == "m" then self.minimap = not self.minimap
    elseif key == "tab" then
        self.parts = not self.parts
        self:say(self.parts and "SELECTING SINGLE PARTS" or "SELECTING WHOLE GROUPS")
    elseif key == "home" then self:go_home()
    elseif key == "f" then self:frame_selection()
    elseif key == "f5" then self:play_test(love.keyboard.isDown("lshift", "rshift"))
    elseif key == "f6" then self:preview_briefing()
    elseif key == "f1" then self:open_dialog("help")
    elseif key == "=" or key == "+" or key == "kp+" then self.view:zoom_by(1, nil, nil, self.doc:size())
    elseif key == "-" or key == "kp-" then self.view:zoom_by(-1, nil, nil, self.doc:size())
    elseif key == "0" or key == "kp0" then
        if love.keyboard.isDown("lshift", "rshift") then self.view:fit(self.doc:size()) else self.view:reset_zoom() end
    end
end

function Editor:mousepressed(x, y, button)
    button = button or 1
    if self.previewing then
        self:close_preview()
        return
    end
    self.kit:mousepressed(x, y, button)
    if self.kit:over(x, y) or not self.view:contains(x, y) then return end
    local mwx, mwy = self:_minimap_at(x, y)
    if mwx then
        if button == 1 then
            self.pan = { minimap = true }
            self.view:look_at(mwx, mwy, self.doc:size())
        end
        return
    end
    local wx, wy = self.view:to_world(x, y)
    if button == 1 then
        if love.keyboard.isDown("space") then
            self.pan = {}
        else
            Tools.defs[self.tool].press(self, wx, wy)
            self.pressing = true
        end
    elseif button == 2 then
        self.right = { x = x, y = y }
    elseif button == 3 then
        self.pan = {}
    end
end

function Editor:mousemoved(x, y, dx, dy)
    if self.previewing then return end
    if self.pan then
        if self.pan.minimap then
            local mwx, mwy = self:_minimap_at(x, y)
            if mwx then self.view:look_at(mwx, mwy, self.doc:size()) end
        else
            self.view:pan(dx or 0, dy or 0, self.doc:size())
        end
        return
    end
    if self.right then
        if not self.right.panning and math.max(math.abs(x - self.right.x), math.abs(y - self.right.y)) > RIGHT_DRAG then
            self.right.panning = true
        end
        if self.right.panning then self.view:pan(dx or 0, dy or 0, self.doc:size()) end
        return
    end
    if self.pressing then
        local wx, wy = self.view:to_world(x, y)
        Tools.defs[self.tool].drag(self, wx, wy)
    end
end

function Editor:mousereleased(x, y, button)
    button = button or 1
    self.kit:mousereleased(x, y, button)
    if button == 1 then
        if self.pressing then
            self.pressing = false
            local wx, wy = self.view:to_world(x, y)
            Tools.defs[self.tool].release(self, wx, wy)
        end
        if self.pan and not love.mouse.isDown(3) then self.pan = nil end
    elseif button == 2 then
        local right = self.right
        self.right = nil
        if right and not right.panning and not self.kit:over(x, y) then Tools.defs[self.tool].cancel(self) end
    elseif button == 3 then
        self.pan = nil
    end
end

function Editor:wheelmoved(_dx, dy)
    if self.previewing then return end
    local x, y = love.mouse.getPosition()
    if self.kit:over(x, y) or not self.view:contains(x, y) then
        self.kit:wheelmoved(dy)
        return
    end
    if dy ~= 0 then self.view:zoom_by(dy > 0 and 1 or -1, x, y, self.doc:size()) end
end

-- drawing: the world

-- The routes in hand: the one last touched and those of the selected units,
-- as { [route] = true }.
function Editor:_hot_routes()
    local hot = {}
    if self.shape and self.doc:route(self.shape.id) == self.shape then hot[self.shape] = true end
    for _, o in ipairs(self.selection.list) do
        local route = o.route and self.doc:route(o.route)
        if route then hot[route] = true end
    end
    return hot
end

-- An arrowhead at the middle of the segment a -> b, pointing the way it is
-- driven. Left out on a segment too short on screen to carry one.
local function draw_heading(a, b, z)
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local length = math.sqrt(dx * dx + dy * dy)
    if length * z < ARROW_MIN then return end
    local ux, uy = dx / length * ARROW_SIZE / z, dy / length * ARROW_SIZE / z
    local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
    love.graphics.polygon("fill", mx + ux, my + uy, mx - ux - uy, my - uy + ux, mx - ux + uy, my - uy - ux)
end

function Editor:_draw_routes()
    if not self.layers.routes.visible then return end
    local g   = love.graphics
    local doc = self.doc
    local z   = self.view:zoom()
    local c   = self.kit.theme.accent
    local in_hand = self:_hot_routes()
    g.setLineWidth(1.5 / z)
    for _, route in ipairs(doc.map.routes) do
        local points = route.points
        local hot    = in_hand[route]
        if hot then g.setColor(c[1], c[2], c[3], 0.95) else g.setColor(1, 1, 1, 0.5) end
        for i = 1, #points - 1 do
            g.line(points[i][1], points[i][2], points[i + 1][1], points[i + 1][2])
            draw_heading(points[i], points[i + 1], z)
        end
        -- Back to the start: a route is driven round and round, the short way.
        if #points > 2 then
            local last   = points[#points]
            local dx, dy = doc:delta(points[1][1], points[1][2], last[1], last[2])
            local back   = { last[1] + dx, last[2] + dy }
            if hot then g.setColor(c[1], c[2], c[3], 0.4) else g.setColor(1, 1, 1, 0.22) end
            g.line(last[1], last[2], back[1], back[2])
            draw_heading(last, back, z)
        end
        if points[1] then
            if hot then g.setColor(c[1], c[2], c[3], 1) else g.setColor(1, 1, 1, 0.8) end
            g.circle("line", points[1][1], points[1][2], 5 / z, 16)
        end
    end
    g.setLineWidth(1 / z)
    for _, o in ipairs(self.view.drawn.objects) do
        local route = o.route and doc:route(o.route)
        if route and route.points[1] then
            local dx, dy = doc:delta(route.points[1][1], route.points[1][2], o.x, o.y)
            g.setColor(1, 1, 1, 0.3)
            g.line(o.x, o.y, o.x + dx, o.y + dy)
        end
    end
end

function Editor:_draw_marks()
    local g   = love.graphics
    local doc = self.doc
    local z   = self.view:zoom()
    local c   = self.kit.theme.accent
    g.setLineWidth(1 / z)
    -- Owner links of what is in view: a pad, a flag or a person to its building.
    if self.layers.objectives.visible then
        for _, list in ipairs({ self.view.drawn.objects, self.view.drawn.decals }) do
            for _, o in ipairs(list) do
                local owner = o.owner and doc.by_id[o.owner]
                if owner and (owner.x ~= o.x or owner.y ~= o.y) then
                    local dx, dy = doc:delta(owner.x, owner.y, o.x, o.y)
                    g.setColor(c[1], c[2], c[3], 0.55)
                    g.line(o.x, o.y, o.x + dx, o.y + dy)
                end
            end
        end
    end
    -- Where an objective asks the player to get to, where shelling lands and
    -- where a player sets off an event.
    if self.layers.objectives.visible then
        for _, place in ipairs(self:goal_marks().places) do
            local dx, dy = doc:delta(place.x, place.y, self.view.x, self.view.y)
            local pc     = place.shell and self.kit.theme.danger or c
            g.setColor(pc[1], pc[2], pc[3], 0.1)
            g.circle("fill", self.view.x + dx, self.view.y + dy, place.radius, 48)
            g.setColor(pc[1], pc[2], pc[3], 0.9)
            g.circle("line", self.view.x + dx, self.view.y + dy, place.radius, 48)
        end
    end
    local x0, y0, x1, y1 = self.view:bounds()
    for _, o in ipairs(self.selection.list) do
        local info = doc:info(o)
        local dx, dy = doc:delta(o.x, o.y, self.view.x, self.view.y)
        local x, y = self.view.x + dx, self.view.y + dy
        if x + info.ox + info.w >= x0 and x + info.ox <= x1 and y + info.oy + info.h >= y0 and y + info.oy <= y1 then
            g.setColor(0, 0, 0, 0.7)
            g.rectangle("line", x + info.ox - 2 / z, y + info.oy - 2 / z, info.w + 4 / z, info.h + 4 / z)
            g.setColor(c[1], c[2], c[3], 1)
            g.rectangle("line", x + info.ox - 1 / z, y + info.oy - 1 / z, info.w + 2 / z, info.h + 2 / z)
        end
    end
    -- The ground of the selected roads.
    if #self.selection.roads > 0 then
        for _, leg in ipairs(doc:built_roads().legs) do
            if self.selection:has_road(leg.road) then
                local dx, dy = doc:delta(leg.left, leg.top, self.view.x, self.view.y)
                local x, y   = self.view.x + dx, self.view.y + dy
                local w, h   = leg.right - leg.left, leg.bottom - leg.top
                g.setColor(c[1], c[2], c[3], 0.16)
                g.rectangle("fill", x, y, w, h)
                g.setColor(c[1], c[2], c[3], 1)
                g.rectangle("line", x - 1 / z, y - 1 / z, w + 2 / z, h + 2 / z)
            end
        end
    end
    -- What an armed unit sees and where it fires, for a single selection.
    if #self.selection.list > 0 and #self.selection.list <= 4 then
        for _, o in ipairs(self.selection.list) do
            local dx, dy = doc:delta(o.x, o.y, self.view.x, self.view.y)
            Tools.draw_ranges(doc:info(o).kind_name, self.view.x + dx, self.view.y + dy)
        end
    end
end

function Editor:_draw_world()
    local g    = love.graphics
    local doc  = self.doc
    local size = doc:size()
    self.view:draw(doc, {
        hidden     = function(o, info) return self:hidden(o, info) end,
        show_lines = self.layers.lines.visible,
        show_roads = self.layers.roads.visible,
        grid       = self.grid.show and self.grid.step or nil,
    })
    local tool = Tools.defs[self.tool]
    self.view:world_pass(function()
        g.setLineStyle("rough")
        for _, tile in ipairs(self.view:tiles(size)) do
            g.push()
            g.translate(tile.ox, tile.oy)
            self:_draw_routes()
            if tool.poly then tool.draw(self) end
            g.pop()
        end
        self:_draw_marks()
        if tool.draw and not tool.poly then
            g.setLineWidth(1 / self.view:zoom())
            tool.draw(self)
        end
    end)
    g.setColor(1, 1, 1, 1)
end

-- Small marks over what matters to the objectives: targets, people, the home
-- pad, what an objective of the map's own names and what one of its events
-- holds back; and whose start a start is.
function Editor:_draw_badges()
    if not self.badges or self.view:zoom() < BADGE_ZOOM then return end
    local kit   = self.kit
    local theme = kit.theme
    local doc   = self.doc
    local s     = kit.scale
    local r     = self.view.rect
    local home  = doc:home()
    local marks = self:goal_marks()
    love.graphics.setScissor(r.x, r.y, r.w, r.h)
    for _, o in ipairs(self.view.drawn.objects) do
        local info = doc:info(o)
        local cls  = info.cls
        local mark = marks.by_id[o.id]
        local icon, color
        if info.start then
            local dx, dy = doc:delta(o.x, o.y, self.view.x, self.view.y)
            local sx, sy = self.view:to_screen(self.view.x + dx, self.view.y + dy)
            kit:rect(sx / s - 9, sy / s - 9, 18, 18, { 0, 0, 0, 0.72 }, 9)
            kit:label(tostring(info.start), sx / s - 9, sy / s - 9, 18, 18,
                { align = "center", color = PlayerTag.color(info.start), size = theme.font_small })
        elseif cls.kind_name == "structure" and cls.behaviour == 2 and cls.is_target then icon, color = "flag", theme.danger
        elseif cls.is_target then icon, color = "target", theme.danger
        elseif mark and mark.type == "protect" then icon, color = "lock", theme.ok
        elseif mark then icon, color = "crosshair", theme.warn
        elseif (cls.pows or 0) > 0 then icon, color = "people", theme.ok
        elseif cls.kind_name == "structure" and Catalog.has_flag(cls.flags, 0x40) then icon, color = "base", theme.text
        elseif marks.held[o.id] then icon, color = "eye", theme.text_dim end
        if icon then
            local dx, dy = doc:delta(o.x, o.y, self.view.x, self.view.y)
            local sx, sy = self.view:to_screen(self.view.x + dx, self.view.y + dy)
            local x, y   = sx / s - 9, sy / s - 9
            kit:rect(x, y, 18, 18, { 0, 0, 0, 0.72 }, 9)
            kit:icon(icon, x + 1, y + 1, 16, color)
        end
    end
    if home then
        local dx, dy = doc:delta(home.x, home.y, self.view.x, self.view.y)
        local sx, sy = self.view:to_screen(self.view.x + dx, self.view.y + dy)
        kit:rect(sx / s - 9, sy / s - 9, 18, 18, { 0, 0, 0, 0.72 }, 9)
        kit:icon("home", sx / s - 8, sy / s - 8, 16, theme.accent)
    end
    for _, place in ipairs(marks.places) do
        local dx, dy = doc:delta(place.x, place.y, self.view.x, self.view.y)
        local sx, sy = self.view:to_screen(self.view.x + dx, self.view.y + dy)
        kit:rect(sx / s - 9, sy / s - 9, 18, 18, { 0, 0, 0, 0.72 }, 9)
        local icon = (place.shell and "bomb") or (place.trigger and "flag") or "pin"
        kit:icon(icon, sx / s - 8, sy / s - 8, 16, place.shell and theme.danger or theme.accent)
    end
    love.graphics.setScissor()
end

-- The place of each point in its route, beside the point: on the routes in
-- hand, and on every route while the route tool is out.
function Editor:_draw_route_numbers()
    if not self.layers.routes.visible then return end
    local kit   = self.kit
    local theme = kit.theme
    local doc   = self.doc
    local s     = kit.scale
    local r     = self.view.rect
    local lists = {}
    if self.tool == "route" then
        if self.view:zoom() >= BADGE_ZOOM then
            for _, route in ipairs(doc.map.routes) do lists[#lists + 1] = route.points end
        end
        if self.work and self.work.points then lists[#lists + 1] = self.work.points end
    else
        for route in pairs(self:_hot_routes()) do lists[#lists + 1] = route.points end
    end
    love.graphics.setScissor(r.x, r.y, r.w, r.h)
    for _, points in ipairs(lists) do
        for i, point in ipairs(points) do
            local dx, dy = doc:delta(point[1], point[2], self.view.x, self.view.y)
            local sx, sy = self.view:to_screen(self.view.x + dx, self.view.y + dy)
            if self.view:contains(sx, sy) then
                local text = tostring(i)
                local w    = kit:text_width(text, theme.font_small) + 6
                kit:rect(sx / s + 6, sy / s - 17, w, 13, { 0, 0, 0, 0.72 }, 3)
                kit:label(text, sx / s + 6, sy / s - 17, w, 13,
                    { align = "center", size = theme.font_small, color = theme.accent })
            end
        end
    end
    love.graphics.setScissor()
end

-- What the measured line comes to: its length, and the seconds each vehicle
-- the map may be played in takes over it at full speed.
function Editor:_measured()
    local span   = self.measure
    local dx, dy = span.x1 - span.x0, span.y1 - span.y0
    local length = math.sqrt(dx * dx + dy * dy)
    local parts  = { string.format("%d PX", math.floor(length + 0.5)) }
    for _, vehicle in ipairs(Catalog.travel(self.doc.map)) do
        parts[#parts + 1] = string.format("%s %.1f S", vehicle.label, length / vehicle.speed)
    end
    return parts
end

-- The measure beside the end of its line.
function Editor:_draw_measure()
    local span = self.measure
    if not span or self.tool ~= "measure" then return end
    local kit   = self.kit
    local theme = kit.theme
    local s     = kit.scale
    local r     = self.view.rect
    local dx, dy = self.doc:delta(span.x0, span.y0, self.view.x, self.view.y)
    local sx, sy = self.view:to_screen(self.view.x + dx + span.x1 - span.x0, self.view.y + dy + span.y1 - span.y0)
    local text   = table.concat(self:_measured(), "   ")
    local w      = kit:text_width(text, theme.font_small) + 12
    love.graphics.setScissor(r.x, r.y, r.w, r.h)
    kit:rect(sx / s + 10, sy / s - 22, w, 16, { 0, 0, 0, 0.78 }, 3)
    kit:label(text, sx / s + 10, sy / s - 22, w, 16, { align = "center", size = theme.font_small, color = theme.accent })
    love.graphics.setScissor()
end

function Editor:_refresh_map_canvas(px)
    local g   = love.graphics
    local doc = self.doc
    if not self.map_canvas or self.map_canvas:getWidth() ~= px then
        self.map_canvas = g.newCanvas(px, px)
        self.map_stamp.revision = -1
    end
    local stamp = self.map_stamp
    if stamp.revision == doc.revision or (self.time - stamp.at < MAP_REFRESH and stamp.revision ~= -1) then return end
    stamp.revision, stamp.at = doc.revision, self.time
    local k      = px / doc:size()
    local ground = World.art_ground(doc:art())
    g.push("all")
    g.setCanvas(self.map_canvas)
    g.origin()
    g.setScissor()
    g.clear(ground[1], ground[2], ground[3], 1)
    g.push()
    g.scale(k)
    self.view:draw_terrain(doc)
    g.pop()
    -- A line or road over the seam goes on from the other edge.
    for oy = -px, px, px do
        for ox = -px, px, px do
            for _, line in ipairs(doc.map.lines) do
                g.setColor(line.color[1] / 255, line.color[2] / 255, line.color[3] / 255, 0.8)
                for i = 1, #line.points - 1 do
                    g.line(ox + line.points[i][1] * k, oy + line.points[i][2] * k,
                        ox + line.points[i + 1][1] * k, oy + line.points[i + 1][2] * k)
                end
            end
            if self.layers.roads.visible then
                for _, s in ipairs(doc:built_roads().segments) do
                    g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255, 0.8)
                    g.line(ox + s.x1 * k, oy + s.y1 * k, ox + s.x2 * k, oy + s.y2 * k)
                end
            end
        end
    end
    local spots = {}
    for _, o in ipairs(doc.map.objects) do
        local layer = doc:info(o).layer
        if self.layers[layer].visible then
            spots[layer] = spots[layer] or {}
            table.insert(spots[layer], { o.x * k, o.y * k })
        end
    end
    for _, layer in ipairs({ "scenery", "ground", "buildings", "base", "guns", "units", "objectives", "pickups" }) do
        local list = spots[layer]
        if list then
            local c = Catalog.data().layer_colors[layer]
            g.setColor(c[1], c[2], c[3], layer == "scenery" and 0.16 or 1)
            g.setPointSize(layer == "scenery" and 1 or 2)
            g.points(list)
        end
    end
    g.pop()
end

function Editor:_draw_minimap()
    if not self.minimap then return end
    local g = love.graphics
    local x, y, w, h = self:_minimap_rect()
    self:_refresh_map_canvas(math.floor(w))
    local size = self.doc:size()
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", x - 2, y - 2, w + 4, h + 4)
    g.setColor(1, 1, 1, 1)
    g.draw(self.map_canvas, x, y)
    local x0, y0, x1, y1 = self.view:bounds()
    local k = w / size
    g.setScissor(x, y, w, h)
    local c = self.kit.theme.accent
    g.setColor(c[1], c[2], c[3], 1)
    g.setLineWidth(1)
    for oy = -1, 1 do
        for ox = -1, 1 do
            g.rectangle("line", x + (x0 + ox * size) * k, y + (y0 + oy * size) * k, (x1 - x0) * k, (y1 - y0) * k)
        end
    end
    g.setScissor()
    g.setColor(c[1], c[2], c[3], 0.6)
    g.rectangle("line", x - 0.5, y - 0.5, w + 1, h + 1)
    g.setColor(1, 1, 1, 1)
end

-- drawing: the interface

function Editor:_menus(kit, x)
    local doc = self.doc
    local chosen = self.selection:any()
    local function menu(id, label, items)
        local w = kit:text_width(label) + 18
        kit:menu(id, x, 3, w, TOP_H - 6, { text = label }, items)
        x = x + w + 2
    end
    menu("menu_file", "FILE", {
        { label = "NEW MAP", key = "CTRL+N", icon = "new", action = function() self:guard(function() self:open_dialog("new") end) end },
        { label = "OPEN", key = "CTRL+O", icon = "open", action = function() self:guard(function() self:open_dialog("open") end) end },
        {},
        { label = "SAVE", key = "CTRL+S", icon = "save", action = function() self:save() end },
        { label = "SAVE AS", key = "CTRL+SHIFT+S", action = function() self:open_dialog("save_as") end },
        {},
        { label = "OPEN THE MAPS FOLDER", icon = "folder", action = function()
            love.filesystem.createDirectory(MapFile.DIR)
            pcall(love.system.openURL, "file://" .. love.filesystem.getSaveDirectory() .. "/" .. MapFile.DIR)
        end },
        {},
        { label = "BACK TO THE MAP LIST", icon = "exit", action = function() self:exit() end },
    })
    menu("menu_edit", "EDIT", {
        { label = "UNDO", key = "CTRL+Z", icon = "undo", disabled = not doc:can_undo(), action = function() self:undo() end },
        { label = "REDO", key = "CTRL+Y", icon = "redo", disabled = not doc:can_redo(), action = function() self:redo() end },
        {},
        { label = "CUT", key = "CTRL+X", icon = "cut", disabled = not chosen, action = function() self:copy(true) end },
        { label = "COPY", key = "CTRL+C", icon = "copy", disabled = not chosen, action = function() self:copy(false) end },
        { label = "PASTE", key = "CTRL+V", icon = "paste", disabled = not self.clip, action = function() self:paste() end },
        { label = "DUPLICATE", key = "CTRL+D", icon = "duplicate", disabled = not chosen, action = function() self:duplicate() end },
        { label = "DELETE", key = "DEL", icon = "trash", disabled = not chosen, action = function() self:delete_selection() end },
        {},
        { label = "SELECT ALL", key = "CTRL+A", icon = "selection", action = function() self:select_all() end },
        { label = "GROUP", icon = "group", disabled = self.selection:count() < 2, action = function() Ops.group(doc, self.selection.list) end },
        { label = "UNGROUP", key = "CTRL+SHIFT+G", icon = "ungroup", disabled = self.selection:count() == 0,
          action = function() Ops.ungroup(doc, self.selection.list) end },
        {},
        { label = "SAVE THE SELECTION AS A PREFAB", icon = "prefab", disabled = not chosen,
          action = function() self:open_dialog("prefab") end },
    })
    local arrange = {}
    for i, item in ipairs(ARRANGE) do
        arrange[i] = item.label and { label = item.label, icon = item.icon, key = item.key,
            disabled = self.selection:count() < (item.single and 1 or 2), action = function() self:arrange(item) end }
            or {}
    end
    menu("menu_arrange", "ARRANGE", arrange)
    local function scale_item(scale)
        return { label = string.format("INTERFACE SIZE %g X", scale), on = kit.scale == scale, action = function()
            self.ui_scale = scale
            kit.scale     = scale
        end }
    end
    local function font_item(name, label)
        return { label = label, on = Config.editor_font == name, action = function()
            Config.editor_font = name
            Config.save()
            kit:set_font(name)
        end }
    end
    menu("menu_view", "VIEW", {
        { label = "GRID", key = "G", on = self.grid.show, action = function() self.grid.show = not self.grid.show end },
        { label = "SNAP TO GRID", key = "CTRL+G", on = self.grid.snap, action = function() self.grid.snap = not self.grid.snap end },
        { label = "OBJECTIVE BADGES", on = self.badges, action = function() self.badges = not self.badges end },
        { label = "OVERVIEW MAP", key = "M", on = self.minimap, action = function() self.minimap = not self.minimap end },
        {},
        { label = "ZOOM IN", key = "+", icon = "zoom_in", action = function() self.view:zoom_by(1, nil, nil, doc:size()) end },
        { label = "ZOOM OUT", key = "-", icon = "zoom_out", action = function() self.view:zoom_by(-1, nil, nil, doc:size()) end },
        { label = "RESET ZOOM", key = "0", action = function() self.view:reset_zoom() end },
        { label = "SHOW THE WHOLE MAP", key = "SHIFT+0", icon = "map", action = function() self.view:fit(doc:size()) end },
        { label = "GO TO THE HOME PAD", key = "HOME", icon = "home", action = function() self:go_home() end },
        { label = "SHOW THE SELECTION", key = "F", icon = "fit", disabled = not chosen, action = function() self:frame_selection() end },
        {},
        scale_item(Kit.SCALES[1]), scale_item(Kit.SCALES[2]), scale_item(Kit.SCALES[3]), scale_item(Kit.SCALES[4]),
        {},
        font_item("game", "TEXT IN THE GAME FONT"), font_item("plain", "TEXT IN A PLAIN FONT"),
    })
    menu("menu_map", "MAP", {
        { label = "MAP SETTINGS", icon = "settings", action = function() self:open_dialog("settings") end },
        { label = "GENERATE GROUND", icon = "generate", action = function() self:open_dialog("generate") end },
        {},
        { label = "TRY THE MAP", key = "F5", icon = "play", action = function() self:play_test() end },
        { label = "TRY FROM WHERE THE VIEW IS", key = "SHIFT+F5", icon = "pin",
          action = function() self:play_test(true) end },
        { label = "TRY IN GOD MODE", on = self.try.god, action = function() self.try.god = not self.try.god end },
        { label = "TRY WITH TWO PLAYERS", on = self:try_players() == 2, disabled = doc.map.players ~= nil,
          action = function() self.try.players = 3 - self.try.players end },
        { label = "PREVIEW THE BRIEFING", key = "F6", icon = "eye", action = function() self:preview_briefing() end },
    })
    if self.app.dev then
        local app = self.app
        local function go(scene, ...)
            local args = { ... }
            return function() self:guard(function() app.scenes:switch(scene, unpack(args)) end) end
        end
        menu("menu_dev", "DEV", {
            { label = "SANDBOX", icon = "dev", action = function()
                self:guard(function()
                    app.settings.loadout = nil
                    app.scenes:switch("sandbox")
                end)
            end },
            { label = "CO-OP FREE PLAY", action = go("vehicle_select", { players = 2, free = true, return_to = "editor" }) },
            { label = "REPLAY PANEL", action = go("replays") },
            {},
            { label = "ANIMATION GALLERY", action = go("anim_gallery") },
            { label = "FONT GALLERY", action = go("font_gallery") },
            { label = "SOUND GALLERY", action = go("sound_gallery") },
            {},
            { label = "ENDING", action = go("ending", { record = app.run_record, preview = true,
                on_done = function() app.scenes:switch("editor") end }) },
            { label = "ALTERNATE ENDING", action = go("ending", { alternate = true, record = app.run_record,
                preview = true, on_done = function() app.scenes:switch("editor") end }) },
            { label = "CRASH PICTURE", action = function()
                require("engine.ui.crash_fx").preview(app.screen, app.settings.vehicle, true)
            end },
        })
    end
    menu("menu_help", "HELP", {
        { label = "KEYS", key = "F1", icon = "help", action = function() self:open_dialog("help") end },
    })
    return x
end

function Editor:_top_bar(kit, sw)
    local theme = kit.theme
    local doc   = self.doc
    kit:panel(0, 0, sw, TOP_H, { border = false })
    kit:separator(0, TOP_H - 1, sw)
    local x = self:_menus(kit, 6)

    local issues = self:issues()
    local errors = Validate.errors(issues)
    local right  = sw - 8
    right = right - 22
    local vehicles = {}
    if not (doc.map.loadout or doc.map.vehicle) then
        vehicles = {
            {},
            { label = "FLY THE CHOPPER", on = self.try.vehicle == "chopper", action = function() self.try.vehicle = "chopper" end },
            { label = "DRIVE THE TANK", on = self.try.vehicle == "tank", action = function() self.try.vehicle = "tank" end },
        }
    end
    kit:menu("try_menu", right, 4, 22, TOP_H - 8, { icon = "chevron_down", tip = "HOW THE MAP IS TRIED" }, {
        { label = "TRY FROM WHERE THE VIEW IS", key = "SHIFT+F5", icon = "pin",
          action = function() self:play_test(true) end },
        {},
        { label = "GOD MODE: NOTHING RUNS OUT, NOTHING HURTS", on = self.try.god,
          action = function() self.try.god = not self.try.god end },
        { label = "TWO PLAYERS ON THE SPLIT SCREEN", on = self:try_players() == 2, disabled = doc.map.players ~= nil,
          action = function() self.try.players = 3 - self.try.players end },
        vehicles[1], vehicles[2], vehicles[3],
    })
    right = right - 2 - 84
    local try_text = (self:try_players() == 2 and "TRY 2P" or "TRY") .. (self.try.god and " (GOD)" or "")
    right = right - (self:try_players() == 2 and 24 or 0)
    if kit:button("try", right, 4, 84 + (self:try_players() == 2 and 24 or 0), TOP_H - 8, { text = try_text, icon = "play",
        primary = true, tip = "PLAY THE MAP AS IT STANDS (F5)" }) then
        self:play_test()
    end
    right = right - 8 - 124
    local badge = errors > 0 and (errors .. (errors == 1 and " ERROR" or " ERRORS"))
        or (#issues > 0 and (#issues .. (#issues == 1 and " WARNING" or " WARNINGS")) or "READY")
    if kit:button("checks", right, 4, 124, TOP_H - 8, { text = badge, flat = true, danger = errors > 0,
        icon = errors > 0 and "error" or (#issues > 0 and "warning" or "ok"), tip = "WHAT THE MAP STILL NEEDS" }) then
        self.dock_tab = "checks"
    end

    -- Name and environment of the map, between the menus and the buttons.
    local env   = doc.map.environment
    local title = doc.map.name .. (doc.dirty and " *" or "")
    local tw    = math.min(kit:text_width(title, theme.font_title), right - x - 120)
    local tx    = x + math.max(12, (right - x - tw - 90) / 2)
    kit:label(title, tx, 0, tw + 4, TOP_H, { size = theme.font_title, color = doc.dirty and theme.accent or theme.text })
    local ix = tx + tw + 12
    kit:label(Catalog.art_label(doc:art()), ix, 0, 120, TOP_H, { size = theme.font_small, color = theme.text_dim })
    ix = ix + kit:text_width(Catalog.art_label(doc:art()), theme.font_small) + 8
    if env.night == true then kit:icon("night", ix, (TOP_H - 16) / 2, 16, theme.text_dim); ix = ix + 20 end
    if env.weather and env.weather ~= "none" then kit:icon(env.weather, ix, (TOP_H - 16) / 2, 16, theme.text_dim) end
end

function Editor:_tool_strip(kit, sh)
    local theme = kit.theme
    kit:panel(0, TOP_H, TOOLS_W, sh - TOP_H - STATUS_H, { border = false })
    kit:rect(TOOLS_W - 1, TOP_H, 1, sh - TOP_H - STATUS_H, theme.border)
    local y = TOP_H + 6
    for _, id in ipairs(Tools.ORDER) do
        local tool = Tools.defs[id]
        if kit:button("tool_" .. id, 4, y, 32, 32, { icon = tool.icon, icon_size = 20, on = self.tool == id,
            tip = tool.tip, flat = true }) then
            self:set_tool(id)
        end
        y = y + 36
    end
    kit:separator(6, y + 2, TOOLS_W - 12)
    y = y + 10
    if kit:button("strip_undo", 4, y, 32, 28, { icon = "undo", flat = true, disabled = not self.doc:can_undo(),
        tip = "UNDO (CTRL+Z)" }) then self:undo() end
    y = y + 30
    if kit:button("strip_redo", 4, y, 32, 28, { icon = "redo", flat = true, disabled = not self.doc:can_redo(),
        tip = "REDO (CTRL+Y)" }) then self:redo() end
    y = y + 38
    if kit:button("strip_grid", 4, y, 32, 28, { icon = "grid", flat = true, on = self.grid.show, tip = "GRID (G)" }) then
        self.grid.show = not self.grid.show
    end
    y = y + 30
    if kit:button("strip_snap", 4, y, 32, 28, { icon = "snap", flat = true, on = self.grid.snap,
        tip = "SNAP TO GRID (CTRL+G)" }) then
        self.grid.snap = not self.grid.snap
    end
    y = y + 30
    if kit:button("strip_home", 4, y, 32, 28, { icon = "home", flat = true, tip = "GO TO THE HOME PAD (HOME)" }) then
        self:go_home()
    end
end

local HINTS = {
    select  = "CLICK OR DRAG A BOX TO SELECT.  DRAG THE SELECTION TO MOVE IT (CTRL: ALONG ONE AXIS).",
    place   = "CLICK TO PLACE, DRAG FOR A ROW.  RIGHT CLICK: BACK TO SELECT.",
    stamp   = "CLICK TO PLACE THE PREFAB.  RIGHT CLICK: BACK TO SELECT.",
    scatter = "TICK OBJECTS ON THE RIGHT, THEN PAINT.",
    erase   = "PAINT OVER WHAT SHOULD GO.",
    ground  = "PAINT THE GROUND OF THE ART SET PICKED.  THE MAP'S OWN ART SET PAINTS IT BACK.",
    route   = "CLICK POINTS, ENTER TO FINISH.  CTRL: 45 DEGREE STEPS.  CLICK AN END TO CARRY ON, DRAG A POINT, CLICK A LINE TO ADD ONE, DEL REMOVES.",
    line    = "CLICK POINTS, ENTER TO FINISH.  CTRL: 45 DEGREE STEPS.  CLICK AN END TO CARRY ON, DRAG A POINT, CLICK A LINE TO ADD ONE, DEL REMOVES.",
    road    = "CLICK POINTS, ENTER TO FINISH.  A POINT ON ANOTHER ROAD JOINS IT.  CLICK AN END TO CARRY ON, DRAG A POINT, SHIFT + CLICK ADDS ONE, DEL REMOVES.",
    measure = "DRAG FROM ONE PLACE TO ANOTHER.  CTRL: 45 DEGREE STEPS.  RIGHT CLICK CLEARS.",
    card    = "CLICK WHAT THE BRIEFING PICTURE SHOULD SHOW.  RIGHT CLICK: BACK TO THE SETTINGS.",
    spot    = "CLICK THE PLACE.  RIGHT CLICK: BACK TO THE SETTINGS.",
}

function Editor:_options_bar(kit, vx, vw)
    local theme = kit.theme
    local y     = TOP_H
    kit:panel(vx, y, vw, OPTIONS_H, { border = false })
    kit:separator(vx, y + OPTIONS_H - 1, vw)
    local x   = vx + 8
    local ry  = y + 3
    local tool = Tools.defs[self.tool]
    kit:label(tool.label, x, y, 70, OPTIONS_H, { color = theme.accent, size = theme.font_small })
    x = x + 72
    local function number(id, label, value, opts)
        local lw = kit:text_width(label, theme.font_small) + 6
        kit:label(label, x, y, lw, OPTIONS_H, { color = theme.text_dim, size = theme.font_small })
        local new = kit:number(id, x + lw, ry, 96, value, opts)
        x = x + lw + 106
        return new
    end
    if self.tool == "select" then
        self.parts = kit:check("opt_parts", x, ry, 150, "SINGLE PARTS", self.parts,
            { tip = "PICK ONE PART OF A GROUP INSTEAD OF THE WHOLE (TAB)" })
        x = x + 160
        if self.selection:any() and kit:button("opt_prefab", x, ry, 22, 22, { icon = "prefab", flat = true,
            tip = "SAVE THE SELECTION AS A PREFAB" }) then
            self:open_dialog("prefab")
        end
        x = x + (self.selection:any() and 30 or 0)
        if self.selection:count() > 1 then
            for i, item in ipairs(ARRANGE) do
                if item.label then
                    if kit:button("opt_arrange_" .. i, x, ry, 22, 22, { icon = item.icon, flat = true,
                        tip = item.key and (item.label .. " (" .. item.key .. ")") or item.label }) then
                        self:arrange(item)
                    end
                    x = x + 23
                else
                    x = x + 7
                end
            end
            x = x + 8
        end
    elseif self.tool == "place" then
        kit:label(self.placing and self.placing.label or "NOTHING PICKED", x, y, 220, OPTIONS_H,
            { color = self.placing and theme.text or theme.warn })
        x = x + 226
    elseif self.tool == "scatter" then
        local brush = self.scatter
        brush.radius  = number("opt_radius", "RADIUS", brush.radius, { min = 8, max = 512, step = 8, big = 32 })
        brush.density = number("opt_density", "PER DAB", brush.density, { min = 1, max = 40 })
        brush.gap     = number("opt_gap", "GAP", brush.gap, { min = 0, max = 128, step = 2, big = 8 })
        kit:label(#brush.list .. (#brush.list == 1 and " KIND" or " KINDS"), x, y, 70, OPTIONS_H,
            { color = #brush.list > 0 and theme.text or theme.warn, size = theme.font_small })
        x = x + 74
    elseif self.tool == "erase" then
        self.erase.radius = number("opt_erase", "RADIUS", self.erase.radius, { min = 4, max = 512, step = 4, big = 32 })
        self.erase.all = kit:check("opt_erase_all", x, ry, 290, "EVERYTHING, NOT ONLY SCENERY", self.erase.all)
        x = x + 300
    elseif self.tool == "ground" then
        local brush, doc = self.ground, self.doc
        local arts = {}
        for _, item in ipairs(Catalog.arts()) do
            if item.present then
                local own = tostring(item.art) == doc:art()
                arts[#arts + 1] = { label = item.label .. (own and " (THE MAP'S OWN)" or ""), value = tostring(item.art) }
            end
        end
        brush.art = kit:choice("opt_ground_art", x, ry, 140, arts, brush.art or doc:art(),
            { list_w = 240, tip = "THE ART SET WHOSE GROUND THE BRUSH PAINTS" })
        x = x + 148
        brush.radius = number("opt_ground_radius", "RADIUS", brush.radius, { min = 8, max = 512, step = 8, big = 32 })
        local cells = {}
        for i, side in ipairs(MapFile.TERRAIN_CELLS) do cells[i] = { label = side .. " PX", value = side } end
        local cell = doc.map.terrain and doc.map.terrain.cell or brush.cell
        local new_cell, cell_changed = kit:choice("opt_ground_cell", x, ry, 80, cells, cell,
            { tip = "THE SIDE OF A SQUARE OF GROUND; AN EDGE RUNS RAGGED THROUGH ONE" })
        if cell_changed then
            brush.cell = new_cell
            doc:set_terrain_cell(new_cell)
        end
        x = x + 88
        local clear_w = kit:text_width("CLEAR SCENERY") + 30
        brush.clear = kit:check("opt_ground_scenery", x, ry, clear_w, "CLEAR SCENERY", brush.clear,
            { tip = "TREES, STONES AND GROUND MARKS ON THE CELLS YOU PAINT GO WITH THE OLD GROUND" })
        x = x + clear_w + 8
        if kit:button("opt_ground_clear", x, ry, 22, 22, { icon = "trash", flat = true, disabled = not doc.map.terrain,
            tip = "THE WHOLE MAP BACK TO ITS OWN GROUND" }) then
            doc:set_map("terrain", nil, "CLEAR GROUND")
        end
        x = x + 30
    elseif self.tool == "card" and self.card_pick then
        local sizes = {}
        for i, size in ipairs(Cards.SIZES) do sizes[i] = { label = size .. " PX", value = size } end
        kit:label("SHOWS", x, y, 52, OPTIONS_H, { color = theme.text_dim, size = theme.font_small })
        self.card_pick.size = kit:choice("opt_card_size", x + 54, ry, 90, sizes, self.card_pick.size)
        x = x + 154
    elseif self.tool == "road" then
        -- The road in hand when there is one, else the next road drawn.
        local style  = Catalog.road_style(self.doc:art())
        local limits = Catalog.data().roads
        local road   = self.shape and self.shape.width and self.shape or nil
        local width  = road and road.width or self.road.width or style.width
        local new_width = number("opt_road_width", "WIDTH", width,
            { min = limits.min_width, max = limits.max_width, step = 2, big = 8 })
        if new_width ~= width then
            self.road.width = new_width
            if road then self.doc:set_road(road, "width", new_width, "ROAD WIDTH") end
        end
        local marks = self.road.marks
        if road then marks = (road.pitch or 0) > 0 end
        local new_marks, marks_changed = kit:check("opt_road_marks", x, ry, 130, "CENTRE LINE", marks)
        if marks_changed then
            self.road.marks = new_marks
            if road then self.doc:set_road(road, "pitch", new_marks and style.pitch or 0, "ROAD CENTRE LINE") end
        end
        x = x + 140
    elseif self.tool == "measure" and self.measure then
        local span = self.measure
        local text = string.format("%s     ACROSS %d  DOWN %d", table.concat(self:_measured(), "   "),
            math.abs(span.x1 - span.x0), math.abs(span.y1 - span.y0))
        local tw   = kit:text_width(text) + 14
        kit:label(text, x, y, tw, OPTIONS_H)
        x = x + tw
    elseif self.tool == "line" then
        for i, color in ipairs(self.line_colors) do
            local id = "opt_color_" .. i
            local clicked, hover = kit:click(id, x, ry + 1, 20, 20)
            kit:rect(x, ry + 1, 20, 20, { color[1] / 255, color[2] / 255, color[3] / 255, 1 }, 3)
            if self.line_color == color then kit:frame(x - 1, ry, 22, 22, theme.accent, 4)
            elseif hover then kit:frame(x - 1, ry, 22, 22, theme.text, 4) end
            if clicked then
                self.line_color = color
                if self.shape and self.shape.color then
                    self.doc:set_points(self.shape, self.shape.points, { color[1], color[2], color[3] }, "LINE COLOUR")
                end
            end
            x = x + 24
        end
        x = x + 8
    end
    local hint = HINTS[self.tool]
    if self.tool == "place" and self.placing and self.placing.prefab then hint = HINTS.stamp end
    if self.tool == "spot" and self.place_pick then hint = self.place_pick.hint end
    kit:label(hint, x, y, vx + vw - x - 8, OPTIONS_H, { color = theme.text_dim, size = theme.font_small })
end

local DOCK_TABS = {
    { label = "OBJECTS", value = "objects" }, { label = "PROPERTIES", value = "properties" },
    { label = "LAYERS", value = "layers" }, { label = "CHECKS", value = "checks" },
}

function Editor:_dock(kit, sw, sh)
    local theme = kit.theme
    local x     = sw - DOCK_W
    local y     = TOP_H
    local h     = sh - TOP_H - STATUS_H
    kit:panel(x, y, DOCK_W, h, { border = false })
    kit:rect(x, y, 1, h, theme.border)
    self.dock_tab = kit:tabs("dock_tabs", x + 1, y, DOCK_W - 1, DOCK_TABS, self.dock_tab)
    local py = y + theme.row + 4
    local ph = h - theme.row - 4
    if self.dock_tab == "objects" then Panels.objects(self, kit, x + 1, py, DOCK_W - 1, ph)
    elseif self.dock_tab == "properties" then Panels.properties(self, kit, x + 1, py, DOCK_W - 1, ph)
    elseif self.dock_tab == "layers" then Panels.layers(self, kit, x + 1, py, DOCK_W - 1, ph)
    else Panels.checks(self, kit, x + 1, py, DOCK_W - 1, ph) end
end

function Editor:_status_bar(kit, sw, sh)
    local theme = kit.theme
    local y     = sh - STATUS_H
    kit:panel(0, y, sw, STATUS_H, { border = false })
    kit:separator(0, y, sw)
    local text = self.message and self.message.text or ""
    kit:label(text, 8, y, sw * 0.5, STATUS_H, { color = theme.accent, size = theme.font_small })
    local parts = {}
    if self.hover_world then
        local size = self.doc:size()
        parts[#parts + 1] = string.format("X %d  Y %d", self.hover_world[1] % size, self.hover_world[2] % size)
    end
    parts[#parts + 1] = string.format("ZOOM %g X", self.view:zoom())
    if self.selection:any() then parts[#parts + 1] = self.selection:total() .. " SELECTED" end
    parts[#parts + 1] = #self.doc.map.objects .. " OBJECTS"
    kit:label(table.concat(parts, "     "), sw * 0.5, y, sw * 0.5 - 8, STATUS_H,
        { align = "right", color = theme.text_dim, size = theme.font_small })
end

-- The briefing as the game shows it, under a line saying how to get back.
function Editor:_draw_preview(kit)
    local theme = kit.theme
    self.briefing:draw()
    kit:begin()
    local text = "BRIEFING PREVIEW.  CLICK OR PRESS A KEY TO GO BACK."
    local w    = kit:text_width(text, theme.font_small) + 20
    kit:rect(8, 8, w, theme.row + 2, theme.panel, 4)
    kit:label(text, 8, 8, w, theme.row + 2, { align = "center", color = theme.accent, size = theme.font_small })
    kit:finish()
    love.graphics.setColor(1, 1, 1, 1)
end

function Editor:draw()
    local kit = self.kit
    if self.previewing then
        self:_draw_preview(kit)
        return
    end
    local sw, sh, vx, _, vw = self:_layout()
    love.graphics.clear(0, 0, 0, 1)
    self:_draw_world()
    self:_draw_minimap()
    kit:begin()
    self:_draw_badges()
    self:_draw_route_numbers()
    self:_draw_measure()
    self:_top_bar(kit, sw)
    self:_tool_strip(kit, sh)
    self:_options_bar(kit, vx, vw)
    self:_dock(kit, sw, sh)
    self:_status_bar(kit, sw, sh)
    Dialogs.draw(self, kit)
    kit:finish()
    love.graphics.setColor(1, 1, 1, 1)
end

return Editor
