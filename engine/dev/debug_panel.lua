-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class     = require "engine.core.class"
local json      = require "lib.json"
local Animation = require "engine.core.animation"
local Log       = require "engine.core.log"

local Debug = Class()

-- layout constants
local PANEL_W   = 290
local PAD       = 10
local LINE_H    = 18
local SECT_H    = 22

local C = {
    bg       = { 0,    0,    0,    0.85 },
    sect     = { 0.18, 0.18, 0.22, 1    },
    label    = { 0.65, 0.65, 0.65, 1    },
    value    = { 1,    1,    1,    1     },
    edit     = { 1,    1,    0,    1     },
    key_col  = { 0.5,  0.8,  1,    1     },
    hint     = { 0.45, 0.45, 0.45, 1    },
    action   = { 0.3,  0.8,  0.3,  1    },
    cursor   = { 1,    1,    0,    0.18  },
    radius_d = { 1,    0.3,  0.3,  0.22  },
    radius_a = { 1,    0.7,  0,    0.22  },
    route    = { 0.3,  1,    0.3,  0.7   },
    log_bg   = { 0,    0,    0,    0.75  },
    log_sel  = { 0.2,  0.5,  1,    1     },
}

-- Step size for numeric type_data fields; anything not listed steps by 1.
local TYPE_STEP = {
    speed=5, turn_speed=5, attack_range=10, detection_radius=10, hit_radius=1,
    patrol_speed=5, patrol_turn=5, collision_radius=1, sprite_rot=15,
    ride_linger=0.1, reaction_delay=0.1,
}

-- lower number = picked first (before ground decals / scenery)
local KIND_PRIORITY = { ground_decal=0, scenery=1, tree=1 }
local function kind_priority(cls)
    return KIND_PRIORITY[cls.kind_name] or 2
end

local PICK_RADIUS = 28   -- world-px pick radius

-- helpers

local function write_json(path, t)
    local src  = love.filesystem.getSource()
    local full = src .. "/" .. path
    local lines = { "{" }
    local keys  = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    for ki, k in ipairs(keys) do
        local v   = t[k]
        local sub = { "  " .. string.format("%q", k) .. ": {" }
        local fk  = {}
        for f in pairs(v) do fk[#fk + 1] = f end
        table.sort(fk)
        for fi, f in ipairs(fk) do
            local val = v[f]
            local vs
            if     val == nil            then vs = "null"
            elseif type(val) == "string" then vs = string.format("%q", val)
            else                              vs = tostring(val)
            end
            sub[#sub + 1] = "    " .. string.format("%q", f) .. ": " .. vs ..
                (fi < #fk and "," or "")
        end
        sub[#sub + 1] = "  }" .. (ki < #keys and "," or "")
        lines[#lines + 1] = table.concat(sub, "\n")
    end
    lines[#lines + 1] = "}"
    local f = io.open(full, "w")
    if f then f:write(table.concat(lines, "\n") .. "\n"); f:close()
    else Log.warn("debug", "cannot write %s", full) end
end

local function draw_section(g, label, bx, y, w)
    g.setColor(C.sect)
    g.rectangle("fill", bx, y, w, SECT_H - 2, 2)
    g.setColor(C.label)
    g.print(label, bx + PAD, y + 2)
    return y + SECT_H
end

local function draw_info_row(g, label, value, bx, y)
    g.setColor(C.label)
    g.print(label, bx + PAD, y)
    g.setColor(C.value)
    g.print(tostring(value), bx + 150, y)
    return y + LINE_H
end

-- Debug class

function Debug:init(world, camera)
    self.world    = world
    self.camera   = camera
    self.enabled  = false
    self.hovered  = nil
    self.selected = nil
    self.fields   = {}       -- {name, kind} rows built from the selected type_data
    self.field_i  = 1
    self.show_radii = true

    -- multi-entity pick list
    self.pick_list  = nil    -- list of Entity when multiple overlap; nil otherwise
    self.pick_index = 1

    -- selection log: recent selections for reference
    self.sel_log     = {}
    self.SEL_LOG_MAX = 8

    -- animation picker
    self.anim_picker = false
    self.anim_names  = {}
    self.anim_index  = 1

    -- status message
    self._status     = nil
    self._status_ttl = 0

    -- clickable UI zones, rebuilt every draw() (field steppers, action buttons,
    -- modal rows). See _zone / _zone_at / mousepressed.
    self._zones = {}

    self.entity_types_path = "data/entity_types.json"
end

-- Register a clickable rectangle for this frame; fn runs on a left click inside.
function Debug:_zone(x, y, w, h, fn)
    self._zones[#self._zones + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

-- The handler for the topmost zone under the point (later-drawn zones win, so
-- modal rows take precedence over the inspector beneath them).
function Debug:_zone_at(mx, my)
    for i = #self._zones, 1, -1 do
        local z = self._zones[i]
        if mx >= z.x and mx <= z.x + z.w and my >= z.y and my <= z.y + z.h then
            return z.fn
        end
    end
end

-- Every type_data key of the entity as an editable row, sorted for a stable
-- layout. kind drives how Left/Right edits it: numbers step, bools toggle,
-- strings cycle through known choices.
function Debug:_build_fields(ent)
    local td    = ent.type_data or {}
    local names = {}
    for k in pairs(td) do names[#names + 1] = k end
    table.sort(names)
    local fields = {}
    for _, name in ipairs(names) do
        local t    = type(td[name])
        local kind = (t == "boolean" and "bool") or (t == "number" and "number") or "string"
        fields[#fields + 1] = { name = name, kind = kind }
    end
    return fields
end

-- Candidate values for a cyclable string field (built lazily). Returns nil for
-- free-form strings, which are then left read-only.
function Debug:_string_choices(fname)
    if fname == "weapon" then
        if not self._weapon_names then
            self._weapon_names = {}
            local raw = love.filesystem.read("data/weapons.json")
            if raw then
                for k in pairs(json.decode(raw)) do self._weapon_names[#self._weapon_names + 1] = k end
                table.sort(self._weapon_names)
            end
        end
        return self._weapon_names
    elseif fname == "explosion" or fname == "turret_explosion" then
        if not self._explosion_names then
            local set = { none = true }
            for _, n in ipairs(Animation.clip_names()) do
                local s = n:match("^explosion_(.+)$")
                if s then set[s] = true end
            end
            self._explosion_names = {}
            for k in pairs(set) do self._explosion_names[#self._explosion_names + 1] = k end
            table.sort(self._explosion_names)
        end
        return self._explosion_names
    elseif fname == "sprite" or fname == "dead_sprite" then
        return Animation.clip_names()
    end
    return nil
end

function Debug:_edit_field(td, f, dir)
    if f.kind == "number" then
        local step = TYPE_STEP[f.name] or 1
        td[f.name] = math.max(0, (td[f.name] or 0) + dir * step)
    elseif f.kind == "bool" then
        td[f.name] = not td[f.name]
    else
        local choices = self:_string_choices(f.name)
        if choices and #choices > 0 then
            local idx = 1
            for i, c in ipairs(choices) do if c == td[f.name] then idx = i; break end end
            td[f.name] = choices[(idx - 1 + dir) % #choices + 1]
        end
    end
end

function Debug:toggle()
    self.enabled     = not self.enabled
    self.hovered     = nil
    self.selected    = nil
    self.pick_list   = nil
    self.anim_picker = false
end

function Debug:update()
    if not self.enabled then return end
    if not self.pick_list then
        self.hovered = self:_entity_under_mouse()
    end
    if self._status_ttl > 0 then
        self._status_ttl = self._status_ttl - love.timer.getDelta()
        if self._status_ttl <= 0 then self._status = nil end
    end
end

function Debug:_set_status(msg)
    self._status     = msg
    self._status_ttl = 2.5
end

-- The selected entity has a weapon and can be test-fired (needs the combat system
-- wired in from main.lua).
function Debug:_can_fire()
    local e = self.selected
    if not self.combat or not e then return false end
    local td = e.type_data or {}
    return (e.weapon or td.weapon) ~= nil
end

function Debug:_fire_selected()
    if not self:_can_fire() then return end
    if self.combat:fire_entity(self.selected) then
        local td = self.selected.type_data or {}
        self:_set_status("fired: " .. tostring(self.selected.weapon or td.weapon))
    end
end

-- The entity to glow in the world: the overlapping candidate currently under the
-- pick-list cursor (so the user sees which one Enter will pick), else the
-- selection / hover.
function Debug:highlight_entity()
    if not self.enabled then return nil end
    if self.pick_list then return self.pick_list[self.pick_index] end
    return self.selected or self.hovered
end

-- True while F2 is steering its own UI with the arrow keys (pick list, animation
-- picker, or a selected entity's field editor), so the overview camera must not
-- pan at the same time.
function Debug:captures_arrows()
    return self.enabled and (self.pick_list ~= nil or self.anim_picker or self.selected ~= nil)
end

-- input

function Debug:keypressed(key)
    if not self.enabled then return false end
    if key == "f2" then self:toggle(); return true end

    if self.anim_picker then
        return self:_anim_picker_key(key)
    end

    if self.pick_list then
        return self:_pick_list_key(key)
    end

    if not self.selected then return false end

    local n = #self.fields
    if n > 0 then
        if key == "up" then
            self.field_i = (self.field_i - 2) % n + 1
            return true
        end
        if key == "down" then
            self.field_i = self.field_i % n + 1
            return true
        end
        local f  = self.fields[self.field_i]
        local td = self.selected.type_data
        if f and td then
            if key == "right" or key == "=" or key == "+" or key == "kp+" then
                self:_edit_field(td, f, 1); return true
            end
            if key == "left" or key == "-" or key == "kp-" then
                self:_edit_field(td, f, -1); return true
            end
        end
    end

    if key == "p" then self:_open_anim_picker(); return true end
    if key == "f" then self:_fire_selected(); return true end
    if key == "x" then
        self.selected:take_damage(self.selected.hp + 1)
        self:_set_status("killed")
        return true
    end
    if key == "r" then
        self.selected.hp    = self.selected.max_hp
        self.selected.state = "idle"
        self.selected.anim  = nil
        self:_set_status("revived")
        return true
    end
    if key == "s" then
        self:_save_entity_types()
        self:_set_status("saved entity_types.json")
        return true
    end
    if key == "escape" then
        self.selected = nil
        return true
    end
    return false
end

function Debug:mousepressed(mx, my, button)
    if not self.enabled then return false end
    if button ~= 1 then return false end

    -- A clickable UI zone (field stepper, action button, or modal row) wins over
    -- everything else on the panel.
    local fn = self:_zone_at(mx, my)
    if fn then fn(); return true end

    -- A click off the modal rows dismisses the modal.
    if self.anim_picker then
        self.anim_picker = false
        return true
    end
    if self.pick_list then
        self.pick_list = nil
        return true
    end

    -- Otherwise this is a world click: pick the entity (or overlap list) under it.
    local wx, wy = self:_screen_to_world(mx, my)
    local candidates = self:_entities_near(wx, wy, PICK_RADIUS)
    if #candidates == 0 then
        self.selected = nil
    elseif #candidates == 1 then
        self:_select(candidates[1])
    else
        self.pick_list  = candidates
        self.pick_index = 1
    end
    self.field_i = 1
    return true
end

function Debug:_pick_list_key(key)
    local n = #self.pick_list
    if key == "escape" then
        self.pick_list = nil
    elseif key == "up" then
        self.pick_index = (self.pick_index - 2) % n + 1
    elseif key == "down" then
        self.pick_index = self.pick_index % n + 1
    elseif key == "return" or key == "space" then
        self:_select(self.pick_list[self.pick_index])
        self.pick_list = nil
    end
    return true
end

function Debug:_select(ent)
    self.selected = ent
    self.fields   = self:_build_fields(ent)
    self.field_i  = 1
    -- add to log
    local cls = self.world.stage.classes[ent.class_idx + 1]
    local entry = {
        id   = ent.id,
        kind = cls.kind_name or "?",
        x    = ent.x,
        y    = ent.y,
        ref  = ent,
    }
    -- remove duplicate id if already in log
    for i = #self.sel_log, 1, -1 do
        if self.sel_log[i].id == ent.id then
            table.remove(self.sel_log, i)
        end
    end
    table.insert(self.sel_log, 1, entry)
    if #self.sel_log > self.SEL_LOG_MAX then
        self.sel_log[#self.sel_log] = nil
    end
end

-- draw

function Debug:draw()
    if not self.enabled then return end
    local g = love.graphics
    self._zones = {}   -- rebuilt fresh each frame

    g.push()
    self.camera:apply()
    self:_draw_radii()
    g.pop()

    self:_draw_stats_bar()
    self:_draw_selection_log()

    local ent = self.selected or self.hovered
    if ent then self:_draw_inspector(ent) end

    if self.pick_list  then self:_draw_pick_list()  end
    if self.anim_picker then self:_draw_anim_picker() end

    self:_draw_help()
end

-- inspector

function Debug:_draw_inspector(ent)
    local g   = love.graphics
    local cls = self.world.stage.classes[ent.class_idx + 1]
    local td  = ent.type_data or {}
    local sel = (self.selected == ent)
    local mx, my = love.mouse.getPosition()

    local fields = sel and self.fields or self:_build_fields(ent)

    local can_fire = sel and self:_can_fire()
    local n_info  = 10
    local n_type  = math.max(1, #fields)
    local n_act   = 4 + (can_fire and 1 or 0)
    local total_h = PAD + SECT_H       -- title band
        + SECT_H + n_info * LINE_H
        + SECT_H + n_type * LINE_H
        + SECT_H + n_act  * LINE_H
        + (self._status and LINE_H or 0)
        + PAD

    local bx = g.getWidth() - PANEL_W - 8
    local by = 30

    g.setColor(C.bg)
    g.rectangle("fill", bx, by, PANEL_W, total_h, 4)
    -- Swallow clicks anywhere on the panel so panel chrome never world-picks or
    -- deselects; specific buttons register their own zones on top of this.
    self:_zone(bx, by, PANEL_W, total_h, function() end)

    local y = by + PAD

    -- title band
    g.setColor(0.12, 0.28, 0.4, 1)
    g.rectangle("fill", bx, y, PANEL_W, SECT_H - 2, 2)
    g.setColor(0.5, 0.9, 1, 1)
    g.print("ENTITY EDITOR", bx + PAD, y + 2)
    g.setColor(C.hint)
    local kn = cls.kind_name or "?"
    g.print(kn, bx + PANEL_W - g.getFont():getWidth(kn) - PAD, y + 2)
    y = y + SECT_H

    y = draw_section(g, "Info", bx, y, PANEL_W)
    y = draw_info_row(g, "id",    ent.id,                                    bx, y)
    y = draw_info_row(g, "class", ent.class_idx,                             bx, y)
    y = draw_info_row(g, "kind",  cls.kind_name or "?",                      bx, y)
    y = draw_info_row(g, "asset", self.world:asset_file(ent.class_idx) or "-", bx, y)
    y = draw_info_row(g, "sprite", cls.render and cls.render.image or "-",   bx, y)
    y = draw_info_row(g, "pos",   string.format("%d, %d", ent.x, ent.y),    bx, y)
    y = draw_info_row(g, "angle", string.format("%.1f", ent.angle),          bx, y)
    local hp_pct = ent.max_hp > 0 and ent.hp / ent.max_hp or 0
    g.setColor(C.label); g.print("hp", bx + PAD, y)
    g.setColor(hp_pct > 0.5 and {0.3,1,0.3,1} or hp_pct > 0.2 and {1,0.8,0.1,1} or {1,0.3,0.3,1})
    g.print(string.format("%d / %d", ent.hp, ent.max_hp), bx + 150, y)
    y = y + LINE_H
    y = draw_info_row(g, "state", ent.state,            bx, y)
    y = draw_info_row(g, "route", ent.route or "none",  bx, y)

    -- A small clickable box drawn at (x,y,w,h); highlights when hovered.
    local fh = g.getFont():getHeight()
    local function draw_btn(x, y0, w, h, txt)
        local over = mx >= x and mx <= x + w and my >= y0 and my <= y0 + h
        g.setColor(over and {0.30, 0.55, 0.90, 1} or {0.22, 0.25, 0.31, 1})
        g.rectangle("fill", x, y0, w, h, 2)
        g.setColor(over and {1, 1, 1, 1} or {0.82, 0.86, 0.92, 1})
        g.print(txt, x + (w - g.getFont():getWidth(txt)) / 2, y0 + (h - fh) / 2)
    end

    y = draw_section(g, "Type data  (shared by kind)", bx, y, PANEL_W)
    if #fields == 0 then
        y = draw_info_row(g, "(no fields)", "", bx, y)
    else
        local sw  = 16
        local mnx = bx + 150
        local plx = bx + PANEL_W - PAD - sw
        for i, f in ipairs(fields) do
            local v = td[f.name]
            if v == nil then v = "-" end
            local hot = sel and i == self.field_i
            if hot then
                g.setColor(C.cursor)
                g.rectangle("fill", bx + 4, y - 1, PANEL_W - 8, LINE_H)
            end
            g.setColor(hot and C.edit or C.label)
            g.print(f.name, bx + PAD, y)
            if sel then
                draw_btn(mnx, y - 1, sw, LINE_H - 1, "-")
                self:_zone(mnx, y - 1, sw, LINE_H - 1,
                    function() self.field_i = i; self:_edit_field(td, f, -1) end)
                draw_btn(plx, y - 1, sw, LINE_H - 1, "+")
                self:_zone(plx, y - 1, sw, LINE_H - 1,
                    function() self.field_i = i; self:_edit_field(td, f, 1) end)
                self:_zone(bx + PAD, y - 1, 150 - PAD, LINE_H,
                    function() self.field_i = i end)
                g.setColor(hot and C.edit or C.key_col)
                local vt = tostring(v)
                g.print(vt, mnx + sw + (plx - mnx - sw - g.getFont():getWidth(vt)) / 2, y)
            else
                g.setColor(C.key_col)
                g.print(tostring(v), bx + 150, y)
            end
            y = y + LINE_H
        end
    end

    y = draw_section(g, "Actions", bx, y, PANEL_W)
    if sel then
        local function action_btn(key, label, fn)
            local ah = LINE_H - 2
            local over = mx >= bx + PAD and mx <= bx + PANEL_W - PAD and my >= y and my <= y + ah
            if over then
                g.setColor(0.30, 0.55, 0.90, 0.35)
                g.rectangle("fill", bx + PAD, y, PANEL_W - 2 * PAD, ah, 2)
            end
            g.setColor(C.action); g.print("[" .. key .. "]", bx + PAD + 2, y)
            g.setColor(C.value);  g.print(label, bx + 50, y)
            self:_zone(bx + PAD, y, PANEL_W - 2 * PAD, ah, fn)
            y = y + LINE_H
        end
        action_btn("P", "play animation...", function() self:_open_anim_picker() end)
        if can_fire then
            action_btn("F", "fire weapon", function() self:_fire_selected() end)
        end
        action_btn("X", "kill entity", function()
            self.selected:take_damage(self.selected.hp + 1); self:_set_status("killed")
        end)
        action_btn("R", "revive entity", function()
            self.selected.hp    = self.selected.max_hp
            self.selected.state = "idle"
            self.selected.anim  = nil
            self:_set_status("revived")
        end)
        action_btn("S", "save entity_types.json", function()
            self:_save_entity_types(); self:_set_status("saved entity_types.json")
        end)
    else
        g.setColor(C.hint)
        g.print("click an entity to edit its kind", bx + PAD, y)
        y = y + LINE_H * 4
    end

    if self._status then
        g.setColor(0.3, 1, 0.6, math.min(1, self._status_ttl))
        g.print(self._status, bx + PAD, y)
    end

    g.setColor(C.hint)
    if sel then
        g.print("-/+ or click steppers   Esc deselect", bx + PAD, by + total_h + 2)
    else
        g.print("click to edit", bx + PAD, by + total_h + 2)
    end
end

-- multi-entity pick list

function Debug:_draw_pick_list()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local list               = self.pick_list
    local lh                 = 22
    local bw                 = 340
    local bh                 = #list * lh + 52
    local bx                 = (screen_w - bw) / 2
    local by                 = (screen_h - bh) / 2

    g.setColor(C.bg)
    g.rectangle("fill", bx, by, bw, bh, 6)
    self:_zone(bx, by, bw, bh, function() end)   -- box swallows off-row clicks
    g.setColor(C.value)
    g.print(string.format("Select entity  (%d overlapping)", #list), bx + PAD, by + PAD)

    for i, ent in ipairs(list) do
        local y   = by + 32 + (i - 1) * lh
        local cls = self.world.stage.classes[ent.class_idx + 1]
        local td  = ent.type_data or {}
        local hit = td.hit_radius or 0
        local label = string.format("#%d  %s  hp:%d  r:%d",
            ent.id, cls.kind_name or "?", ent.hp, hit)

        if i == self.pick_index then
            g.setColor(C.cursor)
            g.rectangle("fill", bx + 4, y - 1, bw - 8, lh - 1, 2)
            g.setColor(C.edit)
        else
            g.setColor(C.value)
        end
        g.print(label, bx + PAD, y)
        self:_zone(bx + 4, y - 1, bw - 8, lh - 1, function()
            self:_select(ent); self.pick_list = nil
        end)
    end

    g.setColor(C.hint)
    g.print("Up/Down navigate   Enter select   Esc cancel", bx + PAD, by + bh - LINE_H - 4)
end

-- selection log

function Debug:_draw_selection_log()
    local g    = love.graphics
    local log  = self.sel_log
    if #log == 0 then return end

    local lh   = 16
    local bw   = 260
    local bh   = #log * lh + 28
    local bx   = 8
    local by   = g.getHeight() - bh - 28

    g.setColor(C.log_bg)
    g.rectangle("fill", bx, by, bw, bh, 4)
    g.setColor(C.label)
    g.print("Selection log", bx + PAD, by + 6)

    for i, entry in ipairs(log) do
        local y    = by + 22 + (i - 1) * lh
        local live = entry.ref:is_alive()
        if entry.ref == self.selected then
            g.setColor(C.edit)
        elseif not live then
            g.setColor(0.4, 0.4, 0.4, 1)
        else
            g.setColor(C.log_sel)
        end
        g.print(string.format("#%-4d  %s", entry.id, entry.kind), bx + PAD, y)
        g.setColor(C.hint)
        g.print(string.format("%d,%d", entry.x, entry.y), bx + 180, y)
    end
end

-- animation picker

function Debug:_open_anim_picker()
    self.anim_names  = Animation.clip_names()
    self.anim_index  = 1
    self.anim_picker = true
end

function Debug:_anim_picker_key(key)
    local n = #self.anim_names
    if n == 0 then self.anim_picker = false; return true end
    if key == "escape" or key == "p" then
        self.anim_picker = false
    elseif key == "up" then
        self.anim_index = (self.anim_index - 2) % n + 1
    elseif key == "down" then
        self.anim_index = self.anim_index % n + 1
    elseif key == "return" or key == "space" then
        local name = self.anim_names[self.anim_index]
        if self.selected then
            self.selected:play_anim(name)
            self:_set_status("playing: " .. name)
        end
        self.anim_picker = false
    end
    return true
end

function Debug:_draw_anim_picker()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local names              = self.anim_names
    local lh                 = 22
    local bw                 = 320
    local bh                 = #names * lh + 60
    local bx                 = (screen_w - bw) / 2
    local by                 = (screen_h - bh) / 2

    g.setColor(C.bg)
    g.rectangle("fill", bx, by, bw, bh, 6)
    self:_zone(bx, by, bw, bh, function() end)   -- box swallows off-row clicks
    g.setColor(C.value)
    local title = self.selected
        and string.format("Play animation on #%d", self.selected.id)
        or  "Play animation"
    g.print(title, bx + PAD, by + PAD)

    for i, name in ipairs(names) do
        local y = by + 36 + (i - 1) * lh
        if i == self.anim_index then
            g.setColor(C.cursor)
            g.rectangle("fill", bx + 4, y - 1, bw - 8, lh - 1, 2)
            g.setColor(C.edit)
        else
            g.setColor(C.value)
        end
        g.print(name, bx + PAD, y)
        self:_zone(bx + 4, y - 1, bw - 8, lh - 1, function()
            if self.selected then
                self.selected:play_anim(name)
                self:_set_status("playing: " .. name)
            end
            self.anim_picker = false
        end)
    end

    g.setColor(C.hint)
    g.print("Up/Down navigate   Enter play   Esc close", bx + PAD, by + bh - LINE_H - 4)
end

-- world-space overlays

function Debug:_draw_radii()
    if not self.show_radii then return end
    local g   = love.graphics
    local ent = self.selected or self.hovered
    if not ent then return end
    local td  = ent.type_data or {}

    g.setLineWidth(1)
    if (td.detection_radius or 0) > 0 then
        g.setColor(C.radius_d)
        g.circle("fill", ent.x, ent.y, td.detection_radius)
        g.setColor(C.radius_d[1], C.radius_d[2], C.radius_d[3], 0.8)
        g.circle("line", ent.x, ent.y, td.detection_radius)
    end
    if (td.attack_range or 0) > 0 then
        g.setColor(C.radius_a)
        g.circle("fill", ent.x, ent.y, td.attack_range)
        g.setColor(C.radius_a[1], C.radius_a[2], C.radius_a[3], 0.9)
        g.circle("line", ent.x, ent.y, td.attack_range)
    end
    if (td.hit_radius or 0) > 0 then
        g.setColor(0.2, 0.8, 1, 0.6)
        g.circle("line", ent.x, ent.y, td.hit_radius)
    end
    if ent.route then
        local route = self.world.stage.routes and self.world.stage.routes[ent.route + 1]
        if route and route.points then
            g.setColor(C.route)
            for i, pt in ipairs(route.points) do
                g.circle("fill", pt.x, pt.y, 4)
                if i > 1 then
                    local prev = route.points[i - 1]
                    g.line(prev.x, prev.y, pt.x, pt.y)
                end
            end
        end
    end
    g.setColor(1, 1, 1)
end

-- stats bar & help

function Debug:_draw_stats_bar()
    -- The overview (editor) shows this live state in its own bottom status bar and
    -- has no F2 toggle, so the top-right bar is redundant there.
    if self.editor then return end
    local g    = love.graphics
    local live = 0
    for _, e in ipairs(self.world.entities) do
        if e:is_alive() then live = live + 1 end
    end
    local text = string.format("FPS %d   entities %d / %d   [F2] debug",
        love.timer.getFPS(), live, #self.world.entities)
    local screen_w = g.getWidth()
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", screen_w - 340, 0, 340, 22)
    g.setColor(C.hint)
    g.print(text, screen_w - 336, 4)
end

function Debug:_draw_help()
    if self.editor then return end   -- editor is always on here; no [F2] toggle hint
    local g        = love.graphics
    local screen_w = g.getWidth()
    local screen_h = g.getHeight()
    g.setColor(C.hint)
    g.print("[F2] close debug", screen_w - 144, screen_h - 20)
end

-- save

function Debug:_save_entity_types()
    -- Start from the full on-disk set so kinds absent from the current stage are
    -- preserved (a stage without tanks/soldiers must not drop their types); overlay
    -- the live, possibly edited type_data for the kinds present on this stage.
    local types = {}
    local existing = love.filesystem.read(self.entity_types_path)
    if existing then
        local ok, decoded = pcall(json.decode, existing)
        if ok and type(decoded) == "table" then types = decoded end
    end
    local seen = {}
    for _, e in ipairs(self.world.entities) do
        local cls = self.world.stage.classes[e.class_idx + 1]
        local kn  = cls.kind_name
        if kn and not seen[kn] and e.type_data then
            seen[kn]  = true
            types[kn] = e.type_data
        end
    end
    write_json(self.entity_types_path, types)
end

-- picking helpers

-- Returns entities within world-px radius sorted: high-priority kinds first,
-- then by hit_radius descending (larger/more solid objects before flat decals).
function Debug:_entities_near(wx, wy, radius)
    local r2   = radius * radius
    local list = {}
    for _, e in ipairs(self.world.entities) do
        if e:is_alive() then
            local dx, dy = e.x - wx, e.y - wy
            if dx*dx + dy*dy <= r2 then
                list[#list + 1] = e
            end
        end
    end
    local classes = self.world.stage.classes
    table.sort(list, function(a, b)
        local ca, cb = classes[a.class_idx + 1], classes[b.class_idx + 1]
        local pa, pb = kind_priority(ca), kind_priority(cb)
        if pa ~= pb then return pa > pb end
        local ra = (a.type_data and a.type_data.hit_radius) or 0
        local rb = (b.type_data and b.type_data.hit_radius) or 0
        return ra > rb
    end)
    return list
end

-- Nearest single entity within radius (used for hover highlight).
function Debug:_entity_under_mouse()
    local mx, my  = love.mouse.getPosition()
    local wx, wy  = self:_screen_to_world(mx, my)
    local best, best_d2 = nil, PICK_RADIUS * PICK_RADIUS
    local classes = self.world.stage.classes
    for _, e in ipairs(self.world.entities) do
        if e:is_alive() then
            local cls    = classes[e.class_idx + 1]
            local dx, dy = e.x - wx, e.y - wy
            local d2     = dx*dx + dy*dy
            -- weight distance by inverse priority so higher-priority kinds win ties
            local w = 1 + (2 - kind_priority(cls)) * 0.3
            if d2 * w < best_d2 then best_d2 = d2 * w; best = e end
        end
    end
    return best
end

function Debug:_screen_to_world(sx, sy)
    local screen_w, screen_h = love.graphics.getDimensions()
    local z  = self.camera:zoom()
    local dx = (sx - screen_w / 2) / z
    local dy = (sy - screen_h / 2) / z
    -- undo camera rotation when in game mode
    local a  = self.camera.angle
    if a then
        local ca, sa = math.cos(-a), math.sin(-a)
        dx, dy = dx * ca - dy * sa, dx * sa + dy * ca
    end
    return self.camera.x + dx, self.camera.y + dy
end

return Debug
