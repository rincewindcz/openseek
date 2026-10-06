-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

function love.conf(t)
    local os_name = rawget(love, "_os")
    t.identity = "openseek"   -- save directory for persisted high scores
    t.window.title = "openSEEK - Seek & Destroy"
    -- The Windows build carries the icon in its exe, in every size the shell
    -- asks for; a window icon would replace those with one scaled image.
    if os_name ~= "Windows" and os_name ~= "Web" then
        t.window.icon = "content/icon/openseek.png"
    end
    t.window.width = 1280
    t.window.height = 720
    -- In the browser the page scales the canvas; a resizable window would follow
    -- the CSS size instead and drop to the phone's CSS resolution.
    t.window.resizable = os_name ~= "Web"
    -- Android scales units by the display density (2-3x); the HUD and the
    -- post-processing shaders assume units are pixels.
    t.window.usedpiscale = false
    t.modules.physics = false
    t.modules.joystick = false
end
