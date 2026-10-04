-- Run with a standalone Lua interpreter: lua Tests\SyncAutoTests.lua <addon directory>
-- Covers automatic syncing between a real master and followers: master selection, login and master-online
-- checks, cooldown and retries, quiet failures, up-to-date replies and master announcements.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client, last, printedSince = harness.advance, harness.client, harness.last, harness.printedSince
local delivered, messagesFrom, login, backupCount = harness.delivered, harness.messagesFrom, harness.login, harness.backupCount
local test = harness.suite("Sync automatic checks and announcements")

local p, f = client("Master"), client("Follower")
f.online.Master, p.online.Follower = true, true
assert(p.ns.SelectMaster("Master") and p.ns.SetModifier("Master", 5))

test("selecting an online master syncs immediately", function()
    assert(f.ns.SelectMaster("Master"))
    advance(2)
    assert(f.ns.GetModifier("Master") == 5 and f.ns.GetUpdatedAt() == p.ns.GetUpdatedAt())
    local output = printedSince(f, 0)
    assert(output:find("Requesting modifiers from Master", 1, true) and output:find("Synced 4 modifiers", 1, true))
end)

test("selecting an offline master waits for it to come online", function()
    local late = client("Late")
    late.roster = { "Late", "Master" }
    local mark = #delivered
    assert(late.ns.SelectMaster("Master"))
    advance(2)
    assert(last(late):find("is offline", 1, true) and #delivered == mark and not late.ns.IsSyncPending())
end)

test("a login check is silent and costs one CURRENT when up to date", function()
    advance(61)
    local followerMark, masterMark, deliveredMark, backups = #f.prints, #p.prints, #delivered, backupCount(f)
    login(f)
    advance(5)
    assert(#f.prints == followerMark and #p.prints == masterMark and backupCount(f) == backups)
    assert(#messagesFrom("Master", "CURRENT", deliveredMark) == 1 and #messagesFrom("Master", "BEGIN", deliveredMark) == 0)
end)

test("a login check streams newer master data with an auto sync backup", function()
    advance(61)
    assert(p.ns.SetModifier("Master", 9))
    local backups = backupCount(f)
    login(f)
    advance(5)
    assert(f.ns.GetModifier("Master") == 9 and f.ns.GetUpdatedAt() == p.ns.GetUpdatedAt())
    assert(backupCount(f) == backups + 1 and last(f):find("Synced 4 modifiers from Master", 1, true))
    local auto = 0
    for _, backup in pairs(f.ns.db.backups) do if backup.name == "auto sync" then auto = auto + 1 end end
    assert(auto == 1)
end)

test("a repeated check inside the cooldown is skipped", function()
    local mark = #delivered
    login(f)
    advance(5)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0)
end)

test("the master coming online triggers one delayed check", function()
    advance(61)
    assert(p.ns.SetModifier("Master", 11))
    f.online.Master = false
    f.ns.OnGuildRosterUpdate()
    advance(10)
    assert(f.ns.GetModifier("Master") == 9, "an offline master is not contacted")
    local mark = #delivered
    f.online.Master = true
    f.ns.OnGuildRosterUpdate()
    f.ns.OnGuildRosterUpdate() -- the client fires the update twice
    advance(2)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0, "the master's addon gets time to settle")
    advance(10)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 1 and f.ns.GetModifier("Master") == 11)
end)

test("the master's own checks and missing masters do nothing", function()
    local mark = #delivered
    login(p)
    login(client("Lone"))
    advance(10)
    assert(#delivered == mark)
end)

test("an unanswered check stays out of chat and retries once", function()
    advance(61)
    local ghost = client("Ghost Follower") -- its master has no client, so requests go unanswered
    ghost.roster = { "Ghost", "Ghost Follower" }
    ghost.online.Ghost = true
    assert(ghost.ns.SelectMaster("Ghost"))
    ghost.ns.CancelSync()
    local mark, printMark = #delivered, #ghost.prints
    login(ghost)
    advance(3)
    assert(ghost.ns.IsSyncPending())
    advance(15)
    assert(not ghost.ns.IsSyncPending(), "timed out")
    advance(6)
    assert(ghost.ns.IsSyncPending(), "retrying")
    advance(76)
    assert(not ghost.ns.IsSyncPending() and #messagesFrom("Ghost Follower", "REQUEST", mark) == 2)
    assert(#ghost.prints == printMark)
end)

test("restricted communication and send errors are silent for automatic checks", function()
    advance(61)
    local mark = #f.prints
    f.result = 11
    login(f)
    advance(20)
    f.result = 12
    advance(61)
    login(f)
    advance(20)
    assert(#f.prints == mark and not f.ns.IsSyncPending())
    f.result = 0
end)

local alpha, beta = client("Alpha"), client("Beta")
alpha.roster, beta.roster = { "Alpha", "Beta" }, { "Alpha", "Beta" }
alpha.online.Beta = true

test("becoming master makes followers who chose that player sync after a random delay", function()
    alpha.ns.db.modifiers.Alpha = 4 -- data that exists before the player becomes master
    alpha.ns.TouchModifiers()
    assert(beta.ns.SelectMaster("Alpha") and last(beta):find("is offline", 1, true))
    -- Alpha comes online without having chosen themselves: the check is answered NOT_MASTER.
    beta.online.Alpha = true
    beta.ns.OnGuildRosterUpdate()
    advance(10)
    assert(beta.ns.GetModifier("Alpha") == 0)
    local mark = #delivered
    alpha.ns.SelectMaster("Alpha")
    advance(0.5)
    assert(#messagesFrom("Alpha", "ANNOUNCE", mark) == 1 and #messagesFrom("Beta", "REQUEST", mark) == 0)
    advance(2.5) -- two online members: the delay is 1-2 s
    assert(#messagesFrom("Beta", "REQUEST", mark) == 1)
    assert(beta.ns.GetModifier("Alpha") == 4 and beta.ns.GetUpdatedAt() == alpha.ns.GetUpdatedAt())
end)

test("announcements are only acted on from the chosen master, on the guild channel, with a newer stamp", function()
    advance(61)
    local mark = #delivered
    local own, newer = beta.ns.GetUpdatedAt(), beta.ns.GetUpdatedAt() + 5
    alpha.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-1\t" .. newer, "GUILD", "Alpha") -- the master's own echo
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-1\t" .. own, "GUILD", "Alpha") -- not newer
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\t" .. newer, "GUILD", "Beta") -- not the master
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\t" .. newer, "WHISPER", "Alpha")
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\tbad", "GUILD", "Alpha")
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2", "GUILD", "Alpha")
    advance(30)
    assert(#delivered == mark)
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-2\t" .. newer, "GUILD", "Alpha")
    advance(30)
    assert(#messagesFrom("Beta", "REQUEST", mark) == 1)
end)

test("the announcement delay grows with the number of online guild members", function()
    advance(61)
    local roster = { "Alpha", "Beta" }
    beta.online = { Alpha = true, Beta = true }
    for i = 1, 60 do
        roster[#roster + 1] = "Online" .. i
        beta.online["Online" .. i] = true
    end
    beta.roster = roster
    local mark, random = #delivered, math.random
    math.random = function() return 0.99 end
    beta.ns.OnSyncMessage("Rollover", "ANNOUNCE\tx-9\t" .. (beta.ns.GetUpdatedAt() + 5), "GUILD", "Alpha")
    math.random = random
    advance(20)
    assert(#messagesFrom("Beta", "REQUEST", mark) == 0, "62 online members spread checks over 30 s")
    advance(12)
    assert(#messagesFrom("Beta", "REQUEST", mark) == 1)
end)
