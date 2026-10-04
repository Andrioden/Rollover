-- Run with a standalone Lua interpreter: lua Tests\AutoSyncTests.lua <addon directory>
-- Covers automatic syncing (Modules\GuildSync.lua): publisher selection, login and publisher-online
-- checks, up-to-date replies, quiet failures and the timestamp/backup rules.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local last, printedSince = harness.last, harness.printedSince
local delivered = harness.delivered
local test = harness.suite("Automatic sync")

local function messagesFrom(name, kind, mark)
    local found = {}
    for i = (mark or 0) + 1, #delivered do
        local entry = delivered[i]
        if entry.sender == name and entry.text:find(kind .. "\t", 1, true) == 1 then found[#found + 1] = entry.text end
    end
    return found
end

local function autoBackups(c)
    local total = 0
    for key in pairs(c.ns.db.backups) do if key:find("(auto)", 1, true) then total = total + 1 end end
    return total
end

local function lastRequestId()
    local requests = messagesFrom("Follower", "REQUEST")
    return requests[#requests]:match("REQUEST\t([^\t]+)")
end

-- Sends a manual request that the publisher cannot answer, so tests can inject messages with its ID.
local function holdRequest(publisher, follower)
    publisher.result = 12
    assert(follower.ns.RequestSync())
    advance(0.5)
    publisher.result = 0
    return lastRequestId()
end

local function login(c)
    c.ns.OnPlayerEnteringWorld(true, false)
    c.ns.OnGuildRosterUpdate()
end

local p, f = client("Publisher"), client("Follower")
f.online.Publisher, p.online.Follower = true, true
assert(p.ns.SelectPublisher("Publisher") and p.ns.SetModifier("Publisher", 5))

test("selecting an online publisher syncs immediately", function()
    assert(f.ns.SelectPublisher("Publisher"))
    advance(2)
    assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Publisher") == 5)
    assert(f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
    local output = printedSince(f, 0)
    assert(output:find("Requesting modifiers from Publisher", 1, true) and output:find("Synced 4 modifiers", 1, true))
    assert(messagesFrom("Follower", "REQUEST")[1]:match("^REQUEST\t[%w%-]+$"), "a new publisher must stream in full")
end)

test("selecting an offline publisher waits for it to come online", function()
    local late = client("Late")
    late.roster = { "Late", "Publisher" }
    local mark = #delivered
    assert(late.ns.SelectPublisher("Publisher"))
    advance(2)
    assert(last(late):find("is offline", 1, true) and #delivered == mark)
    assert(late.ns.db.sync.updatedAt == nil and not late.ns.IsSyncPending())
end)

test("a repeated manual sync reports up to date instead of failing as busy", function()
    advance(1)
    local mark, deliveredMark = #f.prints, #delivered
    assert(f.ns.RequestSync())
    advance(2)
    assert(not f.ns.IsSyncPending() and last(f):find("Already up to date with Publisher", 1, true))
    assert(not printedSince(f, mark):find("Sync failed", 1, true))
    assert(#messagesFrom("Publisher", "CURRENT", deliveredMark) == 1)
end)

test("login check is silent and cheap when up to date", function()
    advance(61)
    local followerMark, publisherMark, deliveredMark = #f.prints, #p.prints, #delivered
    local backups = 0
    for _ in pairs(f.ns.db.backups) do backups = backups + 1 end
    login(f)
    advance(5)
    assert(not f.ns.IsSyncPending() and #f.prints == followerMark and #p.prints == publisherMark)
    local request = messagesFrom("Follower", "REQUEST", deliveredMark)[1]
    assert(request and request:match("\t" .. f.ns.db.sync.updatedAt .. "$"), "REQUEST carries updatedAt")
    assert(#messagesFrom("Publisher", "CURRENT", deliveredMark) == 1 and #messagesFrom("Publisher", "BEGIN", deliveredMark) == 0)
    local after = 0
    for _ in pairs(f.ns.db.backups) do after = after + 1 end
    assert(after == backups)
end)

test("a newer publisher state is streamed with a tagged backup", function()
    advance(61)
    assert(p.ns.SetModifier("Publisher", 9))
    local publisherMark, backups = #p.prints, autoBackups(f)
    login(f)
    advance(5)
    assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Publisher") == 9)
    assert(f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
    assert(autoBackups(f) == backups + 1)
    assert(printedSince(p, publisherMark):find("Follower requested a sync", 1, true))
    assert(printedSince(f, 0):find("Synced 4 modifiers from Publisher", 1, true))
end)

test("a repeated check inside the cooldown is skipped", function()
    local mark = #delivered
    login(f)
    advance(5)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0)
end)

test("the publisher coming online triggers one check", function()
    advance(61)
    assert(p.ns.SetModifier("Publisher", 11))
    f.online.Publisher = false
    f.ns.OnGuildRosterUpdate()
    advance(10)
    assert(f.ns.GetModifier("Publisher") == 9, "an offline publisher is not contacted")
    local mark = #delivered
    f.online.Publisher = true
    f.ns.OnGuildRosterUpdate()
    f.ns.OnGuildRosterUpdate()
    advance(2)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0, "the publisher's addon gets time to settle")
    advance(10)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 1)
    assert(f.ns.GetModifier("Publisher") == 11 and f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
end)

test("the publisher's own checks and missing publishers do nothing", function()
    local mark = #delivered
    login(p)
    local lone = client("Lone")
    login(lone)
    advance(10)
    assert(#delivered == mark)
end)

test("failures before BEGIN stay out of chat and retry once", function()
    advance(61)
    local ghost = client("Ghost Follower")
    ghost.roster = { "Ghost", "Ghost Follower" }
    ghost.online.Ghost = true
    assert(ghost.ns.SelectPublisher("Ghost"))
    ghost.ns.CancelSync()
    ghost.ns.db.sync.updatedAt = 10
    local mark, printMark = #delivered, #ghost.prints
    login(ghost)
    advance(3)
    assert(ghost.ns.IsSyncPending())
    advance(15)
    assert(not ghost.ns.IsSyncPending())
    advance(6)
    assert(ghost.ns.IsSyncPending())
    advance(16)
    advance(60)
    assert(not ghost.ns.IsSyncPending() and #messagesFrom("Ghost Follower", "REQUEST", mark) == 2)
    assert(#ghost.prints == printMark)
end)

test("restricted communication and send errors are silent for automatic checks", function()
    advance(61)
    local mark = #f.prints
    f.result = 11
    login(f)
    advance(20)
    assert(#f.prints == mark)
    f.result = 12
    advance(61)
    login(f)
    advance(20)
    assert(#f.prints == mark and not f.ns.IsSyncPending())
    f.result = 0
end)

test("an interrupted stream clears updatedAt so the next check repairs it", function()
    advance(61)
    assert(f.ns.db.sync.updatedAt)
    local id = holdRequest(p, f)
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t2\t5", "WHISPER", "Publisher")
    assert(f.ns.db.sync.updatedAt == nil)
    f.ns.CancelSync()
    assert(f.ns.db.sync.updatedAt == nil)
    advance(35)
    login(f)
    advance(5)
    assert(f.ns.GetModifier("Publisher") == 11 and f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
end)

test("malformed and unexpected messages are rejected", function()
    advance(61)
    local mark = #delivered
    p.ns.OnSyncMessage("Rollover", "REQUEST\tbad-id\tnotanumber", "WHISPER", "Follower")
    p.ns.OnSyncMessage("Rollover", "REQUEST\tbad-id\t1\t2", "WHISPER", "Follower")
    advance(2)
    assert(#delivered == mark)
    f.ns.db.sync.updatedAt = nil -- CURRENT is only valid for a request that sent updatedAt
    local id = holdRequest(p, f)
    f.ns.OnSyncMessage("Rollover", "CURRENT\t" .. id, "WHISPER", "Publisher")
    assert(not f.ns.IsSyncPending() and last(f):find("Sync failed", 1, true))
    advance(35)
end)

test("a second changed sync inside the rate limit explains the wait", function()
    local second = client("Second")
    second.online.Publisher = true
    p.online.Second = true
    p.roster, second.roster = { "Publisher", "Follower", "Second" }, { "Publisher", "Follower", "Second" }
    assert(second.ns.SelectPublisher("Publisher"))
    advance(3)
    assert(p.ns.SetModifier("Publisher", 6))
    assert(second.ns.RequestSync())
    advance(3)
    assert(not second.ns.IsSyncPending() and last(second):find("publisher is busy or was asked too recently", 1, true))
    assert(not last(second):find("already active", 1, true))
    p.roster = { "Publisher", "Follower", "ZeroMember", "ThirdMember" }
    advance(61)
end)
