local Class    = require "engine.core.class"
local Gameplay = require "engine.scenes.gameplay"

-- Sandbox: single-player gameplay plus a live vehicle-parameter editor. Edits
-- apply to the shared vehicle def immediately; F4 writes it back to
-- data/vehicles/<vehicle>.json.
local Sandbox = Class(Gameplay)

local PARAMS = {
    { name="sprite_scale",   step=0.5  },
    { name="rotor_y_offset", step=1    },
    { name="rotor_fps",      step=2    },
    { name="turn_rate",      step=5    },
    { name="accel",          step=10   },
    { name="decel",          step=10   },
    { name="brake",          step=10   },
    { name="max_fwd",        step=10   },
    { name="max_rev",        step=5    },
    { name="strafe_speed",   step=5    },
    { name="strafe_accel",   step=10   },
    { name="fuel_drain",     step=0.1  },
    { name="takeoff_time",   step=0.05 },
    { name="land_time",      step=0.05 },
}

function Sandbox:init(app)
    Gameplay.init(self, app)
    self.cursor       = 1
    self.status       = ""
    self.status_timer = 0
    self._zones       = {}   -- clickable panel rects, rebuilt each draw
end

function Sandbox:enter()
    Gameplay.enter(self)
    love.window.setTitle(self.app.world:title() .. "  [sandbox:" .. self.app.settings.vehicle .. "]")
end

function Sandbox:_def()
    return self.app.vehicle_defs[self.app.settings.vehicle]
end

function Sandbox:apply()
    local def = self:_def()
    if self.player and def then self.player:load_vehicle_def(def) end
end

function Sandbox:adjust(dir)
    local def = self:_def()
    if not def then return end
    local p = PARAMS[self.cursor]
    def[p.name] = (def[p.name] or 0) + dir * p.step
    self:apply()
end

function Sandbox:save()
    local def = self:_def()
    if not def then return end
    local src  = love.filesystem.getSource()
    local path = src .. "/data/vehicles/" .. self.app.settings.vehicle .. ".json"
    local f    = io.open(path, "w")
    if not f then
        self.status       = "ERROR: cannot write"
        self.status_timer = 3
        return
    end
    f:write("{\n")
    local keys = {}
    for k in pairs(def) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
        local v = def[k]
        local value_text = type(v) == "number" and string.format("%.4g", v) or tostring(v)
        f:write(string.format('  "%s": %s%s\n', k, value_text, i < #keys and "," or ""))
    end
    f:write("}\n")
    f:close()
    self.status       = "Saved!"
    self.status_timer = 2
end

function Sandbox:update(dt)
    Gameplay.update(self, dt)
    if self.paused or self.app.end_stats:is_active() then return end
    if self.status_timer > 0 then
        self.status_timer = self.status_timer - dt
        if self.status_timer <= 0 then
            self.status       = ""
            self.status_timer = 0
        end
    end
end

function Sandbox:draw()
    Gameplay.draw(self)
    self:_draw_panel()
end

function Sandbox:_draw_panel()
    local g        = love.graphics
    local screen_w = g.getDimensions()
    local pw       = 250
    local ph       = #PARAMS * 18 + 76
    local bx       = screen_w - pw - 4
    local by       = 30
    local mx, my   = love.mouse.getPosition()
    self._zones    = {}

    local function draw_btn(x, y0, w, h, txt)
        local over = mx >= x and mx <= x + w and my >= y0 and my <= y0 + h
        g.setColor(over and {0.30, 0.55, 0.90, 1} or {0.22, 0.25, 0.31, 1})
        g.rectangle("fill", x, y0, w, h, 2)
        g.setColor(over and {1, 1, 1, 1} or {0.82, 0.86, 0.92, 1})
        local fh = g.getFont():getHeight()
        g.print(txt, x + (w - g.getFont():getWidth(txt)) / 2, y0 + (h - fh) / 2)
    end

    g.setColor(0, 0, 0, 0.88)
    g.rectangle("fill", bx, by, pw, ph, 4)
    g.setColor(0.12, 0.34, 0.18, 1)
    g.rectangle("fill", bx, by, pw, 20, 2)
    g.setColor(0.4, 1, 0.5, 1)
    g.print("VEHICLE EDITOR: " .. self.app.settings.vehicle, bx + 8, by + 3)

    local def = self:_def() or {}
    local sw, plx = 16, bx + pw - 8 - 16
    local mnx     = plx - 4 - 16
    for i, p in ipairs(PARAMS) do
        local y = by + 26 + (i - 1) * 18
        if i == self.cursor then
            g.setColor(0.2, 0.5, 1, 0.3)
            g.rectangle("fill", bx + 2, y - 1, pw - 4, 18)
            g.setColor(1, 1, 0, 1)
        else
            g.setColor(0.75, 0.75, 0.75, 1)
        end
        g.print(p.name, bx + 8, y)
        local val = def[p.name]
        local value_text = val ~= nil and string.format("%.4g", val) or "?"
        g.print(value_text, mnx - 8 - g.getFont():getWidth(value_text), y)

        draw_btn(mnx, y - 1, sw, 17, "-")
        self._zones[#self._zones + 1] = { x = mnx, y = y - 1, w = sw, h = 17,
            fn = function() self.cursor = i; self:adjust(-1) end }
        draw_btn(plx, y - 1, sw, 17, "+")
        self._zones[#self._zones + 1] = { x = plx, y = y - 1, w = sw, h = 17,
            fn = function() self.cursor = i; self:adjust(1) end }
        self._zones[#self._zones + 1] = { x = bx + 2, y = y - 1, w = mnx - bx - 4, h = 17,
            fn = function() self.cursor = i end }
    end

    local sy = by + 26 + #PARAMS * 18 + 4
    draw_btn(bx + 8, sy, 60, 18, "SAVE")
    self._zones[#self._zones + 1] = { x = bx + 8, y = sy, w = 60, h = 18,
        fn = function() self:save() end }
    g.setColor(0.45, 0.45, 0.45, 1)
    g.print("[/] nav  +/- or click  F3 exit", bx + 78, sy + 2)

    if self.status ~= "" then
        g.setColor(0.1, 1, 0.4, 1)
        g.print(self.status, bx + 8, by + ph + 4)
    end
end

function Sandbox:mousepressed(mx, my)
    if self.paused or self.app.end_stats:is_active() then return end
    for _, z in ipairs(self._zones) do
        if mx >= z.x and mx <= z.x + z.w and my >= z.y and my <= z.y + z.h then
            z.fn()
            return
        end
    end
end

-- Editor keys; everything else falls through to the game keys so movement
-- (WASD, Space, weapons) keeps working while editing.
function Sandbox:sandbox_keys(key)
    if key == "f3" then self.app.scenes:switch("overview"); return true end
    if key == "f4" then self:save(); return true end
    if key == "[" then
        self.cursor = ((self.cursor - 2) % #PARAMS) + 1
        return true
    end
    if key == "]" then
        self.cursor = self.cursor % #PARAMS + 1
        return true
    end
    if key == "=" or key == "kp+" then self:adjust( 1); return true end
    if key == "-" or key == "kp-" then self:adjust(-1); return true end
    return false
end

function Sandbox:keypressed(key)
    if self:debug_keys(key) then return end
    if self:sandbox_keys(key) then return end
    self:game_keys(key)
end

return Sandbox
