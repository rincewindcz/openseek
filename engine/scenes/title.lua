-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Scene  = require "engine.core.scene"
local Config = require "engine.core.config"

-- Boot scene: the TITLE card fading in over black, preceded by the short
-- openSEEK engine card while Config.engine_intro is on. Draws an opaque fill
-- every frame so the overview never flashes during the intro; done, Esc, Enter
-- or Space drops into the main menu (Enter / Space on the engine card skip only
-- to the TITLE card).
local Title = Class(Scene)

Title.ENGINE_INTRO = "content/intro/openseek_intro.png"

function Title:enter()
    local app = self.app
    local function to_menu() app.scenes:switch("main_menu") end
    local function show_title()
        app.screen:show("TITLE", {
            fade_in   = 0.6,
            hold      = 2.0,
            fade_out  = 0.6,
            tag       = "OPENSEEK 0.9",
            skippable = true,
            on_done   = to_menu,
            on_cancel = to_menu,
        })
    end
    -- EXTRA (engine_intro): shown on the first launch only, then switched off;
    -- the EXTRAS page turns it back on.
    if not Config.engine_intro then
        show_title()
        return
    end
    Config.engine_intro = false
    Config.save()
    app.screen:show(Title.ENGINE_INTRO, {
        fade_in   = 0.25,
        hold      = 0.8,
        fade_out  = 0.25,
        skippable = true,
        on_done   = show_title,
        on_cancel = show_title,
    })
end

function Title:draw()
    local g = love.graphics
    local screen_w, screen_h = g.getDimensions()
    g.setColor(0, 0, 0, 1)
    g.rectangle("fill", 0, 0, screen_w, screen_h)
    g.setColor(1, 1, 1)
end

return Title
