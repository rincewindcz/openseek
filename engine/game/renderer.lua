local Class     = require "engine.core.class"
local Animation = require "engine.core.animation"

local Renderer = Class()

function Renderer:init(world, camera)
    self.world         = world
    self.camera        = camera
    self.show_segments = true
    self.show_grid     = false
    self.picker        = false      -- stage picker
    self.kind_picker   = false      -- kind visibility panel
    self.kind_index    = 1          -- cursor in kind panel
    self.hidden_kinds  = {}         -- set: kind_name -> true means hidden
    self._kinds        = {}         -- ordered list of {name, count} for the panel
    self.highlight     = nil        -- Entity to tint (debug selection / hover)
end

-- Pulsing additive pass over a just-drawn sprite to mark the debug selection.
function Renderer:_glow(img, x, y, rot, sx, sy, ox, oy)
    local g = love.graphics
    local p = 0.30 + 0.18 * math.sin(love.timer.getTime() * 6)
    g.setBlendMode("add")
    g.setColor(p * 0.5, p * 0.8, p, 1)
    g.draw(img, x, y, rot, sx, sy, ox, oy)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1)
end

-- Called after a stage load to rebuild the kind list.
function Renderer:refresh_kinds()
    local counts = {}
    for _, cls in ipairs(self.world.stage.classes) do
        local kn = cls.kind_name
        if kn then counts[kn] = (counts[kn] or 0) + 1 end
    end
    -- count entities per kind
    local entity_counts = {}
    for _, e in ipairs(self.world.entities) do
        local cls = self.world.stage.classes[e.class_idx + 1]
        local kn  = cls.kind_name
        if kn then entity_counts[kn] = (entity_counts[kn] or 0) + 1 end
    end
    self._kinds = {}
    for kn, _ in pairs(counts) do
        self._kinds[#self._kinds + 1] = { name = kn, count = entity_counts[kn] or 0 }
    end
    table.sort(self._kinds, function(a, b) return a.name < b.name end)
    self.kind_index = math.min(self.kind_index, math.max(1, #self._kinds))
end

function Renderer:is_kind_visible(kind_name)
    return not self.hidden_kinds[kind_name]
end

function Renderer:toggle_kind(kind_name)
    self.hidden_kinds[kind_name] = not self.hidden_kinds[kind_name] or nil
end

function Renderer:toggle_kind_picker()
    self.kind_picker = not self.kind_picker
    if self.kind_picker then
        self:refresh_kinds()
        self.picker = false  -- close stage picker if open
    end
end

function Renderer:on_kind_picker_key(key)
    local n = #self._kinds
    if n == 0 then return end
    if key == "up" then
        self.kind_index = (self.kind_index - 2) % n + 1
    elseif key == "down" then
        self.kind_index = self.kind_index % n + 1
    elseif key == "space" or key == "return" then
        self:toggle_kind(self._kinds[self.kind_index].name)
    elseif key == "backspace" then
        self.hidden_kinds = {}  -- show all
    end
end

-- draw

function Renderer:draw()
    self:_draw_world()
    if not self.in_game then self:_draw_hud() end
    if not self.in_game then self:_draw_objective_banner() end
    if self.picker      then self:_draw_stage_picker() end
    if self.kind_picker then self:_draw_kind_picker()  end
end

function Renderer:_draw_world()
    local g  = love.graphics
    local w  = self.world
    local vp = self.camera:viewport()

    g.clear(w:ground_color())
    g.push()
    self.camera:apply()

    -- Draw the world once per overlapping map copy so it reads as seamless across
    -- the wrapped (toroidal) edges; culling uses the copy-local viewport.
    for _, t in ipairs(self.camera:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        self:_draw_world_layers({
            x0 = vp.x0 - t.ox, x1 = vp.x1 - t.ox,
            y0 = vp.y0 - t.oy, y1 = vp.y1 - t.oy,
        })
        g.pop()
    end

    g.pop()
end

function Renderer:_draw_world_layers(vp)
    local g = love.graphics
    local w = self.world

    -- Lowest layer: dust kicked up where shrapnel landed, under decals and trees.
    self:_draw_ground_fx(vp)

    self:_draw_entities(w.decals, vp)

    if self.show_segments then
        g.setLineStyle("rough")
        g.setLineWidth(1)
        for _, s in ipairs(w.stage.segments) do
            g.setColor(s.color[1] / 255, s.color[2] / 255, s.color[3] / 255)
            g.line(s.x1, s.y1, s.x2, s.y2)
        end
        g.setColor(1, 1, 1)
    end

    self:_draw_entities(w.objects, vp)
    self:_draw_objectives(vp)

    if self.show_grid then
        g.setColor(0, 0, 0, 0.2)
        g.setLineWidth(1 / self.camera:zoom())
        local ws = w.stage.world_size
        for i = 0, ws, 256 do
            g.line(i, 0, i, ws)
            g.line(0, i, ws, i)
        end
        g.setColor(1, 1, 1)
    end
end

function Renderer:_draw_entities(list, vp)
    local g       = love.graphics
    local images  = self.world.images
    local classes = self.world.stage.classes
    local hidden  = self.hidden_kinds
    g.setColor(1, 1, 1)
    for _, e in ipairs(list) do
        local cls = classes[e.class_idx + 1]
        local in_vp = e.x >= vp.x0 and e.x <= vp.x1 and e.y >= vp.y0 and e.y <= vp.y1
        if not in_vp then goto continue end
        if hidden[cls.kind_name] then goto continue end
        if e.rescue_hidden then goto continue end   -- emptied POW building marker

        -- Units with explicit alive/dead sprites (soldiers) draw axis-aligned and
        -- persist as a corpse once dead.
        if e.type_data and e.type_data.sprite then
            self:_draw_unit(e)
            goto continue
        end

        if e:is_alive() then
            local r = images[e.class_idx + 1]
            if r then
                -- Two-part tanks keep a fixed hull (turret does the aiming) unless they
                -- patrol, in which case the hull faces its travel heading; everything
                -- else rotates its single sprite to face.
                local rot = (e.turret_render and not e.route_points) and 0
                    or e:draw_angle_rad(cls.angle_steps)
                g.draw(r.img, e.x, e.y, rot, 1, 1, -r.ox, -r.oy)
                if e == self.highlight then
                    self:_glow(r.img, e.x, e.y, rot, 1, 1, -r.ox, -r.oy)
                end
            else
                g.setColor(1, 0, 1)
                g.circle("fill", e.x, e.y, 3)
                g.setColor(1, 1, 1)
            end

            -- Two-part enemy tank: the turret spins on the fixed hull from aim_angle;
            -- its destruction explosion plays over the hull until the hull itself dies.
            if e.turret_render then
                if e.turret_alive then
                    local tr  = e.turret_render
                    local rot = e.aim_angle * math.pi / 180
                    g.draw(tr.img, e.x, e.y, rot, 1, 1, tr.ax, tr.ay)
                end
                if e.turret_fx then
                    local img = e.turret_fx:current_image()
                    if img then
                        local iw, ih = img:getDimensions()
                        g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
                    end
                end
            end
            -- overlay animation (non-destructive: hit flash, etc.)
            if e.state == "animating" and e.anim then
                local img = e.anim:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
                end
            end

            -- Damage smoke emitters (persistent, threshold-based)
            for _, se in ipairs(e._damage_smokes) do
                local img = se.anim:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    g.setColor(1, 1, 1, 0.85)
                    g.draw(img, e.x + se.ox, e.y + se.oy, 0, 1, 1, iw / 2, ih / 2)
                    g.setColor(1, 1, 1)
                end
            end

            -- One-shot hit smokes (SMOKE2)
            for _, hs in ipairs(e._hit_smokes) do
                local img = hs.anim:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    g.draw(img, e.x + hs.ox, e.y + hs.oy, 0, 1, 1, iw / 2, ih / 2)
                end
            end
        else
            -- Not alive: persistent crater under any in-progress explosion.
            if e.crater_img then
                local iw, ih = e.crater_img:getDimensions()
                g.setColor(1, 1, 1)
                g.draw(e.crater_img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
            end
            if e.state == "exploding" and e.anim then
                local img = e.anim:current_image()
                if img then
                    local iw, ih = img:getDimensions()
                    g.draw(img, e.x, e.y, 0, 1, 1, iw / 2, ih / 2)
                end
            end
        end

        ::continue::
    end
end

-- Ground dust (lowest layer): drawn before decals so even trees sit above it.
function Renderer:_draw_ground_fx(vp)
    local g = love.graphics
    for _, fx in ipairs(self.world.ground_fx) do
        if fx.x >= vp.x0 and fx.x <= vp.x1 and fx.y >= vp.y0 and fx.y <= vp.y1 then
            local img = fx.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1)
                g.draw(img, fx.x, fx.y, 0, 1, 1, iw / 2, ih / 2)
            end
        end
    end
end

-- Flying iron/metal shrapnel from explosions (buildings and bombs). Drawn as its
-- own overlay (after the explosion effects) so the chunks stay visible on top of
-- the blast; tiled like the world so it wraps at the seam.
function Renderer:draw_debris()
    local w = self.world
    if #w.debris == 0 then return end
    local g  = love.graphics
    local vp = self.camera:viewport()
    g.push()
    self.camera:apply()
    for _, t in ipairs(self.camera:tiles()) do
        g.push()
        g.translate(t.ox, t.oy)
        self:_draw_debris({
            x0 = vp.x0 - t.ox, x1 = vp.x1 - t.ox,
            y0 = vp.y0 - t.oy, y1 = vp.y1 - t.oy,
        })
        g.pop()
    end
    g.pop()
end

function Renderer:_draw_debris(vp)
    local g = love.graphics
    for _, d in ipairs(self.world.debris) do
        if d.x >= vp.x0 and d.x <= vp.x1 and d.y >= vp.y0 and d.y <= vp.y1 then
            local img = d.anim:current_image()
            if img then
                local iw, ih = img:getDimensions()
                g.setColor(1, 1, 1, d.alpha or 1)
                g.draw(img, d.x, d.y, 0, 1, 1, iw / 2, ih / 2)
            end
        end
    end
    g.setColor(1, 1, 1)
end

-- Persistent damage smoke and one-shot hit smoke for an entity.
function Renderer:_draw_smokes(e)
    local g = love.graphics
    for _, se in ipairs(e._damage_smokes) do
        local img = se.anim:current_image()
        if img then
            local iw, ih = img:getDimensions()
            g.setColor(1, 1, 1, 0.85)
            g.draw(img, e.x + se.ox, e.y + se.oy, 0, 1, 1, iw / 2, ih / 2)
            g.setColor(1, 1, 1)
        end
    end
    for _, hs in ipairs(e._hit_smokes) do
        local img = hs.anim:current_image()
        if img then
            local iw, ih = img:getDimensions()
            g.draw(img, e.x + hs.ox, e.y + hs.oy, 0, 1, 1, iw / 2, ih / 2)
        end
    end
end

function Renderer:_draw_unit(e)
    local g  = love.graphics
    local td = e.type_data
    local x, y = e.x + e.death_ox, e.y + e.death_oy
    local rot  = (e.aim_angle + (td.sprite_rot or 0)) * math.pi / 180

    -- Prefer the stage's own asset sprite (frame 0 alive, dead-pose frame as the
    -- corpse) so every stage shows its own unit art; fall back to the named clip
    -- only if the stage lacks a render image.
    local r   = self.world.images[e.class_idx + 1]
    local img = r and (e:is_alive() and r.img or (r.dead or r.img)) or nil
    if not img then
        local clip = Animation.clip(e:is_alive() and td.sprite or (td.dead_sprite or td.sprite))
        img = clip and clip.frames[1] or nil
    end
    if img then
        local iw, ih = img:getDimensions()
        g.setColor(1, 1, 1)
        g.draw(img, x, y, rot, 1, 1, iw / 2, ih / 2)
        if e == self.highlight then
            self:_glow(img, x, y, rot, 1, 1, iw / 2, ih / 2)
        end
    end
    if e:is_alive() then self:_draw_smokes(e) end
end

-- Four L-shaped corners forming a target reticle around (cx, cy).
function Renderer:_corner_box(cx, cy, hw, hh)
    local g = love.graphics
    local l = math.max(3, math.min(hw, hh) * 0.5)
    local x0, y0, x1, y1 = cx - hw, cy - hh, cx + hw, cy + hh
    g.line(x0, y0, x0 + l, y0); g.line(x0, y0, x0, y0 + l)
    g.line(x1, y0, x1 - l, y0); g.line(x1, y0, x1, y0 + l)
    g.line(x0, y1, x0 + l, y1); g.line(x0, y1, x0, y1 - l)
    g.line(x1, y1, x1 - l, y1); g.line(x1, y1, x1, y1 - l)
end

-- Objective overlay (world space): bracket every live destroy-target and ring
-- the POW landing zones / civilians on rescue phases. The entity lists come
-- from the stage JSON objectives block (collected in World:load).
function Renderer:_draw_objectives(vp)
    local w   = self.world
    local obj = w.stage.objectives
    if not obj then return end
    local g = love.graphics
    g.setLineWidth(2 / self.camera:zoom())

    if obj.destroy then
        g.setColor(1, 0.3, 0.2, 0.7 + 0.3 * math.sin(love.timer.getTime() * 5))
        for _, e in ipairs(w.targets) do
            if e:is_alive() and e.x >= vp.x0 and e.x <= vp.x1 and e.y >= vp.y0 and e.y <= vp.y1 then
                local hw, hh, cx, cy = 9, 9, e.x, e.y
                local r = w.images[e.class_idx + 1]
                if r and r.img then
                    local iw, ih = r.img:getDimensions()
                    hw, hh = iw / 2 + 4, ih / 2 + 4
                    cx, cy = e.x + r.ox + iw / 2, e.y + r.oy + ih / 2
                end
                self:_corner_box(cx, cy, hw, hh)
            end
        end
    end

    if obj.rescue then
        -- POWHERE buildings are marked in-world by their own sprite and land pad (the
        -- RescueSystem), so only loose civilians get a world reticle here.
        local pulse = 0.6 + 0.4 * math.sin(love.timer.getTime() * 4)
        g.setColor(0.55, 0.9, 1, pulse)
        for _, e in ipairs(w.rescue_people) do
            if e:is_alive() and e.x >= vp.x0 and e.x <= vp.x1 and e.y >= vp.y0 and e.y <= vp.y1 then
                g.polygon("line", e.x, e.y - 7, e.x + 7, e.y, e.x, e.y + 7, e.x - 7, e.y)
            end
        end
    end

    g.setColor(1, 1, 1)
    g.setLineWidth(1)
end

-- One-line objective summary (screen space, top-center) with live counts. Shown
-- in the viewer and in game mode; phases with no destroy/rescue goal show nothing.
function Renderer:_draw_objective_banner()
    local obj = self.world.stage.objectives
    if not obj or not (obj.destroy or obj.rescue) then return end
    local g        = love.graphics
    local screen_w = g.getDimensions()
    local text, col
    if obj.destroy then
        local rem = 0
        for _, e in ipairs(self.world.targets) do if e:is_alive() then rem = rem + 1 end end
        text = string.format("OBJECTIVE: DESTROY  -  %d target%s remaining", rem, rem == 1 and "" or "s")
        if obj.special_end then text = text .. "  [COMMANDERS BUILDING]" end
        col = { 1, 0.55, 0.3 }
    else
        local n = #self.world.rescue_people
        text = n > 0
            and string.format("OBJECTIVE: RESCUE  -  %d POW%s to recover", n, n == 1 and "" or "s")
            or  "OBJECTIVE: RESCUE  -  reach the marked POW landing zones"
        col = { 0.4, 1, 0.6 }
    end
    local font = g.getFont()
    local tw   = font:getWidth(text)
    local bx   = (screen_w - tw) / 2
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", bx - 8, 44, tw + 16, 18)
    g.setColor(col[1], col[2], col[3], 1)
    g.print(text, bx, 46)
    g.setColor(1, 1, 1)
end

function Renderer:_draw_hud()
    local g = love.graphics
    g.setColor(0, 0, 0, 0.6)
    g.rectangle("fill", 0, 0, 500, 22)
    g.setColor(1, 1, 1)

    -- count hidden kinds for the hint
    local nhidden = 0
    for _ in pairs(self.hidden_kinds) do nhidden = nhidden + 1 end
    local kind_hint = nhidden > 0
        and string.format("[K]inds (%d hidden)", nhidden)
        or  "[K]inds"

    g.print(string.format(
        "%s  cam %d,%d  zoom %gx  [Tab] [L] [G] %s",
        self.world.stage_name, self.camera.x, self.camera.y,
        self.camera:zoom(), kind_hint), 4, 4)
end

function Renderer:_draw_stage_picker()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local stages             = self.world.stages
    local lh                 = 28
    local bw                 = 280
    local bh                 = #stages * lh + 50
    local bx                 = (screen_w - bw) / 2
    local by                 = (screen_h - bh) / 2
    g.setColor(0, 0, 0, 0.85)
    g.rectangle("fill", bx, by, bw, bh, 6)
    g.setColor(1, 1, 1)
    g.print("Select stage  (Enter)", bx + 16, by + 12)
    for i, name in ipairs(stages) do
        local y = by + 40 + (i - 1) * lh
        if i == self.world.stage_index then
            g.setColor(1, 1, 0)
            g.rectangle("line", bx + 10, y - 4, bw - 20, lh - 4)
        else
            g.setColor(0.8, 0.8, 0.8)
        end
        g.print(name, bx + 20, y)
    end
    g.setColor(1, 1, 1)
end

function Renderer:_draw_kind_picker()
    local g                  = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local kinds              = self._kinds
    local lh                 = 22
    local bw                 = 320
    local bh                 = #kinds * lh + 60
    local bx                 = (screen_w - bw) / 2
    local by                 = (screen_h - bh) / 2

    g.setColor(0, 0, 0, 0.88)
    g.rectangle("fill", bx, by, bw, bh, 6)
    g.setColor(1, 1, 1)
    g.print("Entity kinds  (Space toggle, Backspace show all)", bx + 12, by + 10)

    for i, entry in ipairs(kinds) do
        local y       = by + 36 + (i - 1) * lh
        local hidden  = self.hidden_kinds[entry.name]
        local cursor  = (i == self.kind_index)

        if cursor then
            g.setColor(1, 1, 0, 0.15)
            g.rectangle("fill", bx + 6, y - 2, bw - 12, lh - 2, 3)
            g.setColor(1, 1, 0)
            g.rectangle("line", bx + 6, y - 2, bw - 12, lh - 2, 3)
        end

        -- checkbox
        g.setColor(hidden and { 0.4, 0.4, 0.4 } or { 0.2, 0.9, 0.3 })
        g.print(hidden and "[ ]" or "[x]", bx + 12, y)

        -- kind name
        g.setColor(hidden and { 0.5, 0.5, 0.5 } or { 1, 1, 1 })
        g.print(entry.name, bx + 48, y)

        -- entity count
        g.setColor(0.5, 0.5, 0.5)
        g.print(tostring(entry.count), bx + bw - 44, y)
    end

    g.setColor(1, 1, 1)
end

return Renderer
