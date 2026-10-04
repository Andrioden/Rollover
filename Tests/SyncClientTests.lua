-- Run with a standalone Lua interpreter: lua Tests\SyncClientTests.lua <addon directory>
-- Covers the follower side (Sync\SyncClient.lua) alone: there is no master client, so every master reply
-- is injected by hand and the follower's local data, chat output and sent messages are checked.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local count, last, printedSince = harness.count, harness.last, harness.printedSince
local delivered, secret, requestSync = harness.delivered, harness.secret, harness.requestSync
local backupCount, messagesFrom = harness.backupCount, harness.messagesFrom
local test = harness.suite("Sync\\SyncClient.lua")

-- The master stays offline, so selecting it sends nothing; tests start their own requests.
local f = client("Follower")
assert(f.ns.SelectMaster("Master") and not f.ns.IsSyncPending())

local function reply(id, ...)
    f.ns.OnSyncMessage("Rollover", table.concat({ ... }, "\t"):gsub("{id}", id), "WHISPER", "Master")
end

-- Starts a sync and returns its request ID (read from the sent message).
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
    return f.ns.GetModifier("OldMember") == 42 and f.ns.db.sync.updatedAt == 1700000000
end

test("a request is sent to the selected master with the local age", function()
    advance(35)
    f.ns.db.sync.updatedAt = 1700000000
    local mark = #delivered
    assert(f.ns.RequestSync())
    advance(1)
    local requests = messagesFrom("Follower", "REQUEST", mark)
    assert(#requests == 1 and requests[1]:match("^REQUEST\t[%w%-]+\t1700000000$"), requests[1])
    assert(delivered[mark + 1].target == "Master" and delivered[mark + 1].channel == "WHISPER")
    f.ns.CancelSync()
end)

test("protocol guards reject spoofed, secret and mismatched messages", function()
    local id = start()
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t1\t1700000005", "WHISPER", "ThirdMember")
    f.ns.OnSyncMessage("Rollover", secret, "WHISPER", "Master")
    f.ns.OnSyncMessage("Rollover", "BEGIN\twrong\t1\t1700000005", "WHISPER", "Master")
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t1\t1700000005", "WHISPER", "Stranger")
    f.ns.OnSyncMessage("Rollover", "BEGIN\t" .. id .. "\t1\t1700000005", "PARTY", "Master")
    f.ns.OnSyncMessage("Rollover", "Other", "WHISPER", "Master")
    assert(f.ns.IsSyncPending() and unchanged())
    f.ns.CancelSync()
end)

test("a complete transfer is applied at END with a backup", function()
    local id = start()
    local backups = backupCount(f)
    reply(id, "BEGIN\t{id}\t2\t1700000005")
    reply(id, "VALUE\t{id}\t1\tMaster\t7\tZeroMember\t0")
    assert(unchanged(), "values are only buffered")
    assert(printedSince(f, 0):find("Received 2/2", 1, true))
    assert(backupCount(f) == backups)
    reply(id, "END\t{id}\t2")
    assert(not f.ns.IsSyncPending() and last(f):find("Synced 2 modifiers from Master", 1, true))
    assert(f.ns.GetModifier("Master") == 7 and f.ns.GetModifier("OldMember") == 0)
    assert(f.ns.db.sync.updatedAt == 1700000005 and backupCount(f) == backups + 1)
end)

test("an incomplete transfer changes nothing: data, age and backups stay", function()
    local id = start()
    local backups = backupCount(f)
    reply(id, "BEGIN\t{id}\t2\t1700000005")
    reply(id, "VALUE\t{id}\t1\tMaster\t-7")
    assert(f.ns.GetModifier("Master") ~= -7, "received values are only buffered")
    reply(id, "END\t{id}\t2")
    assert(not f.ns.IsSyncPending() and last(f):find("Sync failed", 1, true))
    assert(unchanged() and backupCount(f) == backups)
    assert(not table.concat(f.prints, "\n"):find("may be incomplete", 1, true))
end)

test("malformed and out-of-sequence replies fail the transfer", function()
    local cases = {
        { "VALUE\t{id}\t1\tMaster\t1" }, -- before BEGIN
        { "BEGIN\t{id}\t2\t1700000005", "BEGIN\t{id}\t2\t1700000005" },
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t2\tMaster\t1" }, -- skipped index
        { "BEGIN\t{id}\t1\t1700000005", "VALUE\t{id}\t1\tMaster\t1\tZeroMember\t1" }, -- beyond the count
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\tabc" },
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\t1\tMaster\t2" }, -- duplicate in one message
        { "BEGIN\t{id}\t2\t1700000005", "VALUE\t{id}\t1\tMaster\t1", "VALUE\t{id}\t2\tMaster\t2" }, -- duplicate across messages
        { "BEGIN\t{id}\t1\t1700000005", "END\t{id}\t1" }, -- nothing received
        { "BEGIN\t{id}\t999999\t1700000005" },
        { "BEGIN\t{id}\tx\t1700000005" },
        { "BEGIN\t{id}\t1\t1700000005", "CURRENT\t{id}" }, -- CURRENT cannot follow BEGIN
        { "CURRENT\t{id}\textra" },
        { "UNKNOWN\t{id}" },
        { "ERROR\t{id}\tSOMETHING" },
    }
    for index, case in ipairs(cases) do
        local id = start()
        for _, message in ipairs(case) do reply(id, message) end
        assert(not f.ns.IsSyncPending() and last(f):find("Sync failed", 1, true), "case " .. index)
        assert(unchanged(), "case " .. index)
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
    assert(not f.ns.IsSyncPending() and last(f):find("Already up to date with Master", 1, true))
    assert(unchanged())
end)

test("a master with older data is refused before anything is touched", function()
    local id = start()
    local backups = backupCount(f)
    reply(id, "BEGIN\t{id}\t1\t1699999999")
    assert(not f.ns.IsSyncPending() and last(f):find("Master has older modifiers", 1, true))
    assert(unchanged() and backupCount(f) == backups)
    assert(not table.concat(f.prints, "\n"):find("may be incomplete", 1, true))
end)

test("a master with equal data may still stream (the stamp is not older)", function()
    local id = start()
    reply(id, "BEGIN\t{id}\t1\t1700000000")
    assert(f.ns.IsSyncPending() and last(f):find("Receiving 1 modifiers from Master", 1, true))
    f.ns.CancelSync()
end)

test("lockdown defers the request and retries with a single notice", function()
    advance(35)
    f.result = 11
    assert(requestSync(f))
    advance(2)
    assert(f.ns.IsSyncPending() and last(f):find(f.ns.L.DEFERRED, 1, true))
    advance(12)
    assert(count(f, f.ns.L.DEFERRED) == 1)
    local mark = #delivered
    f.result = 0
    advance(6)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 1)
    f.ns.CancelSync()
end)

test("throttled sends retry silently", function()
    advance(35)
    f.result = 3
    local deferred, mark = count(f, f.ns.L.DEFERRED), #delivered
    assert(requestSync(f))
    advance(2)
    assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == deferred)
    f.result = 0
    advance(2)
    assert(#messagesFrom("Follower", "REQUEST", mark) == 1)
    f.ns.CancelSync()
end)

test("send failure before BEGIN does not claim partial changes", function()
    advance(35)
    local mark = #f.prints
    f.result = 12
    assert(requestSync(f))
    advance(2)
    assert(not f.ns.IsSyncPending() and last(f):find("12", 1, true))
    assert(count(f, "may be incomplete", mark) == 0)
    f.result = 0
end)

test("import, restore and source changes are blocked while receiving", function()
    start()
    assert(not f.ns.ImportModifiers("{}") and not f.ns.SelectMaster("Follower"))
    assert(f.ns.IsSyncPending() and unchanged())
    f.ns.CancelSync()
end)

test("cancel releases the receiver immediately", function()
    start()
    f.ns.CancelSync()
    assert(not f.ns.IsSyncPending() and last(f):find("cancelled", 1, true))
    assert(unchanged())
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
    assert(not requestSync(noPrefix))
    assert(last(noPrefix):find(noPrefix.ns.L.PREFIX_FAILED, 1, true))
end)

test("requests need a master that is not the player", function()
    local solo = client("Solo")
    solo.roster = { "Solo", "Master" }
    assert(not solo.ns.RequestSync() and last(solo):find(solo.ns.L.SELECT_MASTER, 1, true))
    assert(solo.ns.SelectMaster("Solo") and not solo.ns.RequestSync())
    assert(last(solo):find(solo.ns.L.LOCAL_MASTER, 1, true))
end)
