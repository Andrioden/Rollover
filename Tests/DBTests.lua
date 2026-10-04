-- Run with a standalone Lua interpreter: lua Tests\DBTests.lua <addon directory>
-- Covers Core\DB.lua: modifiers, backups, publisher selection, edit permissions and guild-member names.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local client, last = harness.client, harness.last
local test = harness.suite("Core\\DB.lua")

local p, f = client("Publisher"), client("Follower")

test("modifiers reject non-finite values", function()
    assert(p.ns.SetModifier("Publisher", 12.5))
    assert(p.ns.SetModifier("FormerMember", -4))
    assert(not p.ns.SetModifier("Publisher", math.huge))
    assert(p.ns.GetModifier("Publisher") == 12.5)
end)

test("backups are independent copies and restorable", function()
    local backup1, backup2 = p.ns.SaveBackup(), p.ns.SaveBackup()
    assert(backup1 ~= backup2)
    p.ns.SetModifier("Publisher", 22)
    assert(p.ns.db.backups[backup1].Publisher == 12.5)
    assert(p.ns.RestoreBackup(backup1) and p.ns.GetPlayerModifier() == 12.5)
end)

test("publisher can edit locally without announcing", function()
    assert(p.ns.SelectPublisher("Publisher"))
    assert(last(p):find(p.ns.L.LOCAL_PUBLISHER, 1, true))
    local printsBeforeEdit = #p.prints
    assert(p.ns.SetModifier("Publisher", 12.5) and #p.prints == printsBeforeEdit)
    assert(p.ns.GetSyncStatus == nil and p.ns.RefreshSyncControls == nil and p.ns.OnModifierStateChanged == nil)
end)

test("follower cannot edit modifiers", function()
    assert(f.ns.SelectPublisher("Publisher"))
    assert(last(f):find(string.format(f.ns.L.PUBLISHER_OFFLINE, "Publisher"), 1, true))
    for _, line in ipairs(f.prints) do assert(not line:find(f.ns.L.LOCAL_PUBLISHER, 1, true)) end
    assert(not f.ns.SetModifier("Follower", 99))
end)

test("every change bumps updatedAt upward; unchanged edits do not", function()
    local stamp = p.ns.db.sync.updatedAt
    assert(stamp)
    assert(p.ns.SetModifier("Publisher", 12.5) and p.ns.db.sync.updatedAt == stamp)
    assert(p.ns.SetModifier("Publisher", 13) and p.ns.db.sync.updatedAt > stamp)
    stamp = p.ns.db.sync.updatedAt
    assert(p.ns.SetModifier("Publisher", 14) and p.ns.db.sync.updatedAt > stamp) -- same server second
    stamp = p.ns.db.sync.updatedAt
    assert(p.ns.RestoreBackup(p.ns.SaveBackup()) and p.ns.db.sync.updatedAt > stamp)
    stamp = p.ns.db.sync.updatedAt
    assert(p.ns.ImportModifiers('{"Publisher":7,"ZeroMember":0}') and p.ns.db.sync.updatedAt > stamp)
end)

test("becoming publisher starts a timestamp and clears it for a new source", function()
    local own = client("Solo")
    own.roster = { "Solo", "Publisher" }
    assert(own.ns.db.sync.updatedAt == nil)
    assert(own.ns.SelectPublisher("Solo") and own.ns.db.sync.updatedAt)
    own.ns.db.sync.updatedAt = 42
    assert(own.ns.SelectPublisher("Publisher") and own.ns.db.sync.updatedAt == nil)
end)

test("followers cannot import or restore", function()
    local backup = f.ns.SaveBackup()
    assert(not f.ns.ImportModifiers("{}") and last(f):find(f.ns.L.FOLLOWER_LOCKED, 1, true))
    assert(not f.ns.RestoreBackup(backup) and last(f):find(f.ns.L.FOLLOWER_LOCKED, 1, true))
end)

test("only automatic backups are pruned, keeping the newest ones", function()
    local seconds = 0
    p.env.date = function() seconds = seconds + 1; return string.format("2026-10-04 12:00:%02d", seconds) end
    local manual = p.ns.SaveBackup()
    local first = p.ns.SaveBackup(true)
    for _ = 1, p.ns.MAX_AUTO_BACKUPS do p.ns.SaveBackup(true) end
    local autoCount = 0
    for key in pairs(p.ns.db.backups) do if key:find("(auto)", 1, true) then autoCount = autoCount + 1 end end
    assert(autoCount == p.ns.MAX_AUTO_BACKUPS)
    assert(p.ns.db.backups[manual] and not p.ns.db.backups[first])
end)

test("modifier state is limited to ns.MAX_MEMBERS entries", function()
    local large = {}
    for i = 1, 1001 do large["Member" .. i] = 0 end
    assert(not f.ns.ValidateModifierState(large))
    large.Member1001 = nil
    assert(f.ns.ValidateModifierState(large))
end)

test("member names are resolved against the roster", function()
    f.roster = { "Twin-One", "Twin-Two", "Twin" }
    assert(f.ns.ResolveGuildMember("Twin") == "Twin") -- an exact match beats ambiguous short names
    f.roster = { "Twin-One", "Twin-Two" }
    assert(not f.ns.ResolveGuildMember("Twin"))
    f.roster = { "Solo Player" }
    assert(f.ns.ResolveGuildMember("Solo Player-Realm") == "Solo Player") -- sender with a realm suffix
    assert(not f.ns.ResolveGuildMember("Other Player"))
end)

test("realm-less 'First Last' names are valid", function()
    assert(f.ns.IsValidMemberName("Andriod En") and not f.ns.IsValidMemberName(""))
    assert(not f.ns.IsValidMemberName("bad|name"))
end)
