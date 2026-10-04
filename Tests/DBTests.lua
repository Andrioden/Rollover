-- Run with a standalone Lua interpreter: lua Tests\DBTests.lua <addon directory>
-- Covers Core\DB.lua: modifiers, backups, master selection, edit permissions and guild-member names.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client, last = harness.advance, harness.client, harness.last
local test = harness.suite("Core\\DB.lua")

local p, f = client("Master"), client("Follower")

test("modifiers reject non-finite values", function()
    assert(p.ns.SetModifier("Master", 12.5))
    assert(p.ns.SetModifier("FormerMember", -4))
    assert(not p.ns.SetModifier("Master", math.huge))
    assert(p.ns.GetModifier("Master") == 12.5)
end)

test("backups are independent copies and restorable", function()
    local backup1, backup2 = p.ns.SaveBackup(), p.ns.SaveBackup()
    assert(backup1 ~= backup2)
    local stamp = p.ns.GetUpdatedAt()
    assert(p.ns.db.backups[backup1].updatedAt == stamp and p.ns.db.backups[backup1].modifiers.Master == 12.5)
    p.ns.db.modifiers.Master = 22
    assert(p.ns.db.backups[backup1].modifiers.Master == 12.5)
    assert(p.ns.RestoreBackup(backup1) and p.ns.GetPlayerModifier() == 12.5, "a backup as new as the data restores")
    assert(p.ns.GetUpdatedAt() == stamp)
end)

test("master can edit locally without announcing", function()
    assert(p.ns.SelectMaster("Master"))
    assert(last(p):find(p.ns.L.LOCAL_MASTER, 1, true))
    local printsBeforeEdit = #p.prints
    assert(p.ns.SetModifier("Master", 12.5) and #p.prints == printsBeforeEdit)
    assert(p.ns.GetSyncStatus == nil and p.ns.RefreshSyncControls == nil and p.ns.OnModifierStateChanged == nil)
end)

test("follower cannot edit modifiers", function()
    assert(f.ns.SelectMaster("Master"))
    assert(last(f):find(string.format(f.ns.L.MASTER_OFFLINE, "Master"), 1, true))
    for _, line in ipairs(f.prints) do assert(not line:find(f.ns.L.LOCAL_MASTER, 1, true)) end
    assert(not f.ns.SetModifier("Follower", 99))
end)

test("only real edits bump updatedAt; restore and import keep the age of their data", function()
    local stamp = p.ns.db.sync.updatedAt
    assert(stamp)
    assert(p.ns.SetModifier("Master", 12.5) and p.ns.db.sync.updatedAt == stamp)
    assert(p.ns.SetModifier("Master", 13) and p.ns.db.sync.updatedAt > stamp)
    stamp = p.ns.db.sync.updatedAt
    assert(p.ns.SetModifier("Master", 14) and p.ns.db.sync.updatedAt > stamp) -- same server second
    stamp = p.ns.db.sync.updatedAt
    assert(p.ns.RestoreBackup(p.ns.SaveBackup()) and p.ns.db.sync.updatedAt == stamp)
    advance(10) -- rapid test edits pushed the stamp past the server clock; imports may not be from the future
    local json = '{"updatedAt":' .. stamp .. ',"modifiers":{"Master":7,"ZeroMember":0}}'
    assert(p.ns.ImportModifiers(json) and p.ns.db.sync.updatedAt == stamp)
    json = '{"updatedAt":' .. (stamp + 1) .. ',"modifiers":{"Master":8}}'
    assert(p.ns.ImportModifiers(json) and p.ns.db.sync.updatedAt == stamp + 1, "an import brings its own age")
end)

test("restoring an older backup is blocked until the data is reset", function()
    local target = p.ns.SaveBackup()
    local old = p.ns.GetUpdatedAt()
    assert(p.ns.SetModifier("Master", 41) and p.ns.GetUpdatedAt() > old)
    local backups, stamp = 0, p.ns.GetUpdatedAt()
    for _ in pairs(p.ns.db.backups) do backups = backups + 1 end
    assert(not p.ns.RestoreBackup(target) and last(p):find("Restore blocked", 1, true))
    local after = 0
    for _ in pairs(p.ns.db.backups) do after = after + 1 end
    assert(p.ns.GetModifier("Master") == 41 and p.ns.GetUpdatedAt() == stamp and after == backups)
    assert(p.ns.ResetData() and p.ns.RestoreBackup(target))
    assert(p.ns.GetModifier("Master") == 8 and p.ns.GetUpdatedAt() == old, "the backup brings its own age")
end)

test("legacy or malformed backups are refused", function()
    p.ns.db.backups["legacy"] = { Master = 1 }
    assert(not p.ns.RestoreBackup("legacy") and last(p):find("unknown format", 1, true))
    p.ns.db.backups["legacy"] = nil
end)

test("restoring a backup saves the current state as a new backup first", function()
    assert(p.ns.SetModifier("Master", 31))
    local before = {}
    for key in pairs(p.ns.db.backups) do before[key] = true end
    local target = p.ns.SaveBackup()
    p.ns.db.modifiers.Master = 32 -- same age, different content
    assert(p.ns.RestoreBackup(target))
    local added
    for key, backup in pairs(p.ns.db.backups) do
        if not before[key] and key ~= target and backup.modifiers.Master == 32 then added = key end
    end
    assert(added and p.ns.GetModifier("Master") == 31, "the pre-restore state must be kept")
end)

test("reset data blanks everything, backs it up and marks the data oldest", function()
    local own = client("Resetter")
    own.roster = { "Resetter", "Master" }
    assert(own.ns.SelectMaster("Resetter") and own.ns.SetModifier("Master", 8))
    local backups = 0
    for _ in pairs(own.ns.db.backups) do backups = backups + 1 end
    assert(own.ns.ResetData())
    local after = 0
    for _, backup in pairs(own.ns.db.backups) do after = after + 1; assert(backup.modifiers.Master == 8) end
    assert(after == backups + 1 and next(own.ns.db.modifiers) == nil and own.ns.db.sync.updatedAt == 0)
    assert(own.ns.ResetData() and #own.prints > 0)
    local again = 0
    for _ in pairs(own.ns.db.backups) do again = again + 1 end
    assert(again == after, "an empty state is not backed up")
end)

test("reset data works for followers", function()
    f.ns.db.modifiers = { Master = 3 }
    f.ns.db.sync.updatedAt = 12345
    assert(f.ns.ResetData() and next(f.ns.db.modifiers) == nil and f.ns.db.sync.updatedAt == 0)
    assert(f.ns.db.sync.master == "Master", "reset keeps the selected master")
end)

test("selecting a master never changes the age of the data", function()
    local own = client("Solo")
    own.roster = { "Solo", "Master" }
    assert(own.ns.db.sync.updatedAt == nil and own.ns.GetUpdatedAt() == 0)
    assert(own.ns.SelectMaster("Solo") and own.ns.db.sync.updatedAt == nil, "becoming master is not an edit")
    assert(own.ns.SetModifier("Master", 2) and own.ns.db.sync.updatedAt > 0)
    own.ns.db.sync.updatedAt = 42
    assert(own.ns.SelectMaster("Master") and own.ns.db.sync.updatedAt == 42)
    assert(own.ns.SelectMaster("Solo") and own.ns.db.sync.updatedAt == 42)
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
