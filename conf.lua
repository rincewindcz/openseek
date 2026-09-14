function love.conf(t)
    t.identity = "openseek"   -- save directory for persisted high scores
    t.window.title = "openSEEK - Seek & Destroy"
    t.window.width = 1280
    t.window.height = 720
    -- In the browser the page scales the canvas; a resizable window would follow
    -- the CSS size instead and drop to the phone's CSS resolution.
    t.window.resizable = rawget(love, "_os") ~= "Web"
    t.modules.physics = false
    t.modules.joystick = false
end
