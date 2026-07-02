-- LOVE 11.x runs LuaJIT (Lua 5.1 plus extensions).
std = "luajit+love"

-- Column-aligned assignment blocks are intentional; no line-length lint.
max_line_length = false

-- Draw helpers stay methods for symmetry even when they ignore self.
self = false

-- An underscore prefix marks a deliberately unused local/argument.
ignore = { "21./_.*" }

exclude_files = { "lib/" }
