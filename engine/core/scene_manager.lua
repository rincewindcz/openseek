-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Michal Genserek

local Class = require "engine.core.class"
local Log   = require "engine.core.log"

-- Stack-based scene manager. Scenes register under a name and address each
-- other by name, which avoids scene-to-scene require cycles. Only the top
-- scene receives update/draw/input via dispatch; there is no draw-through.
local SceneManager = Class()

function SceneManager:init()
    self.registry = {}
    self.names    = {}   -- scene -> registered name, for the log
    self.stack    = {}
end

function SceneManager:register(name, scene)
    self.registry[name] = scene
    self.names[scene]   = name
end

function SceneManager:_get(name)
    return assert(self.registry[name], "unknown scene: " .. tostring(name))
end

function SceneManager:get(name)
    return self:_get(name)
end

function SceneManager:top()
    return self.stack[#self.stack]
end

function SceneManager:depth()
    return #self.stack
end

-- Leave every stacked scene (top-down), then enter `name` as the only scene.
function SceneManager:switch(name, ...)
    local scene = self:_get(name)
    Log.info("scene", "switch to %s", name)
    for i = #self.stack, 1, -1 do
        self.stack[i]:leave()
        self.stack[i] = nil
    end
    self.stack[1] = scene
    scene:enter(...)
end

-- Suspend the current top and enter `name` above it (pop returns below).
function SceneManager:push(name, ...)
    local scene = self:_get(name)
    local top = self:top()
    Log.info("scene", "push %s over %s", name, self.names[top] or "nothing")
    if top then top:suspend() end
    self.stack[#self.stack + 1] = scene
    scene:enter(...)
end

-- Leave the top scene and resume the one below.
function SceneManager:pop(...)
    local top = table.remove(self.stack)
    if top then top:leave() end
    local new_top = self:top()
    Log.info("scene", "pop %s, resume %s", self.names[top] or "nothing", self.names[new_top] or "nothing")
    if new_top then new_top:resume(...) end
end

-- Leave the top scene and enter `name` in its place, without resuming the
-- scene below (a suspended game stays suspended across menu <-> picker hops).
function SceneManager:replace(name, ...)
    local scene = self:_get(name)
    local top = table.remove(self.stack)
    Log.info("scene", "replace %s with %s", self.names[top] or "nothing", name)
    if top then top:leave() end
    self.stack[#self.stack + 1] = scene
    scene:enter(...)
end

-- Forward an event to the top scene only.
function SceneManager:dispatch(event, ...)
    local top = self:top()
    if not top then return end
    return top[event](top, ...)
end

return SceneManager
