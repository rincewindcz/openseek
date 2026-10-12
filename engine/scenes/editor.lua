-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local json        = require "lib.json"
local Class       = require "engine.core.class"
local Scene       = require "engine.core.scene"
local Log         = require "engine.core.log"
local World       = require "engine.game.world"
local Entity      = require "engine.game.entity"
local Mission     = require "engine.game.mission"
local MapFile     = require "engine.game.map_file"
local MapCompiler = require "engine.game.map_compiler"
local Sound       = require "engine.game.sound"
local Kit         = require "engine.ui.kit"
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
    self.placing = nil      -- catalog entry the place tool puts down
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
    self.line_colors = Catalog.data().line_colors
    self.line_color  = self.line_colors[1]
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
end

-- lifecycle

function Editor:enter(opts)
    opts = opts or {}
    Sound.play_music()
    love.keyboard.setKeyRepeat(true)
    self.kit.scale = self.ui_scale or Kit.scale_for(select(2, love.graphics.getDimensions()))
    self.pan, self.right, self.work = nil, nil, nil
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
        local text = love.filesystem.getInfo(BRIEFINGS) and love.filesystem.read(BRIEFINGS)
        local info = text and json.decode(text)[spec.stage]
        for i, paragraph in ipairs(info and info.paragraphs or {}) do map.briefing[i] = paragraph.text end
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

-- Play the map as it stands. Esc in the phase comes back here.
function Editor:play_test()
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
    app.campaign               = false
    app.settings.loadout       = nil
    app.settings.death_enabled = true   -- as a map plays from the list: vehicles can be lost
    if self.doc.map.vehicle then app.settings.vehicle = self.doc.map.vehicle end
    app.play_return = { scene = "editor", test = true }
    app.scenes:switch("gameplay")
end

-- state the panels and tools ask for

function Editor:hidden(_o, info)
    return not self.layers[info.layer].visible
end

function Editor:pickable(_o, info)
    local layer = self.layers[info.layer]
    return layer.visible and not layer.locked
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

function Editor:delete_selection()
    if self.selection:count() == 0 then return end
    self.doc:remove(self.selection.list)
    self.selection:prune(self.doc)
end

function Editor:duplicate()
    if self.selection:count() == 0 then return end
    self.selection:replace(Ops.duplicate(self.doc, self.selection.list))
end

function Editor:copy(cut)
    if self.selection:count() == 0 then return end
    self.clip = Ops.copy(self.doc, self.selection.list)
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
    self.selection:replace(found)
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
    if first then self.view:look_at(first.x, first.y, self.doc:size()) end
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
    if self.selection:count() == 0 then return end
    local step = love.keyboard.isDown("lshift", "rshift") and 8 or 1
    if self.grid.snap then step = self.grid.step end
    self.doc:move(self.selection.list, dx * step, dy * step)
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
        return
    end
    if tool.keypressed and tool.keypressed(self, key) then return end
    if key == "escape" then
        if self.work or self.tool ~= "select" or self.selection:count() > 0 then
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
    elseif key == "f5" then self:play_test()
    elseif key == "f1" then self:open_dialog("help")
    elseif key == "=" or key == "+" or key == "kp+" then self.view:zoom_by(1, nil, nil, self.doc:size())
    elseif key == "-" or key == "kp-" then self.view:zoom_by(-1, nil, nil, self.doc:size())
    end
end

function Editor:mousepressed(x, y, button)
    button = button or 1
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
    local x, y = love.mouse.getPosition()
    if self.kit:over(x, y) or not self.view:contains(x, y) then
        self.kit:wheelmoved(dy)
        return
    end
    if dy ~= 0 then self.view:zoom_by(dy > 0 and 1 or -1, x, y, self.doc:size()) end
end

-- drawing: the world

function Editor:_draw_routes()
    if not self.layers.routes.visible then return end
    local g   = love.graphics
    local doc = self.doc
    local z   = self.view:zoom()
    local c   = self.kit.theme.accent
    local used = {}
    for _, o in ipairs(self.selection.list) do
        if o.route then used[o.route] = true end
    end
    g.setLineWidth(1.5 / z)
    for _, route in ipairs(doc.map.routes) do
        local points = route.points
        local hot    = used[route.id] or route == self.shape
        if hot then g.setColor(c[1], c[2], c[3], 0.95) else g.setColor(1, 1, 1, 0.5) end
        for i = 1, #points - 1 do
            g.line(points[i][1], points[i][2], points[i + 1][1], points[i + 1][2])
        end
        -- Back to the start: a route is driven round and round.
        if #points > 2 then
            if hot then g.setColor(c[1], c[2], c[3], 0.4) else g.setColor(1, 1, 1, 0.22) end
            g.line(points[#points][1], points[#points][2], points[1][1], points[1][2])
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
            g.setColor(1, 1, 1, 0.3)
            g.line(o.x, o.y, route.points[1][1], route.points[1][2])
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
    -- What an armed unit sees and where it fires, for a single selection.
    if #self.selection.list > 0 and #self.selection.list <= 4 then
        for _, o in ipairs(self.selection.list) do
            local td = Entity.type_for(doc:info(o).kind_name)
            if td.armed and (td.detection_radius or 0) > 0 then
                local dx, dy = doc:delta(o.x, o.y, self.view.x, self.view.y)
                local x, y = self.view.x + dx, self.view.y + dy
                g.setColor(1, 0.4, 0.3, 0.5)
                g.circle("line", x, y, td.detection_radius, 64)
                if (td.attack_range or 0) > 0 then
                    g.setColor(1, 0.4, 0.3, 0.9)
                    g.circle("line", x, y, td.attack_range, 64)
                end
            end
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
        grid       = self.grid.show and self.grid.step or nil,
    })
    local tool = Tools.defs[self.tool]
    self.view:world_pass(function()
        g.setLineStyle("rough")
        for _, tile in ipairs(self.view:tiles(size)) do
            g.push()
            g.translate(tile.ox, tile.oy)
            self:_draw_routes()
            if tool.id == "route" or tool.id == "line" then tool.draw(self) end
            g.pop()
        end
        self:_draw_marks()
        if tool.draw and tool.id ~= "route" and tool.id ~= "line" then
            g.setLineWidth(1 / self.view:zoom())
            tool.draw(self)
        end
    end)
    g.setColor(1, 1, 1, 1)
end

-- Small marks over what matters to the objectives: targets, people, the home pad.
function Editor:_draw_badges()
    if not self.badges or self.view:zoom() < BADGE_ZOOM then return end
    local kit   = self.kit
    local theme = kit.theme
    local doc   = self.doc
    local s     = kit.scale
    local r     = self.view.rect
    local home  = doc:home()
    love.graphics.setScissor(r.x, r.y, r.w, r.h)
    for _, o in ipairs(self.view.drawn.objects) do
        local cls  = doc:info(o).cls
        local icon, color
        if cls.kind_name == "structure" and cls.behaviour == 2 and cls.is_target then icon, color = "flag", theme.danger
        elseif cls.is_target then icon, color = "target", theme.danger
        elseif (cls.pows or 0) > 0 then icon, color = "people", theme.ok
        elseif cls.kind_name == "structure" and Catalog.has_flag(cls.flags, 0x40) then icon, color = "base", theme.text end
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
    for _, line in ipairs(doc.map.lines) do
        g.setColor(line.color[1] / 255, line.color[2] / 255, line.color[3] / 255, 0.8)
        for i = 1, #line.points - 1 do
            g.line(line.points[i][1] * k, line.points[i][2] * k, line.points[i + 1][1] * k, line.points[i + 1][2] * k)
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
    for _, layer in ipairs({ "scenery", "ground", "buildings", "base", "guns", "units", "objectives" }) do
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
    local chosen = self.selection:count() > 0
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
        { label = "UNGROUP", key = "CTRL+SHIFT+G", icon = "ungroup", disabled = not chosen,
          action = function() Ops.ungroup(doc, self.selection.list) end },
    })
    local function scale_item(scale)
        return { label = string.format("INTERFACE SIZE %g X", scale), on = kit.scale == scale, action = function()
            self.ui_scale = scale
            kit.scale     = scale
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
        { label = "GO TO THE HOME PAD", key = "HOME", icon = "home", action = function() self:go_home() end },
        { label = "SHOW THE SELECTION", key = "F", icon = "fit", disabled = not chosen, action = function() self:frame_selection() end },
        {},
        scale_item(Kit.SCALES[1]), scale_item(Kit.SCALES[2]), scale_item(Kit.SCALES[3]), scale_item(Kit.SCALES[4]),
    })
    menu("menu_map", "MAP", {
        { label = "MAP SETTINGS", icon = "settings", action = function() self:open_dialog("settings") end },
        { label = "GENERATE GROUND", icon = "generate", action = function() self:open_dialog("generate") end },
        {},
        { label = "TRY THE MAP", key = "F5", icon = "play", action = function() self:play_test() end },
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
    right = right - 92
    if kit:button("try", right, 4, 92, TOP_H - 8, { text = "TRY", icon = "play", primary = true,
        tip = "PLAY THE MAP AS IT STANDS (F5)" }) then
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
    if env.weather == "snow" or env.weather == "rain" then kit:icon(env.weather, ix, (TOP_H - 16) / 2, 16, theme.text_dim) end
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
    select  = "CLICK OR DRAG A BOX TO SELECT.  DRAG THE SELECTION TO MOVE IT.  RIGHT CLICK: NOTHING SELECTED.",
    place   = "CLICK TO PLACE, DRAG FOR A ROW.  RIGHT CLICK: BACK TO SELECT.",
    scatter = "TICK OBJECTS ON THE RIGHT, THEN PAINT.",
    erase   = "PAINT OVER WHAT SHOULD GO.",
    route   = "CLICK POINTS, ENTER TO FINISH.  DRAG A POINT TO MOVE IT, CLICK A LINE TO ADD ONE, DEL REMOVES.",
    line    = "CLICK POINTS, ENTER TO FINISH.  DRAG A POINT TO MOVE IT, CLICK A LINE TO ADD ONE, DEL REMOVES.",
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
    kit:label(HINTS[self.tool], x, y, vx + vw - x - 8, OPTIONS_H, { color = theme.text_dim, size = theme.font_small })
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
    if self.selection:count() > 0 then parts[#parts + 1] = self.selection:count() .. " SELECTED" end
    parts[#parts + 1] = #self.doc.map.objects .. " OBJECTS"
    kit:label(table.concat(parts, "     "), sw * 0.5, y, sw * 0.5 - 8, STATUS_H,
        { align = "right", color = theme.text_dim, size = theme.font_small })
end

function Editor:draw()
    local kit = self.kit
    local sw, sh, vx, _, vw = self:_layout()
    love.graphics.clear(0, 0, 0, 1)
    self:_draw_world()
    self:_draw_minimap()
    kit:begin()
    self:_draw_badges()
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
