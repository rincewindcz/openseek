local Class    = require "engine.core.class"
local Scene    = require "engine.core.scene"
local Font     = require "engine.core.font"
local Vehicles = require "engine.game.vehicles"

-- Shared base for the gameplay scenes (single player, sandbox, co-op split):
-- firing, weapon cycling, landing, the mission-won -> DESTRUCTION STATS
-- sequencing, and the in-game text overlays. Subclasses provide
-- collect_stats() for the stats screen.
local GameplayBase = Class(Scene)

-- Centered title in the game's bitmap body font (same as the score readout)
-- over a dimmed screen. No subtitle / key hints: game mode shows game-font
-- text only.
function GameplayBase:overlay_text(title, dim)
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, dim or 0.55)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    local font = Font.get("chars")
    local s    = 5
    font:print(title, (screen_w - font:width(title, s)) / 2,
        (screen_h - font.line_height * s) / 2, { scale = s })
    g.setColor(1, 1, 1)
end

-- Slow-blinking "MISSION COMPLETE / RETURN TO BASE" once every objective is
-- met and the player only has to fly home (mission state "return_to_base").
-- Uses the score font (CHARS), not the menu ENDCHARS face.
function GameplayBase:draw_return_prompt()
    if math.floor(love.timer.getTime() * 1.5) % 2 ~= 0 then return end
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    local font  = Font.get("chars")
    local s     = 4
    local lines = { "MISSION COMPLETE", "RETURN TO BASE" }
    local y     = screen_h / 2 - 70
    for _, ln in ipairs(lines) do
        font:print(ln, (screen_w - font:width(ln, s)) / 2, y, { scale = s })
        y = y + font.line_height * s + 10
    end
end

-- Fire p's current weapon if its reload is up and it has ammo. owner stays the
-- literal "player" so projectiles hit enemies (not the other player) regardless
-- of which of the two fired.
function GameplayBase:fire_for(p)
    local combat = self.app.combat
    local weapon_def = combat.weapons[p.weapon_name]
    if not weapon_def then return end
    if p.fire_timer > 0 then return end
    if not p:has_ammo(p.weapon_name) then return end
    local level = weapon_def.levels and weapon_def.levels[p.weapon_level] or weapon_def
    combat:tick_swing("player", p.weapon_name)
    combat:fire(p.x, p.y, p:fire_angle(), p.weapon_name, "player", p.weapon_level, nil, p)
    p:consume_ammo(p.weapon_name, weapon_def.ammo_cost or 1)
    p.fire_timer = 1.0 / (level.fire_rate or weapon_def.fire_rate or 10)
end

-- Cycle p's weapon to the next one valid for its vehicle.
function GameplayBase:cycle_weapon(p)
    local weapon_list = Vehicles.WEAPONS[p.vehicle] or {}
    if #weapon_list == 0 then return end
    local idx = 1
    for i, w in ipairs(weapon_list) do
        if w == p.weapon_name then idx = i; break end
    end
    p.weapon_name  = weapon_list[idx % #weapon_list + 1]
    p.weapon_level = 1
    p.fire_timer   = 0
end

-- Toggle a flyer between airborne and grounded; no-op for a tank.
function GameplayBase:toggle_land(p)
    if p.land_state == "airborne" then
        p:land()
    elseif p.land_state == "grounded" then
        p:take_off()
    end
end

-- Mission won: hold MISSION COMPLETE briefly, then start the DESTRUCTION
-- STATS screen from the subclass's collect_stats().
function GameplayBase:update_won(dt)
    local mission = self.mission
    if not (mission and mission.state == "won") then return end
    if self.won_timer == nil then self.won_timer = 1.5 end
    if self.won_timer > 0 then
        self.won_timer = self.won_timer - dt
    elseif not self.end_stats_started then
        self.app.end_stats:start(self:collect_stats())
        self.end_stats_started = true
    end
end

function GameplayBase:reset_end_stats()
    self.won_timer            = nil
    self.end_stats_started    = false
    self.app.end_stats.active = false
end

-- End-stats key handling: Esc dismisses immediately; otherwise the first key
-- snaps the tally, the next dismisses. Dismissing returns to the overview.
function GameplayBase:end_stats_keypressed(key)
    local end_stats = self.app.end_stats
    if key == "escape" then
        end_stats:keypressed()
        end_stats.active = false
        self.app.scenes:switch("overview")
    elseif end_stats:keypressed() and not end_stats:is_active() then
        self.app.scenes:switch("overview")
    end
end

-- Pointer release mirrors the keyboard: advance / dismiss the stats screen.
function GameplayBase:mousereleased(_x, _y)
    local end_stats = self.app.end_stats
    if end_stats:is_active() then
        if end_stats:keypressed() and not end_stats:is_active() then
            self.app.scenes:switch("overview")
        end
    end
end

function GameplayBase:wheelmoved(_dx, dy)
    local app = self.app
    if not app.renderer.picker and not app.renderer.kind_picker then
        app.camera:on_wheel(dy)
    end
end

return GameplayBase
