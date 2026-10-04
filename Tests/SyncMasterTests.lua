-- Run with a standalone Lua interpreter: lua Tests\SyncMasterTests.lua <addon directory>
-- Covers the master side (Sync\SyncMaster.lua) alone: there is no follower client, so requests are
-- injected by hand and the messages the master sends are read from the delivered log.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client, count, printedSince = harness.advance, harness.client, harness.count, harness.printedSince
local delivered, secret, messagesFrom = harness.delivered, harness.secret, harness.messagesFrom
local test = harness.suite("Sync\\SyncMaster.lua")

-- A client whose roster includes itself, so it can select itself as master.
local function member(name)
    local c = client(name)
    c.roster = { name, "Master", "Follower", "ZeroMember", "ThirdMember" }
    return c
end

local sequence = 0
-- Sends REQUEST <id> <have> to `c` and lets it answer. Returns the request ID and the delivered mark.
local function ask(c, sender, have, channel)
    sequence = sequence + 1
    local id, mark = "req-" .. sequence, #delivered
    c.ns.OnSyncMessage("Rollover", "REQUEST\t" .. id .. "\t" .. (have or 0), channel or "WHISPER", sender or "Follower")
    advance(2)
    return id, mark
end

local m = client("Master")
assert(m.ns.SelectMaster("Master") and m.ns.SetModifier("Master", 12.5) and m.ns.SetModifier("FormerMember", -4))
advance(1) -- lets the master announcement leave the queue

test("a request streams BEGIN, all modifiers with roster zeros, and END", function()
    local printMark = #m.prints
    local id, mark = ask(m)
    local sent = {}
    for i = mark + 1, #delivered do
        assert(delivered[i].target == "Follower" and delivered[i].channel == "WHISPER")
        sent[#sent + 1] = delivered[i].text
    end
    -- Sorted by name; roster members without saved data are included as zeros.
    assert(#sent == 3)
    assert(sent[1] == "BEGIN\t" .. id .. "\t5\t" .. m.ns.GetUpdatedAt(), sent[1])
    assert(sent[2] == "VALUE\t" .. id .. "\t1\tFollower\t0\tFormerMember\t-4\tMaster\t12.5\tThirdMember\t0\tZeroMember\t0", sent[2])
    assert(sent[3] == "END\t" .. id .. "\t5", sent[3])
    assert(printedSince(m, printMark):find("Follower requested a sync; sending 5 modifiers.", 1, true))
end)

test("a repeated request inside 30 seconds is answered BUSY, then served again", function()
    local printMark = #m.prints
    local id, mark = ask(m)
    assert(messagesFrom("Master", "ERROR", mark)[1] == "ERROR\t" .. id .. "\tBUSY" and #delivered == mark + 1)
    assert(printedSince(m, printMark):find("asked again too soon", 1, true))
    advance(31)
    local _, later = ask(m)
    assert(#messagesFrom("Master", "BEGIN", later) == 1)
end)

test("an up-to-date follower gets one silent CURRENT, without rate limit; an older one is streamed", function()
    advance(31)
    local printMark = #m.prints
    local id, mark = ask(m, "Follower", m.ns.GetUpdatedAt())
    assert(messagesFrom("Master", "CURRENT", mark)[1] == "CURRENT\t" .. id)
    assert(#delivered == mark + 1 and #m.prints == printMark, "nothing else is sent or printed")
    local _, again = ask(m, "Follower", m.ns.GetUpdatedAt())
    assert(#messagesFrom("Master", "CURRENT", again) == 1)
    local _, stream = ask(m, "Follower", m.ns.GetUpdatedAt() - 1)
    assert(#messagesFrom("Master", "BEGIN", stream) == 1)
end)

test("malformed and misrouted messages are not answered", function()
    advance(31)
    local mark = #delivered
    ask(m, "Follower", "notanumber")
    ask(m, "Follower", "1\t2")
    ask(m, "Follower", "1099511627777") -- above the stamp bound
    ask(m, "Stranger") -- not in the guild roster
    ask(m, "Follower", 0, "PARTY")
    ask(m, "Follower", 0, "GUILD") -- only ANNOUNCE may use the guild channel
    for _, text in ipairs({ "REQUEST\tx-1", "REQUEST\tbad id\t0", "REQUEST\t" .. string.rep("a", 65) .. "\t0", "REQUEST",
        "CURRENT\tx-1", "BEGIN\tx-1\t1\t5", secret }) do
        m.ns.OnSyncMessage("Rollover", text, "WHISPER", "Follower")
    end
    advance(2)
    assert(#delivered == mark)
end)

test("a player who is not the master declines with NOT_MASTER, without rate limit", function()
    local plain = client("Plain")
    local printMark = #plain.prints
    local id, mark = ask(plain)
    assert(messagesFrom("Plain", "ERROR", mark)[1] == "ERROR\t" .. id .. "\tNOT_MASTER" and #delivered == mark + 1)
    assert(printedSince(plain, printMark):find("not the master", 1, true))
    assert(plain.ns.SelectMaster("Master"))
    local _, second = ask(plain, "Follower", 5)
    assert(#messagesFrom("Plain", "ERROR", second) == 1)
end)

test("a busy send queue answers BUSY instead of queueing more streams", function()
    local busy = member("Busy")
    assert(busy.ns.SelectMaster("Busy") and busy.ns.SetModifier("Busy", 1))
    advance(1)
    busy.result = 11 -- restricted communication: nothing leaves the queue
    local mark = #delivered
    for _, sender in ipairs({ "Follower", "ZeroMember", "ThirdMember" }) do
        busy.ns.OnSyncMessage("Rollover", "REQUEST\tq-" .. sender .. "\t0", "WHISPER", sender)
    end
    advance(2)
    assert(count(busy, busy.ns.L.DEFERRED) == 1)
    busy.result = 0
    advance(30)
    assert(#messagesFrom("Busy", "BEGIN", mark) == 2)
    assert(messagesFrom("Busy", "ERROR", mark)[1] == "ERROR\tq-ThirdMember\tBUSY")
end)

test("queued streams are dropped when the master stops being the master", function()
    local lost = member("Lost")
    assert(lost.ns.SelectMaster("Lost") and lost.ns.SetModifier("Lost", 1))
    advance(1)
    lost.result = 11
    local _, mark = ask(lost)
    lost.ns.db.sync.master = "Follower"
    lost.result = 0
    advance(10)
    assert(#delivered == mark)
end)

test("large rosters are packed into several VALUE messages with contiguous indexes", function()
    local big = client("Big Master")
    big.roster = { "Big Master" }
    for i = 1, 99 do big.roster[#big.roster + 1] = string.format("Guild Member Number %03d", i) end
    assert(big.ns.SelectMaster("Big Master"))
    for i = 2, #big.roster do assert(big.ns.SetModifier(big.roster[i], i * 1.5)) end
    big.roster[#big.roster + 1] = "Follower"
    advance(1)
    local id, mark = ask(big)
    advance(20) -- the stream is paced at one message per 0.2 s
    local values, nextIndex = messagesFrom("Big Master", "VALUE", mark), 1
    for _, text in ipairs(values) do
        local fields = {}
        for field in (text .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
        assert(fields[2] == id and tonumber(fields[3]) == nextIndex and #fields % 2 == 1)
        nextIndex = nextIndex + (#fields - 3) / 2
    end
    assert(#values > 1 and nextIndex == 102, #values .. " " .. nextIndex)
    assert(messagesFrom("Big Master", "END", mark)[1] == "END\t" .. id .. "\t101")
end)

test("becoming master announces the data stamp to the guild", function()
    local alpha = client("Alpha")
    alpha.roster = { "Alpha", "Beta" }
    alpha.ns.db.modifiers.Alpha = 4 -- data that exists before the player becomes master
    alpha.ns.TouchModifiers()
    local mark = #delivered
    assert(alpha.ns.SelectMaster("Alpha"))
    advance(1)
    local announce = delivered[mark + 1]
    assert(#delivered == mark + 1 and announce.channel == "GUILD")
    assert(announce.text:match("^ANNOUNCE\t[%w%-]+\t" .. alpha.ns.GetUpdatedAt() .. "$"), announce.text)
end)

test("nothing is announced without data, without being master or without the prefix", function()
    local mark = #delivered
    local blank = member("Blank")
    assert(blank.ns.SelectMaster("Blank") and blank.ns.GetUpdatedAt() == 0)
    local bystander = member("Bystander")
    assert(bystander.ns.SelectMaster("Master"))
    bystander.ns.TouchModifiers()
    local noPrefix = member("NoPrefix")
    noPrefix.prefix = false
    noPrefix.ns.InitGuildSync()
    noPrefix.ns.TouchModifiers()
    assert(noPrefix.ns.SelectMaster("NoPrefix"))
    blank.ns.AnnounceMaster()
    bystander.ns.AnnounceMaster()
    advance(5)
    assert(#delivered == mark)
end)
