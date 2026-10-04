-- Run with a standalone Lua interpreter: lua Tests\DBTests.lua <addon directory>
-- Covers Core\DB.lua: edit permissions, updatedAt, backups, restore, reset and guild-member names.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local client, last, backupCount = harness.client, harness.last, harness.backupCount
local test = harness.suite("Core\\DB.lua")

local p, f, none = client("Master"), client("Follower"), client("Nobody")
assert(p.ns.SelectMaster("Master") and f.ns.SelectMaster("Master"))

test("only the master edits, and only with finite numbers", function()
    assert(not none.ns.SetModifier("Master", 1) and last(none):find(none.ns.L.READ_ONLY, 1, true), "no master")
    assert(not f.ns.SetModifier("Follower", 1), "follower")
    assert(p.ns.SetModifier("Master", 12.5) and p.ns.SetModifier("FormerMember", -4))
    assert(not p.ns.SetModifier("Master", math.huge) and not p.ns.SetModifier("Master", 0 / 0))
    assert(p.ns.GetModifier("Master") == 12.5 and p.ns.GetPlayerModifier() == 12.5)
end)

test("only the master imports or restores", function()
    for _, c in ipairs({ f, none }) do
        local backup = c.ns.SaveBackup("manual")
        assert(not c.ns.ImportModifiers("{}") and last(c):find(c.ns.L.FOLLOWER_LOCKED, 1, true))
        assert(not c.ns.RestoreBackup(backup) and last(c):find(c.ns.L.FOLLOWER_LOCKED, 1, true))
    end
end)

test("only real edits bump updatedAt, strictly increasing", function()
    local stamp = p.ns.GetUpdatedAt()
    assert(stamp > 0)
    assert(p.ns.SetModifier("Master", 12.5) and p.ns.GetUpdatedAt() == stamp, "unchanged value")
    assert(p.ns.SetModifier("Master", 13) and p.ns.GetUpdatedAt() > stamp)
    stamp = p.ns.GetUpdatedAt()
    assert(p.ns.SetModifier("Master", 12.5) and p.ns.GetUpdatedAt() > stamp, "same server second")
end)

test("selecting a master never changes the age of the data", function()
    local solo = client("Solo")
    solo.roster = { "Solo", "Master" }
    solo.ns.db.sync.updatedAt = 42
    assert(solo.ns.SelectMaster("Solo") and solo.ns.GetUpdatedAt() == 42)
    assert(solo.ns.SelectMaster("Master") and solo.ns.GetUpdatedAt() == 42)
end)

test("backups are named copies with unique keys", function()
    local a, b = p.ns.SaveBackup("manual"), p.ns.SaveBackup("manual")
    local backup = p.ns.db.backups[a]
    assert(a ~= b and backup.name == "manual" and backup.updatedAt == p.ns.GetUpdatedAt())
    p.ns.db.modifiers.Master = 22
    assert(backup.modifiers.Master == 12.5)
    p.ns.db.modifiers.Master = 12.5
end)

test("restore backs up the current state and brings the backup's age", function()
    local target, stamp = p.ns.SaveBackup("manual"), p.ns.GetUpdatedAt()
    p.ns.db.modifiers.Master = 32 -- same age, different content
    local backups = backupCount(p)
    assert(p.ns.RestoreBackup(target) and p.ns.GetModifier("Master") == 12.5 and p.ns.GetUpdatedAt() == stamp)
    assert(backupCount(p) == backups + 1)
    for _, backup in pairs(p.ns.db.backups) do
        if backup.name == "restore" then assert(backup.modifiers.Master == 32) end
    end
end)

test("restoring an older backup is blocked until the data is reset", function()
    local target, old = p.ns.SaveBackup("manual"), p.ns.GetUpdatedAt()
    assert(p.ns.SetModifier("Master", 41))
    local backups = backupCount(p)
    assert(not p.ns.RestoreBackup(target) and last(p):find("Restore blocked", 1, true))
    assert(p.ns.GetModifier("Master") == 41 and backupCount(p) == backups)
    assert(p.ns.ResetData() and p.ns.RestoreBackup(target))
    assert(p.ns.GetModifier("Master") == 12.5 and p.ns.GetUpdatedAt() == old)
end)

test("reset backs up non-empty data, clears it and marks it oldest, also for followers", function()
    f.ns.db.modifiers, f.ns.db.sync.updatedAt = { Master = 3 }, 12345
    local backups = backupCount(f)
    assert(f.ns.ResetData() and next(f.ns.db.modifiers) == nil and f.ns.GetUpdatedAt() == 0)
    assert(backupCount(f) == backups + 1 and f.ns.db.sync.master == "Master")
    assert(f.ns.ResetData() and backupCount(f) == backups + 1, "an empty state is not backed up")
end)

test("only automatic backups are pruned, keeping the newest ones", function()
    local seconds = 0
    p.env.date = function() seconds = seconds + 1; return string.format("2026-10-04 12:00:%02d", seconds) end
    local manual, oldest = p.ns.SaveBackup("manual"), p.ns.SaveBackup("auto sync")
    for _ = 1, p.ns.MAX_AUTO_BACKUPS do p.ns.SaveBackup("auto sync") end
    local auto = 0
    for _, backup in pairs(p.ns.db.backups) do if backup.name == "auto sync" then auto = auto + 1 end end
    assert(auto == p.ns.MAX_AUTO_BACKUPS and p.ns.db.backups[manual] and not p.ns.db.backups[oldest])
end)

test("member names are resolved against the roster", function()
    f.roster = { "Twin-One", "Twin-Two", "Twin" }
    assert(f.ns.ResolveGuildMember("Twin") == "Twin", "an exact match beats ambiguous short names")
    f.roster = { "Twin-One", "Twin-Two" }
    assert(not f.ns.ResolveGuildMember("Twin"))
    f.roster = { "Solo Player" }
    assert(f.ns.ResolveGuildMember("Solo Player-Realm") == "Solo Player", "sender with a realm suffix")
    assert(not f.ns.ResolveGuildMember("Other Player"))
end)

test("realm-less 'First Last' names are valid; empty, overlong and escape names are not", function()
    assert(f.ns.IsValidMemberName("Andriod En"))
    for _, name in ipairs({ "", string.rep("a", 97), "bad|name", "tab\tname" }) do
        assert(not f.ns.IsValidMemberName(name), name)
    end
end)
