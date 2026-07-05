function love.conf(t)
    t.identity = "openseek"   -- save directory for persisted high scores
    t.window.title = "Seek & Destroy level viewer"
    t.window.width = 1280
    t.window.height = 800
    t.window.resizable = true
    t.modules.physics = false
    t.modules.joystick = false
end
