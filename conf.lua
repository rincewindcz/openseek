-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

function love.conf(t)
    local os_name = rawget(love, "_os")
    t.identity = "openseek"   -- save directory for persisted high scores
    t.window.title = "openSEEK - Seek & Destroy"
    -- The Windows build carries the icon in its exe and the macOS app in its
    -- bundle, in every size the shell asks for; a window icon would replace
    -- those with one scaled image.
    local own_icon = os_name == "Windows" or (os_name == "OS X" and love.filesystem.isFused())
    if not own_icon and os_name ~= "Web" then
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
    -- LOVE 12 (which alone has t.graphics) would pick Metal or Vulkan first;
    -- OpenGL is what every build of the game is tested on. The list is a
    -- filter, LOVE keeps its own order, so the others have to stay off it.
    if t.graphics then
        t.graphics.renderers = { "opengl" }
    end
end
