-- Shared design space and letterbox transform for the non-game UI screens.
-- Menus lay out in the original 320x240 screen space and scale to the window.
local Layout = {}

Layout.DESIGN_W = 320
Layout.DESIGN_H = 240

-- Letterbox fit of the design canvas into the window. Returns the uniform
-- scale and the x/y offset that centers the scaled canvas.
function Layout.fit(screen_w, screen_h, design_w, design_h)
    design_w = design_w or Layout.DESIGN_W
    design_h = design_h or Layout.DESIGN_H
    local scale = math.min(screen_w / design_w, screen_h / design_h)
    return scale,
        (screen_w - design_w * scale) / 2,
        (screen_h - design_h * scale) / 2
end

return Layout
