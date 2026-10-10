-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class  = require "engine.core.class"
local Scene  = require "engine.core.scene"
local Audio  = require "engine.core.audio"
local Config = require "engine.core.config"
local Sound  = require "engine.game.sound"

-- Boot scene: the TITLE card fading in over black, preceded by the short
-- openSEEK engine card on the first launch or while Config.engine_intro is on. Draws an opaque fill
-- every frame so the overview never flashes during the intro; done, Esc, Enter
-- or Space drops into the main menu (Enter / Space on the engine card skip only
-- to the TITLE card), or into the style selection screen until the player has
-- confirmed it once. The menu music starts here, at boot, as in the original;
-- behind the engine card's riff the mixer holds it back. The riff outlasts its
-- card and rings on over the TITLE card; skipping either card fades it out.
local Title = Class(Scene)

Title.ENGINE_INTRO       = "content/intro/openseek_intro.png"
Title.ENGINE_INTRO_MUSIC = "content/intro/openseek_intro.ogg"

local INTRO_FADE_IN   = 0.25
local INTRO_HOLD      = 0.8   -- without the riff (muted, music volume at zero)
local INTRO_HOLD_RIFF = 2.5
local INTRO_FADE_OUT  = 0.25

function Title:enter()
    local app = self.app
    local function to_menu()
        app.scenes:switch(Config.style_chosen and "main_menu" or "style_select")
    end
    local function skip_to_menu()
        Audio.stop_jingle()
        to_menu()
    end
    local function show_title()
        app.screen:show("TITLE", {
            fade_in   = 0.6,
            hold      = 2.0,
            fade_out  = 0.6,
            build_tag = true,
            skippable = true,
            on_done   = to_menu,
            on_cancel = skip_to_menu,
        })
    end
    -- EXTRA (engine_intro): always shown on the first launch, which also saves the
    -- settings so the next launch is not a first one; on every launch while the
    -- EXTRAS page has it on.
    local first = Config.first_launch
    if first then
        Config.first_launch = false
        Config.save()
    end
    local intro = first or Config.engine_intro
    local riff  = intro and Audio.play_jingle(Title.ENGINE_INTRO_MUSIC)
    Sound.play_music("menu")
    if not intro then
        show_title()
        return
    end
    app.screen:show(Title.ENGINE_INTRO, {
        fade_in   = INTRO_FADE_IN,
        hold      = riff and INTRO_HOLD_RIFF or INTRO_HOLD,
        fade_out  = INTRO_FADE_OUT,
        skippable = true,
        on_done   = show_title,
        on_cancel = function()
            Audio.stop_jingle()
            show_title()
        end,
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
