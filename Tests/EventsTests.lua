-- Run with a standalone Lua interpreter: lua Tests\EventsTests.lua <addon directory>
-- Covers Core\Events.lua: event registration and handler wiring.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local client = harness.client
local test = harness.suite("Core\\Events.lua")

local f = client("Follower")
local events

test("ADDON_LOADED registers the addon and guild events", function()
    f.load("Core\\Events.lua")
    events = f.frames[#f.frames]
    events.scripts.OnEvent(events, "ADDON_LOADED", "Rollover")
    assert(events.events.CHAT_MSG_ADDON and events.events.PLAYER_GUILD_UPDATE)
end)

test("GUILD_ROSTER_UPDATE is handled while the main window is closed", function()
    events.scripts.OnEvent(events, "GUILD_ROSTER_UPDATE")
end)
