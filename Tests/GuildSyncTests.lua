-- Run with a standalone Lua interpreter: lua Tests\GuildSyncTests.lua <addon directory>
-- Covers Modules\GuildSync.lua: publisher streaming over WHISPER, validation, retries and failure reporting.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local count, last, printedSince = harness.count, harness.last, harness.printedSince
local delivered, secret, requestSync = harness.delivered, harness.secret, harness.requestSync
local test = harness.suite("Modules\\GuildSync.lua")

local p, f = client("Publisher"), client("Follower")
assert(p.ns.SetModifier("Publisher", 12.5) and p.ns.SetModifier("FormerMember", -4))
assert(p.ns.SelectPublisher("Publisher") and f.ns.SelectPublisher("Publisher"))

test("streams modifiers and missing roster zeros, with progress output", function()
    local syncMark, publisherMark = #f.prints, #p.prints
    f.ns.db.modifiers = { OldMember = 42 }
    assert(requestSync(f))
    advance(0.1)
    assert(f.ns.IsSyncPending() and f.ns.GetModifier("OldMember") == 0)
    assert(f.ns.GetModifier("Follower") == 0)
    assert(printedSince(p, publisherMark):find("Follower requested a sync; sending 5 modifiers.", 1, true))
    advance(1)
    assert(not f.ns.IsSyncPending())
    local output = printedSince(f, syncMark)
    -- All five entries fit in one VALUE message and are listed together.
    assert(output:find("Synced 5/5: Follower (0), FormerMember (-4), Publisher (+12.5), ThirdMember (0), ZeroMember (0)", 1, true))
    assert(output:find("Requesting modifiers from Publisher", 1, true))
    assert(output:find("Receiving 5 modifiers from Publisher", 1, true))
    assert(output:find("Synced 5 modifiers from Publisher", 1, true))
    assert(not output:find("Sync failed", 1, true))
    assert(f.ns.GetModifier("Publisher") == 12.5 and f.ns.GetModifier("FormerMember") == -4)
    assert(f.ns.db.modifiers.ZeroMember == 0)
    advance(35)
end)

test("sync keeps a pre-sync backup that can be restored", function()
    f.ns.db.modifiers = { OldMember = 43 }
    local function findBackup()
        for key, state in pairs(f.ns.db.backups) do if state.OldMember == 43 then return key end end
    end
    assert(requestSync(f))
    assert(not findBackup()) -- taken when the stream begins, not when the request is sent
    advance(1.1)
    local before = findBackup()
    assert(before and not before:find("(auto)", 1, true))
    assert(not f.ns.IsSyncPending() and f.ns.GetModifier("OldMember") == 0)
    assert(not f.ns.RestoreBackup(before) and f.ns.GetModifier("OldMember") == 0) -- followers cannot restore
    advance(35)
end)

test("import, restore and source changes are blocked while receiving", function()
    assert(requestSync(f))
    assert(not f.ns.ImportModifiers("{}") and not f.ns.SelectPublisher("Follower"))
    f.ns.CancelSync()
    advance(35)
end)

test("protocol guards reject spoofed, secret and mismatched messages", function()
    f.ns.db.modifiers = { OldMember = 42 }
    local id = requestSync(f)
    assert(id)
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t1\t5", "WHISPER", "ThirdMember")
    f.ns.OnSyncMessage("Rollover", secret, "WHISPER", "Publisher")
    f.ns.OnSyncMessage("Rollover", "BEGIN\twrong\t1\t5", "WHISPER", "Publisher")
    assert(f.ns.GetModifier("OldMember") == 42)
    f.ns.CancelSync()
    advance(35)
end)

test("incomplete transfer ends with a 'may be incomplete' warning", function()
    f.ns.db.modifiers = { OldMember = 42 }
    local id = requestSync(f)
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t2\t5", "WHISPER", "Publisher")
    f.ns.OnSyncMessage("Rollover", "VALUE\t" .. id .. "\t1\tPublisher\t-7", "WHISPER", "Publisher")
    assert(f.ns.GetModifier("Publisher") == -7)
    f.ns.OnSyncMessage("Rollover", "END\t" .. id .. "\t2", "WHISPER", "Publisher")
    assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Publisher") == -7)
    assert(last(f):find("may be incomplete", 1, true))
    advance(35)
end)

test("lockdown defers the request and retries with a single notice", function()
    f.result = 11
    assert(requestSync(f))
    advance(2)
    assert(f.ns.IsSyncPending() and last(f):find(f.ns.L.DEFERRED, 1, true))
    advance(12)
    assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == 1)
    f.result = 0
    advance(20)
    assert(not f.ns.IsSyncPending() and last(f):find("Synced", 1, true))
    advance(35)
end)

test("send failure before BEGIN does not claim partial changes", function()
    local mark = #f.prints
    f.result = 12
    assert(requestSync(f))
    advance(2)
    assert(not f.ns.IsSyncPending() and last(f):find("12", 1, true))
    assert(count(f, "may be incomplete", mark) == 0)
    f.result = 0
    advance(35)
end)

test("cancel releases the receiver immediately", function()
    assert(requestSync(f))
    f.ns.CancelSync()
    assert(not f.ns.IsSyncPending() and last(f):find("cancelled", 1, true))
    advance(35)
end)

test("throttle retries silently", function()
    f.result = 3
    local deferredBefore = count(f, f.ns.L.DEFERRED)
    assert(requestSync(f))
    advance(2)
    assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == deferredBefore)
    f.result = 0
    advance(20)
    assert(not f.ns.IsSyncPending() and last(f):find("Synced", 1, true))
end)

test("losing the guild cancels an active receive", function()
    assert(requestSync(f))
    f.guild = nil
    f.ns.OnSyncContextChanged()
    assert(not f.ns.IsSyncPending())
    f.guild = "Guild"
    advance(35)
end)

test("timeout ends the transfer", function()
    f.result = 11
    assert(requestSync(f))
    advance(1801)
    assert(not f.ns.IsSyncPending() and last(f):find("timed out", 1, true))
    f.result = 0
end)

test("a non-publisher answers NOT_PUBLISHER", function()
    local mark = #f.prints
    local third = client("ThirdMember")
    advance(35)
    assert(f.ns.SelectPublisher("ThirdMember"))
    assert(requestSync(f))
    advance(5)
    assert(not f.ns.IsSyncPending() and last(f):find("not publishing", 1, true))
    assert(count(f, "may be incomplete", mark) == 0)
    assert(third.ns)
end)

test("sync is unavailable when the addon prefix cannot be registered", function()
    local noPrefix = client("NoPrefix")
    noPrefix.prefix = false
    noPrefix.ns.InitGuildSync()
    assert(not requestSync(noPrefix))
end)

test("realm-less 'First Last' names sync", function()
    local rp, rf = client("Andriod En"), client("Other Player")
    for _, c in ipairs({ rp, rf }) do c.roster = { "Andriod En", "Other Player", "Third Guy" } end
    assert(rp.ns.SelectPublisher("Andriod En") and rp.ns.IsPublisher())
    assert(rp.ns.SetModifier("Andriod En", 220) and rp.ns.SetModifier("Other Player", -3))
    assert(rf.ns.SelectPublisher("Andriod En"))
    assert(requestSync(rf))
    advance(20)
    assert(not rf.ns.IsSyncPending() and last(rf):find("Synced 3 modifiers from Andriod En", 1, true))
    assert(rf.ns.GetModifier("Andriod En") == 220 and rf.ns.GetModifier("Other Player") == -3)
    assert(rf.ns.db.modifiers["Third Guy"] == 0 and rf.ns.GetPlayerModifier() == -3)
    for _, line in ipairs(rp.prints) do assert(not line:find("unambiguous", 1, true), line) end
    for _, line in ipairs(rf.prints) do assert(not line:find("unambiguous", 1, true), line) end
end)

local bp, bf = client("Big Publisher"), client("Big Follower")
local bigRoster = { "Big Publisher", "Big Follower" }
for i = 1, 98 do bigRoster[#bigRoster + 1] = string.format("Guild Member Number %03d", i) end

test("large rosters are packed into several VALUE messages", function()
    bp.roster, bf.roster = bigRoster, bigRoster
    for i = 3, #bigRoster do bp.ns.db.modifiers[bigRoster[i]] = i * 1.5 end
    assert(bp.ns.SelectPublisher("Big Publisher") and bf.ns.SelectPublisher("Big Publisher"))
    local mark, valueMessages, deliveredBefore = #bf.prints, 0, #delivered
    assert(requestSync(bf))
    advance(10)
    assert(not bf.ns.IsSyncPending() and last(bf):find("Synced 100 modifiers from Big Publisher", 1, true))
    for i = deliveredBefore + 1, #delivered do
        if delivered[i].text:find("VALUE\t", 1, true) == 1 then valueMessages = valueMessages + 1 end
    end
    assert(valueMessages > 1 and valueMessages < 30, valueMessages)
    assert(count(bf, "Synced ", mark) - 1 == valueMessages and bf.ns.GetModifier(bigRoster[100]) == 150)
    assert(printedSince(bf, mark):find("Synced 100/100:", 1, true))
end)

test("a duplicate name inside one packed VALUE fails the transfer", function()
    advance(35)
    local mark = #bf.prints
    local id = requestSync(bf)
    assert(id)
    bf.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t2\t5", "WHISPER", "Big Publisher")
    bf.ns.OnSyncMessage("Rollover", "VALUE\t" .. id .. "\t1\tBig Follower\t1\tBig Follower\t2", "WHISPER", "Big Publisher")
    assert(not bf.ns.IsSyncPending() and printedSince(bf, mark):find("Invalid or incomplete", 1, true))
end)

test("every sent addon message fits in 255 bytes", function()
    assert(#delivered > 0)
    for _, message in ipairs(delivered) do assert(#message.text <= 255) end
end)
