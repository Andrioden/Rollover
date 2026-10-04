-- Run with a standalone Lua interpreter: lua Tests\SyncTests.lua <addon directory>
-- Covers a real master and followers talking over the mocked client: manual syncs end to end, recovery from
-- lockdown and throttling, realm-less names, large rosters and the rules that data only moves forward.
-- Single-sided behavior lives in SyncClientTests.lua and SyncMasterTests.lua, automatic checks in SyncAutoTests.lua.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local count, last, printedSince = harness.count, harness.last, harness.printedSince
local delivered, requestSync = harness.delivered, harness.requestSync
local backupCount, login, messagesFrom = harness.backupCount, harness.login, harness.messagesFrom
local test = harness.suite("Sync master and follower together")

local p, f = client("Master"), client("Follower")
assert(p.ns.SelectMaster("Master") and p.ns.SetModifier("Master", 12.5) and p.ns.SetModifier("FormerMember", -4))
assert(f.ns.SelectMaster("Master"))
f.online.Master = true

test("a manual sync streams modifiers and roster zeros, printing progress but no names", function()
    local mark = #f.prints
    f.ns.db.modifiers = { OldMember = 42 }
    assert(requestSync(f))
    advance(0.1)
    assert(f.ns.IsSyncPending() and f.ns.GetModifier("OldMember") == 42, "untouched until the stream completes")
    advance(1)
    assert(not f.ns.IsSyncPending())
    local output = printedSince(f, mark)
    for _, line in ipairs({ "Requesting modifiers from Master", "Receiving 5 modifiers from Master", "Received 5/5",
        "Synced 5 modifiers from Master" }) do
        assert(output:find(line, 1, true), line)
    end
    assert(not output:find("FormerMember", 1, true))
    assert(f.ns.GetModifier("Master") == 12.5 and f.ns.GetModifier("FormerMember") == -4)
    assert(f.ns.db.modifiers.ZeroMember == 0 and f.ns.GetModifier("OldMember") == 0)
    assert(f.ns.GetUpdatedAt() == p.ns.GetUpdatedAt())
    advance(35)
end)

test("lockdown defers the request and retries with a single notice", function()
    f.result = 11
    assert(requestSync(f))
    advance(14)
    assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == 1)
    f.result = 0
    advance(20)
    assert(not f.ns.IsSyncPending() and last(f):find("Synced", 1, true))
    advance(35)
end)

test("throttle retries silently", function()
    f.result = 3
    local deferred = count(f, f.ns.L.DEFERRED)
    assert(requestSync(f))
    advance(2)
    assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == deferred)
    f.result = 0
    advance(20)
    assert(not f.ns.IsSyncPending() and last(f):find("Synced", 1, true))
end)

test("realm-less 'First Last' names sync", function()
    local rp, rf = client("Andriod En"), client("Other Player")
    for _, c in ipairs({ rp, rf }) do c.roster = { "Andriod En", "Other Player", "Third Guy" } end
    assert(rp.ns.SelectMaster("Andriod En") and rp.ns.SetModifier("Andriod En", 220) and rp.ns.SetModifier("Other Player", -3))
    assert(rf.ns.SelectMaster("Andriod En"))
    rf.online["Andriod En"], rp.online["Other Player"] = true, true
    assert(requestSync(rf))
    advance(20)
    assert(last(rf):find("Synced 3 modifiers from Andriod En", 1, true))
    assert(rf.ns.GetModifier("Andriod En") == 220 and rf.ns.GetPlayerModifier() == -3 and rf.ns.db.modifiers["Third Guy"] == 0)
end)

test("large rosters arrive over several VALUE messages", function()
    local bp, bf = client("Big Master"), client("Big Follower")
    local roster = { "Big Master", "Big Follower" }
    for i = 1, 98 do roster[#roster + 1] = string.format("Guild Member Number %03d", i) end
    bp.roster, bf.roster = roster, roster
    assert(bp.ns.SelectMaster("Big Master") and bf.ns.SelectMaster("Big Master"))
    bf.online["Big Master"] = true
    for i = 3, #roster do assert(bp.ns.SetModifier(roster[i], i * 1.5)) end
    local mark = #delivered
    assert(requestSync(bf))
    advance(10)
    assert(#messagesFrom("Big Master", "VALUE", mark) > 1)
    assert(last(bf):find("Synced 100 modifiers from Big Master", 1, true) and bf.ns.GetModifier(roster[100]) == 150)
end)

test("a repeated manual sync reports up to date instead of failing as busy", function()
    advance(1)
    local mark = #delivered
    assert(f.ns.RequestSync())
    advance(2)
    assert(not f.ns.IsSyncPending() and last(f):find("Already up to date with Master", 1, true))
    assert(#messagesFrom("Master", "CURRENT", mark) == 1)
end)

test("a second changed sync inside the rate limit explains the wait", function()
    local second = client("Second")
    second.online.Master, p.online.Second = true, true
    p.roster, second.roster = { "Master", "Follower", "Second" }, { "Master", "Follower", "Second" }
    assert(second.ns.SelectMaster("Master"))
    advance(3)
    assert(p.ns.SetModifier("Master", 6) and second.ns.RequestSync())
    advance(3)
    assert(not second.ns.IsSyncPending() and last(second):find(second.ns.L.MASTER_BUSY, 1, true))
    p.roster = { "Master", "Follower", "ZeroMember", "ThirdMember" }
end)

local old, new = client("Oldie"), client("Newbie")

test("a follower refuses a master with older data before touching anything", function()
    advance(61)
    old.roster, new.roster = { "Oldie", "Newbie" }, { "Oldie", "Newbie" }
    old.online.Newbie, new.online.Oldie = true, true
    assert(old.ns.SelectMaster("Oldie") and old.ns.SetModifier("Oldie", 1))
    new.ns.db.modifiers = { Oldie = 77 }
    new.ns.db.sync.updatedAt = old.ns.GetUpdatedAt() + 100
    local backups = backupCount(new)
    assert(new.ns.SelectMaster("Oldie"))
    advance(3)
    assert(#messagesFrom("Oldie", "BEGIN") == 1, "the master streams; the follower refuses")
    assert(not new.ns.IsSyncPending() and new.ns.GetModifier("Oldie") == 77 and backupCount(new) == backups)
    assert(new.ns.GetUpdatedAt() == old.ns.GetUpdatedAt() + 100 and last(new):find("Oldie has older modifiers", 1, true))
end)

test("announcements older than the local data are ignored", function()
    advance(61)
    local mark = #delivered
    new.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-1\t" .. old.ns.GetUpdatedAt(), "GUILD", "Oldie")
    advance(30)
    assert(#messagesFrom("Newbie", "REQUEST", mark) == 0)
end)

test("automatic checks report an older master once per stamp, manual syncs always", function()
    advance(61)
    local mark = #new.prints
    login(new)
    advance(5)
    assert(#new.prints == mark and new.ns.GetModifier("Oldie") == 77)
    advance(61)
    assert(new.ns.RequestSync())
    advance(3)
    assert(printedSince(new, mark):find("has older modifiers", 1, true))
end)

test("reset data lets a follower take the older master's data", function()
    advance(61)
    assert(new.ns.ResetData() and new.ns.RequestSync())
    advance(3)
    assert(new.ns.GetModifier("Oldie") == 1 and new.ns.GetUpdatedAt() == old.ns.GetUpdatedAt())
end)

test("a master with the same updatedAt never replaces local data", function()
    advance(61)
    new.ns.db.modifiers.Oldie = 5 -- diverged content under an equal stamp
    local mark = #delivered
    assert(new.ns.RequestSync())
    advance(3)
    assert(#messagesFrom("Oldie", "CURRENT", mark) == 1 and #messagesFrom("Oldie", "BEGIN", mark) == 0)
    assert(new.ns.GetModifier("Oldie") == 5)
end)

test("a fresh master with no data cannot overwrite followers", function()
    advance(61)
    local blank, other = client("Blank"), client("Other")
    blank.roster, other.roster = { "Blank", "Other" }, { "Blank", "Other" }
    blank.online.Other, other.online.Blank = true, true
    assert(blank.ns.SelectMaster("Blank") and blank.ns.GetUpdatedAt() == 0)
    other.ns.db.modifiers = { Blank = 5 }
    other.ns.db.sync.updatedAt = 1800000005
    assert(other.ns.SelectMaster("Blank"))
    advance(3)
    assert(#messagesFrom("Blank", "BEGIN") == 1 and not other.ns.IsSyncPending())
    assert(other.ns.GetModifier("Blank") == 5 and other.ns.GetUpdatedAt() == 1800000005)
end)
