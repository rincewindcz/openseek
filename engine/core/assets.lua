-- Asset path resolution across the engine's two asset roots.
--
--   content/...       engine-owned artwork, tracked in git and shipped with the
--                     engine. Original work, no bytes from the original game.
--   everything else   the pack decoded from the user's own copy of the game by
--                     tools/ (assets/), which is not distributable.
--
-- Data-driven paths (data/hud.json, data/animations.json, ...) name the root
-- explicitly, so a path's provenance is readable where it is declared:
--
--   "content/hud/player_f00.png"   shipped
--   "hud/armour_f00.png"           from the pack
--
-- Loaders take the JSON path and go through Assets.path / Assets.exists rather
-- than concatenating "assets/" themselves.

local Assets = {}

local PACK    = "assets/"
local CONTENT = "content/"

function Assets.path(p)
    if p:sub(1, #CONTENT) == CONTENT then return p end
    return PACK .. p
end

function Assets.exists(p)
    return love.filesystem.getInfo(Assets.path(p)) ~= nil
end

return Assets
