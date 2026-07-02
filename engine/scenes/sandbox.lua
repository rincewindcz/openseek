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
    local pw       = 220
    local ph       = #PARAMS * 18 + 58
    local bx       = screen_w - pw - 4
    local by       = 30

    g.setColor(0, 0, 0, 0.88)
    g.rectangle("fill", bx, by, pw, ph, 4)
    g.setColor(0.3, 0.9, 0.3, 1)
    g.print("SANDBOX: " .. self.app.settings.vehicle, bx + 8, by + 6)

    local def = self:_def() or {}
    for i, p in ipairs(PARAMS) do
        local y = by + 24 + (i - 1) * 18
        if i == self.cursor then
            g.setColor(0.2, 0.5, 1, 0.3)
            g.rectangle("fill", bx + 2, y - 1, pw - 4, 18)
            g.setColor(1, 1, 0, 1)
        else
            g.setColor(0.75, 0.75, 0.75, 1)
        end
        local val = def[p.name]
        local value_text = val ~= nil and string.format("%.4g", val) or "?"
        g.print(string.format("%-16s %6s", p.name, value_text), bx + 8, y)
    end

    g.setColor(0.45, 0.45, 0.45, 1)
    g.print("[/] nav  +/- adj  F4 save  F3 exit", bx + 4, by + ph - 18)

    if self.status ~= "" then
        g.setColor(0.1, 1, 0.4, 1)
        g.print(self.status, bx + 8, by + ph + 4)
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
