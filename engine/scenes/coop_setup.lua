local Class        = require "engine.core.class"
local Scene        = require "engine.core.scene"
local Animation    = require "engine.core.animation"
local Vehicles     = require "engine.game.vehicles"
local CoopGameplay = require "engine.scenes.coop_gameplay"

-- 2P setup overlay over the overview: each player toggles their own vehicle
-- with their own keys at any time (no cursor); G/F toggle god / friendly
-- fire; SPACE starts the split-screen game, Esc backs out.
local CoopSetup = Class(Scene)

local COLORS      = CoopGameplay.COLORS
local P1_CONTROLS = CoopGameplay.P1_CONTROLS
local P2_CONTROLS = CoopGameplay.P2_CONTROLS

-- Draw a representative vehicle sprite (chopper body or tank hull+turret),
-- centered and scaled to fit a menu box. skin picks the chopper variant.
local function draw_vehicle_icon(g, vehicle, cx, cy, scale, skin)
    local function img(clip, idx)
        local c = Animation.clip(clip)
        return c and c.frames[idx]
    end
    g.setColor(1, 1, 1)
    if vehicle == "tank" then
        local hull = img("tankbgrn", 1)
        if hull then local w, h = hull:getDimensions(); g.draw(hull, cx, cy, 0, scale, scale, w/2, h/2) end
        local top = img("tanktop", 1)
        if top then
            local ax, ay = Animation.frame_anchor("tanktop", 1)
            g.draw(top, cx, cy, 0, scale, scale, ax, ay)
        end
    else
        local body = img("choppit" .. (skin or 1), 8)   -- neutral pitch frame
        if body then local w, h = body:getDimensions(); g.draw(body, cx, cy, 0, scale, scale, w/2, h/2) end
        local rotor = img("bladep", 1)
        if rotor then local w, h = rotor:getDimensions(); g.draw(rotor, cx, cy, 0, scale, scale, w/2, h/2) end
    end
end

function CoopSetup:_toggle_vehicle(idx)
    local coop = self.app.settings.coop
    coop.vehicle[idx], coop.skin[idx] = Vehicles.cycle(coop.vehicle[idx], coop.skin[idx])
end

function CoopSetup:update(dt)
    -- The camera stays put while the setup panel is up; the world keeps living.
    self.app.world:update(dt)
    self.app.debug_panel:update()
end

-- One player's vehicle selection box: a square in the player's color holding
-- the current vehicle icon. Each player toggles their own box independently,
-- so both boxes are always live (no cursor / focus).
function CoopSetup:_draw_player_box(g, idx, bx, by, bw, bh)
    local coop = self.app.settings.coop
    local col  = COLORS[idx]
    g.setColor(0, 0, 0, 0.5)
    g.rectangle("fill", bx, by, bw, bh)
    g.setColor(col[1], col[2], col[3], 1)
    g.setLineWidth(4)
    g.rectangle("line", bx, by, bw, bh)
    g.setLineWidth(1)
    g.print("PLAYER " .. idx, bx + 8, by + 6)
    draw_vehicle_icon(g, coop.vehicle[idx], bx + bw / 2, by + bh / 2 + 6, 2, coop.skin[idx])
    g.setColor(1, 1, 1, 1)
    local name = Vehicles.label(coop.vehicle[idx], coop.skin[idx])
    g.print("< " .. name .. " >", bx + bw / 2 - 40, by + bh - 22)
end

function CoopSetup:draw()
    local app  = self.app
    local coop = app.settings.coop
    -- The overview stays visible behind the translucent setup panel.
    app.scenes:get("overview"):draw()

    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 0.85)
    g.rectangle("fill", 0, 0, screen_w, screen_h)

    g.setColor(0.5, 0.9, 1, 1)
    local title = "SPLIT SCREEN CO-OP"
    g.print(title, screen_w / 2 - g.getFont():getWidth(title) * 1.5 / 2, screen_h / 2 - 200, 0, 1.5, 1.5)

    local bw, bh = 200, 150
    local gap    = 40
    local boxy   = screen_h / 2 - 150
    self:_draw_player_box(g, 1, screen_w / 2 - bw - gap / 2, boxy, bw, bh)
    self:_draw_player_box(g, 2, screen_w / 2 + gap / 2,      boxy, bw, bh)

    local ty = boxy + bh + 36
    g.setColor(1, 1, 1, 1)
    g.print(string.format("[G] God mode:     < %s >", coop.god and "ON" or "OFF"), screen_w / 2 - 120, ty)
    g.print(string.format("[F] Friendly fire: < %s >", coop.ff and "ON" or "OFF"), screen_w / 2 - 120, ty + 30)

    g.setColor(0.6, 0.6, 0.6, 1)
    local fy = ty + 78
    g.print("P1 (blue): A/D pick vehicle      P2 (orange): Left/Right pick vehicle", screen_w / 2 - 240, fy)
    g.print("G god mode      F friendly fire      SPACE start      Esc cancel", screen_w / 2 - 240, fy + 22)
    g.print("In game  P1: WASD + L-Shift/L-Ctrl/Q/E    P2: Arrows + R-Shift/R-Ctrl/Num0/NumEnter",
        screen_w / 2 - 240, fy + 46)
    g.setColor(1, 1, 1)
end

function CoopSetup:keypressed(key)
    local app  = self.app
    local coop = app.settings.coop
    if     key == "escape" then app.scenes:switch("overview")
    elseif key == "space"  then app.scenes:switch("coop_gameplay")
    elseif key == "g"      then coop.god = not coop.god
    elseif key == "f"      then coop.ff  = not coop.ff
    elseif key == P1_CONTROLS.left or key == P1_CONTROLS.right then self:_toggle_vehicle(1)
    elseif key == P2_CONTROLS.left or key == P2_CONTROLS.right then self:_toggle_vehicle(2)
    end
end

return CoopSetup
