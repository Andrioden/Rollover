-- Run with a standalone Lua interpreter: lua Tests\AutoSyncTests.lua <addon directory>
-- Covers automatic syncing (Modules\GuildSync.lua): master selection, login and master-online
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
    for key in pairs(c.ns.db.backups) do if c.ns.db.backups[key].name == "auto sync" then total = total + 1 end end
    return total
end

local function lastRequestId()
    local requests = messagesFrom("Follower", "REQUEST")
    return requests[#requests]:match("REQUEST\t([^\t]+)")
end

-- Sends a manual request that the master cannot answer, so tests can inject messages with its ID.
local function holdRequest(master, follower)
    master.result = 12
    assert(follower.ns.RequestSync())
    advance(0.5)
    master.result = 0
    return lastRequestId()
end

local function login(c)
    c.ns.OnPlayerEnteringWorld(true, false)
    c.ns.OnGuildRosterUpdate()
end

local p, f = client("Master"), client("Follower")
f.online.Master, p.online.Follower = true, true
assert(p.ns.SelectMaster("Master") and p.ns.SetModifier("Master", 5))

test("selecting an online master syncs immediately", function()
    assert(f.ns.SelectMaster("Master"))
    advance(2)
    assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Master") == 5)
    assert(f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
    local output = printedSince(f, 0)
    assert(output:find("Requesting modifiers from Master", 1, true) and output:find("Synced 4 modifiers", 1, true))
    assert(messagesFrom("Follower", "REQUEST")[1]:match("^REQUEST\t[%w%-]+\t0$"), "a fresh follower asks with age 0")
end)

test("selecting an offline master waits for it to come online", function()
    local late = client("Late")
    late.roster = { "Late", "Master" }
    local mark = #delivered
    assert(late.ns.SelectMaster("Master"))
    advance(2)
    assert(last(late):find("is offline", 1, true) and #delivered == mark)
    assert(late.ns.db.sync.updatedAt == nil and not late.ns.IsSyncPending())
end)

test("a repeated manual sync reports up to date instead of failing as busy", function()
    advance(1)
    local mark, deliveredMark = #f.prints, #delivered
    assert(f.ns.RequestSync())
    advance(2)
    assert(not f.ns.IsSyncPending() and last(f):find("Already up to date with Master", 1, true))
    assert(not printedSince(f, mark):find("Sync failed", 1, true))
    assert(#messagesFrom("Master", "CURRENT", deliveredMark) == 1)
end)

test("login check is silent and cheap when up to date", function()
    advance(61)
    local followerMark, masterMark, deliveredMark = #f.prints, #p.prints, #delivered
    local backups = 0
    for _ in pairs(f.ns.db.backups) do backups = backups + 1 end
    login(f)
    advance(5)
    assert(not f.ns.IsSyncPending() and #f.prints == followerMark and #p.prints == masterMark)
    local request = messagesFrom("Follower", "REQUEST", deliveredMark)[1]
    assert(request and request:match("\t" .. f.ns.db.sync.updatedAt .. "$"), "REQUEST carries updatedAt")
    assert(#messagesFrom("Master", "CURRENT", deliveredMark) == 1 and #messagesFrom("Master", "BEGIN", deliveredMark) == 0)
    local after = 0
    for _ in pairs(f.ns.db.backups) do after = after + 1 end
    assert(after == backups)
end)

test("a newer master state is streamed with a tagged backup", function()
    advance(61)
    assert(p.ns.SetModifier("Master", 9))
    local masterMark, backups = #p.prints, autoBackups(f)
    login(f)
    advance(5)
    assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Master") == 9)
    assert(f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
    assert(autoBackups(f) == backups + 1)
    assert(printedSince(p, masterMark):find("Follower requested a sync", 1, true))
    assert(printedSince(f, 0):find("Synced 4 modifiers from Master", 1, true))
end)

test("a repeated check inside the cooldown is skipped", function()
    local mark = #delivered
    login(f)
    advance(5)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0)
end)

test("the master coming online triggers one check", function()
    advance(61)
    assert(p.ns.SetModifier("Master", 11))
    f.online.Master = false
    f.ns.OnGuildRosterUpdate()
    advance(10)
    assert(f.ns.GetModifier("Master") == 9, "an offline master is not contacted")
    local mark = #delivered
    f.online.Master = true
    f.ns.OnGuildRosterUpdate()
    f.ns.OnGuildRosterUpdate()
    advance(2)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0, "the master's addon gets time to settle")
    advance(10)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 1)
    assert(f.ns.GetModifier("Master") == 11 and f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
end)

test("the master's own checks and missing masters do nothing", function()
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
    assert(ghost.ns.SelectMaster("Ghost"))
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

test("an interrupted stream leaves local data and its age untouched", function()
    advance(61)
    local stamp, value, backups = f.ns.db.sync.updatedAt, f.ns.GetModifier("Master"), autoBackups(f)
    assert(stamp and value == 11)
    local id = holdRequest(p, f)
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t2\t" .. (stamp + 5), "WHISPER", "Master")
    f.ns.OnSyncMessage("Rollover", "VALUE\t" .. id .. "\t1\tMaster\t-7", "WHISPER", "Master")
    f.ns.CancelSync()
    assert(f.ns.db.sync.updatedAt == stamp and f.ns.GetModifier("Master") == 11 and autoBackups(f) == backups)
    advance(35)
    login(f)
    advance(5)
    assert(f.ns.GetModifier("Master") == 11 and f.ns.db.sync.updatedAt == p.ns.db.sync.updatedAt)
end)

test("malformed and unexpected messages are rejected", function()
    advance(61)
    local mark = #delivered
    p.ns.OnSyncMessage("Rollover", "REQUEST\tbad-id\tnotanumber", "WHISPER", "Follower")
    p.ns.OnSyncMessage("Rollover", "REQUEST\tbad-id\t1\t2", "WHISPER", "Follower")
    advance(2)
    assert(#delivered == mark)
    local id = holdRequest(p, f)
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t1\t" .. f.ns.db.sync.updatedAt, "WHISPER", "Master")
    f.ns.OnSyncMessage("Rollover", "CURRENT\t" .. id, "WHISPER", "Master") -- CURRENT cannot follow BEGIN
    assert(not f.ns.IsSyncPending() and last(f):find("Sync failed", 1, true))
    advance(35)
end)

test("a second changed sync inside the rate limit explains the wait", function()
    local second = client("Second")
    second.online.Master = true
    p.online.Second = true
    p.roster, second.roster = { "Master", "Follower", "Second" }, { "Master", "Follower", "Second" }
    assert(second.ns.SelectMaster("Master"))
    advance(3)
    assert(p.ns.SetModifier("Master", 6))
    assert(second.ns.RequestSync())
    advance(3)
    assert(not second.ns.IsSyncPending() and last(second):find("master is busy or was asked too recently", 1, true))
    assert(not last(second):find("already active", 1, true))
    p.roster = { "Master", "Follower", "ZeroMember", "ThirdMember" }
    advance(61)
end)

test("a player who becomes master announces it so followers who chose them sync", function()
    local alpha, beta = client("Alpha"), client("Beta")
    alpha.roster, beta.roster = { "Alpha", "Beta" }, { "Alpha", "Beta" }
    alpha.online.Beta = true
    assert(alpha.ns.SetModifier("Alpha", 4))
    assert(beta.ns.SelectMaster("Alpha") and last(beta):find("is offline", 1, true))
    -- Alpha logs in without having chosen themselves: the master check is answered NOT_MASTER.
    beta.online.Alpha = true
    beta.ns.OnGuildRosterUpdate()
    advance(10)
    assert(beta.ns.GetModifier("Alpha") == 0 and beta.ns.db.sync.updatedAt == nil)
    local mark = #delivered
    alpha.ns.SelectMaster("Alpha")
    advance(0.5)
    local announce = delivered[mark + 1]
    assert(announce and announce.channel == "GUILD" and announce.text:match("^ANNOUNCE\t[%w%-]+\t" .. alpha.ns.db.sync.updatedAt .. "$"))
    assert(#messagesFrom("Beta", "REQUEST", mark) == 0, "followers wait a random delay")
    advance(2.5) -- two online members: the delay is 1-2 s
    assert(#messagesFrom("Beta", "REQUEST", mark) == 1)
    assert(beta.ns.GetModifier("Alpha") == 4 and beta.ns.db.sync.updatedAt == alpha.ns.db.sync.updatedAt)
    assert(not beta.ns.IsSyncPending() and #messagesFrom("Alpha", "BEGIN", mark) == 1)
end)

test("an announcement with an unchanged updatedAt starts nothing", function()
    advance(61)
    local alpha, beta = harness.clients.Alpha, harness.clients.Beta
    local mark = #delivered
    alpha.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-1\t" .. beta.ns.db.sync.updatedAt, "GUILD", "Alpha")
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-1\t" .. beta.ns.db.sync.updatedAt, "GUILD", "Alpha")
    advance(30)
    assert(#delivered == mark)
end)

test("announcements are only accepted from the chosen master on the guild channel", function()
    advance(61)
    local beta = harness.clients.Beta
    local mark = #delivered
    local newer = beta.ns.db.sync.updatedAt + 5
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\t" .. newer, "GUILD", "Beta") -- not the master
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\t" .. newer, "WHISPER", "Alpha") -- wrong channel
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\tbad", "GUILD", "Alpha")
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2", "GUILD", "Alpha")
    beta.ns.OnSyncMessage("Rollover", "REQUEST\tx-3", "GUILD", "Alpha") -- only ANNOUNCE may use GUILD
    advance(30)
    assert(#delivered == mark)
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\t" .. newer, "GUILD", "Alpha")
    advance(30)
    assert(#messagesFrom("Beta", "REQUEST", mark) == 1)
end)

test("the announcement delay grows with the number of online guild members", function()
    advance(61)
    local beta = harness.clients.Beta
    local roster = { "Alpha", "Beta" }
    beta.online = { Alpha = true, Beta = true }
    for i = 1, 60 do
        roster[#roster + 1] = "Online" .. i
        beta.online["Online" .. i] = true
    end
    beta.roster = roster
    local mark, random = #delivered, math.random
    math.random = function() return 0.99 end
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-9\t" .. (beta.ns.db.sync.updatedAt + 5), "GUILD", "Alpha")
    math.random = random
    advance(20)
    assert(#messagesFrom("Beta", "REQUEST", mark) == 0, "62 online members spread checks over 30 s")
    advance(12)
    assert(#messagesFrom("Beta", "REQUEST", mark) == 1)
end)

local function backupCount(c)
    local total = 0
    for _ in pairs(c.ns.db.backups) do total = total + 1 end
    return total
end

local old, new = client("Oldie"), client("Newbie")

test("a follower rejects a master with older data before touching anything", function()
    advance(61)
    old.roster, new.roster = { "Oldie", "Newbie" }, { "Oldie", "Newbie" }
    old.online.Newbie, new.online.Oldie = true, true
    assert(old.ns.SelectMaster("Oldie") and old.ns.SetModifier("Oldie", 1))
    new.ns.db.modifiers = { Oldie = 77 }
    new.ns.db.sync.updatedAt = old.ns.db.sync.updatedAt + 100
    local backups = backupCount(new)
    assert(new.ns.SelectMaster("Oldie"))
    advance(3)
    assert(#messagesFrom("Oldie", "BEGIN") == 1, "the master streams; the follower refuses")
    assert(not new.ns.IsSyncPending() and new.ns.GetModifier("Oldie") == 77)
    assert(new.ns.db.sync.updatedAt == old.ns.db.sync.updatedAt + 100 and backupCount(new) == backups)
    local output = printedSince(new, 0)
    assert(output:find("Oldie has older modifiers", 1, true) and not output:find("may be incomplete", 1, true))
end)

test("announcements older than the local data are ignored", function()
    advance(61)
    local mark = #delivered
    local stamp = old.ns.db.sync.updatedAt
    new.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-1\t" .. stamp, "GUILD", "Oldie")
    advance(30)
    assert(#messagesFrom("Newbie", "REQUEST", mark) == 0)
end)

test("automatic checks report an older master once per stamp, manual syncs always", function()
    advance(61)
    local mark = #new.prints
    login(new)
    advance(5)
    assert(#new.prints == mark and not new.ns.IsSyncPending() and new.ns.GetModifier("Oldie") == 77)
    advance(61)
    assert(new.ns.RequestSync())
    advance(3)
    assert(printedSince(new, mark):find("has older modifiers", 1, true))
end)

test("reset data lets a follower take the older master's data", function()
    advance(61)
    assert(new.ns.ResetData() and new.ns.db.sync.updatedAt == 0)
    assert(new.ns.RequestSync())
    advance(3)
    assert(new.ns.GetModifier("Oldie") == 1 and new.ns.db.sync.updatedAt == old.ns.db.sync.updatedAt)
    assert(not new.ns.IsSyncPending())
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
    assert(other.ns.GetModifier("Blank") == 5 and other.ns.db.sync.updatedAt == 1800000005)
    assert(#messagesFrom("Blank", "BEGIN") >= 1 and not other.ns.IsSyncPending())
end)