-- Run with a standalone Lua interpreter: lua Tests\SyncClientTests.lua <addon directory>
-- Covers the follower side (Sync\SyncClient.lua) alone: there is no master client, so every master reply
-- is injected by hand and the follower's local data, chat output and sent messages are checked.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client, last = harness.advance, harness.client, harness.last
local delivered, secret, requestSync = harness.delivered, harness.secret, harness.requestSync
local backupCount, messagesFrom = harness.backupCount, harness.messagesFrom
local test = harness.suite("Sync\\SyncClient.lua")

-- The master stays offline, so selecting it sends nothing; tests start their own requests.
local f = client("Follower")
assert(f.ns.SelectMaster("Master") and not f.ns.IsSyncPending())

local function reply(id, message)
    f.ns.OnSyncMessage("Rollover", (message:gsub("{id}", id)), "WHISPER", "Master")
end

-- Starts a sync from known local data and returns its request ID (read from the sent message).
local function start()
    advance(35)
    f.ns.db.modifiers = { OldMember = 42 }
    f.ns.db.sync.updatedAt = 1700000000
    assert(f.ns.RequestSync() and f.ns.IsSyncPending())
    advance(1)
    local requests = messagesFrom("Follower", "REQUEST")
    return requests[#requests]:match("^REQUEST\t([^\t]+)")
end

local function unchanged()
    return f.ns.GetModifier("OldMember") == 42 and f.ns.GetUpdatedAt() == 1700000000
end

test("a request whispers the selected master with the local age", function()
    local mark = #delivered
    start()
    local requests = messagesFrom("Follower", "REQUEST", mark)
    assert(#requests == 1 and requests[1]:match("^REQUEST\t[%w%-]+\t1700000000$"), requests[1])
    assert(delivered[mark + 1].target == "Master" and delivered[mark + 1].channel == "WHISPER")
    f.ns.CancelSync()
end)

test("spoofed, secret and mismatched messages are ignored", function()
    local id = start()
    local begin = "BEGIN\t" .. id .. "\t1\t1700000005"
    f.ns.OnSyncMessage("Rollover", begin, "WHISPER", "ThirdMember") -- not the master
    f.ns.OnSyncMessage("Rollover", begin, "WHISPER", "Stranger") -- not in the guild
    f.ns.OnSyncMessage("Rollover", begin, "PARTY", "Master")
    f.ns.OnSyncMessage("Other", begin, "WHISPER", "Master")
    f.ns.OnSyncMessage("Rollover", secret, "WHISPER", "Master")
    f.ns.OnSyncMessage("Rollover", "BEGIN\twrong\t1\t1700000005", "WHISPER", "Master")
    assert(f.ns.IsSyncPending() and unchanged())
    f.ns.CancelSync()
end)

test("a complete transfer is buffered, then applied at END with a sync backup", function()
    local id = start()
    local backups = backupCount(f)
    reply(id, "BEGIN\t{id}\t2\t1700000005")
    reply(id, "VALUE\t{id}\t1\tMaster\t7\tZeroMember\t0")
    assert(unchanged() and backupCount(f) == backups and last(f):find("Received 2/2", 1, true))
    reply(id, "END\t{id}\t2")
    assert(not f.ns.IsSyncPending() and last(f):find("Synced 2 modifiers from Master", 1, true))
    assert(f.ns.GetModifier("Master") == 7 and f.ns.GetModifier("OldMember") == 0)
    assert(f.ns.GetUpdatedAt() == 1700000005 and backupCount(f) == backups + 1)
    for _, backup in pairs(f.ns.db.backups) do
        if backup.modifiers.OldMember == 42 then assert(backup.name == "sync") end
    end
end)

test("malformed, incomplete and out-of-sequence replies fail without changes", function()
    local cases = {
        { "VALUE\t{id}\t1\tMaster\t1" }, -- before BEGIN
        { "BEGIN\t{id}\t2\t1700000005", "BEGIN\t{id}\t2\t1700000005" },
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t2\tMaster\t1" }, -- skipped index
        { "BEGIN\t{id}\t1\t1700000005", "VALUE\t{id}\t1\tMaster\t1\tZeroMember\t1" }, -- beyond the count
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\tabc" },
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\t1\tMaster\t2" }, -- duplicate in one message
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\t1", "VALUE\t{id}\t2\tMaster\t2" }, -- duplicate across messages
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\t-7", "END\t{id}\t2" }, -- incomplete
        { "BEGIN\t{id}\t999999\t1700000005" },
        { "BEGIN\t{id}\tx\t1700000005" },
        { "BEGIN\t{id}\t1\t1700000005", "CURRENT\t{id}" }, -- CURRENT cannot follow BEGIN
        { "CURRENT\t{id}\textra" },
        { "UNKNOWN\t{id}" },
        { "ERROR\t{id}\tSOMETHING" },
    }
    for index, case in ipairs(cases) do
        local id = start()
        local backups = backupCount(f)
        for _, message in ipairs(case) do reply(id, message) end
        assert(not f.ns.IsSyncPending() and last(f):find("Sync failed", 1, true), "case " .. index)
        assert(unchanged() and backupCount(f) == backups, "case " .. index)
    end
end)

test("master errors are reported with their reason", function()
    local errors = { NOT_MASTER = f.ns.L.NOT_MASTER, BUSY = f.ns.L.MASTER_BUSY, INVALID_TRANSFER = f.ns.L.INVALID_TRANSFER }
    for code, text in pairs(errors) do
        local id = start()
        reply(id, "ERROR\t{id}\t" .. code)
        assert(not f.ns.IsSyncPending() and last(f):find(text, 1, true), code)
    end
end)

test("CURRENT ends a manual sync as up to date", function()
    local id = start()
    reply(id, "CURRENT\t{id}")
    assert(not f.ns.IsSyncPending() and last(f):find("Already up to date with Master", 1, true) and unchanged())
end)

test("a master with older data is refused before anything is touched", function()
    local id = start()
    local backups = backupCount(f)
    reply(id, "BEGIN\t{id}\t1\t1699999999")
    assert(not f.ns.IsSyncPending() and last(f):find("Master has older modifiers", 1, true))
    assert(unchanged() and backupCount(f) == backups)
end)

test("a master with equal data may still stream", function()
    local id = start()
    reply(id, "BEGIN\t{id}\t1\t1700000000")
    assert(f.ns.IsSyncPending() and last(f):find("Receiving 1 modifiers from Master", 1, true))
    f.ns.CancelSync()
end)

test("send errors end the request and are reported", function()
    advance(35)
    f.result = 12
    assert(requestSync(f))
    advance(2)
    assert(not f.ns.IsSyncPending() and last(f):find("12", 1, true))
    f.result = 0
end)

test("import, restore, reset and master changes are blocked while receiving", function()
    local backup = f.ns.SaveBackup("manual")
    start()
    assert(not f.ns.ImportModifiers("{}") and not f.ns.RestoreBackup(backup) and not f.ns.ResetData())
    assert(not f.ns.SelectMaster("Follower") and not f.ns.DeselectMaster())
    assert(last(f):find(f.ns.L.BUSY, 1, true) and f.ns.IsSyncPending() and unchanged())
    f.ns.CancelSync()
end)

test("cancel releases the receiver immediately", function()
    start()
    f.ns.CancelSync()
    assert(not f.ns.IsSyncPending() and last(f):find("cancelled", 1, true) and unchanged())
end)

test("a queued request is dropped once it was cancelled", function()
    advance(35)
    f.result = 11
    assert(requestSync(f))
    f.ns.CancelSync()
    local mark = #delivered
    f.result = 0
    advance(10)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 0)
end)

test("losing the guild or the master from the roster ends an active receive", function()
    start()
    f.guild = nil
    f.ns.OnSyncContextChanged()
    assert(not f.ns.IsSyncPending() and last(f):find("Sync failed", 1, true))
    f.guild = "Guild"
    start()
    f.roster = { "Follower", "ZeroMember" }
    f.ns.OnSyncContextChanged()
    assert(not f.ns.IsSyncPending())
    f.roster = { "Master", "Follower", "ZeroMember", "ThirdMember" }
end)

test("timeout ends the transfer", function()
    advance(35)
    f.result = 11
    assert(requestSync(f))
    advance(1801)
    assert(not f.ns.IsSyncPending() and last(f):find("timed out", 1, true))
    f.result = 0
end)

test("sync is unavailable when the addon prefix cannot be registered", function()
    local noPrefix = client("NoPrefix")
    noPrefix.prefix = false
    noPrefix.ns.InitGuildSync()
    assert(not requestSync(noPrefix) and last(noPrefix):find(noPrefix.ns.L.PREFIX_FAILED, 1, true))
end)

test("requests need a master that is not the player", function()
    local solo = client("Solo")
    solo.roster = { "Solo", "Master" }
    assert(not solo.ns.RequestSync() and last(solo):find(solo.ns.L.SELECT_MASTER, 1, true))
    assert(solo.ns.SelectMaster("Solo") and not solo.ns.RequestSync())
    assert(last(solo):find(solo.ns.L.LOCAL_MASTER, 1, true))
end)
