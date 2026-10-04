-- Run with a standalone Lua interpreter: lua Tests\SyncMasterTests.lua <addon directory>
-- Covers the master side (Sync\SyncMaster.lua) alone: there is no follower client, so requests are
-- injected by hand and the messages the master sends are read from the delivered log.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local count, last, printedSince = harness.count, harness.last, harness.printedSince
local delivered, secret = harness.delivered, harness.secret
local messagesFrom = harness.messagesFrom
local test = harness.suite("Sync\\SyncMaster.lua")

-- A client whose roster includes itself, so it can select itself as master.
local function member(name)
    local c = client(name)
    c.roster = { name, "Master", "Follower", "ZeroMember", "ThirdMember" }
    return c
end

local sequence = 0
-- Sends a REQUEST to `c` as `sender` and lets the master answer. Returns the request ID and the delivered mark.
local function ask(c, sender, have, channel)
    sequence = sequence + 1
    local id = "req-" .. sequence
    local mark = #delivered
    local text = "REQUEST\t" .. id .. (have and ("\t" .. have) or "")
    c.ns.OnSyncMessage("Rollover", text, channel or "WHISPER", sender or "Follower")
    advance(2)
    return id, mark
end

local m = client("Master")
assert(m.ns.SelectMaster("Master") and m.ns.IsMaster())
assert(m.ns.SetModifier("Master", 12.5) and m.ns.SetModifier("FormerMember", -4))
advance(1) -- lets the master announcement leave the queue

test("a request streams BEGIN, all modifiers with roster zeros, and END", function()
    local printMark = #m.prints
    local id, mark = ask(m)
    local stamp = m.ns.GetUpdatedAt()
    local sent = {}
    for i = mark + 1, #delivered do
        assert(delivered[i].target == "Follower" and delivered[i].channel == "WHISPER")
        sent[#sent + 1] = delivered[i].text
    end
    assert(sent[1] == "BEGIN\t" .. id .. "\t5\t" .. stamp, sent[1])
    assert(sent[#sent] == "END\t" .. id .. "\t5", sent[#sent])
    -- Sorted by name; roster members without saved data are included as zeros.
    assert(sent[2] == "VALUE\t" .. id .. "\t1\tFollower\t0\tFormerMember\t-4\tMaster\t12.5\tThirdMember\t0\tZeroMember\t0", sent[2])
    assert(#sent == 3)
    assert(printedSince(m, printMark):find("Follower requested a sync; sending 5 modifiers.", 1, true))
end)

test("a repeated request inside 30 seconds is answered BUSY, then served again", function()
    local printMark = #m.prints
    local id, mark = ask(m)
    local replies = messagesFrom("Master", "ERROR", mark)
    assert(#replies == 1 and replies[1] == "ERROR\t" .. id .. "\tBUSY" and #messagesFrom("Master", "BEGIN", mark) == 0)
    assert(printedSince(m, printMark):find("asked again too soon", 1, true))
    advance(31)
    local _, later = ask(m)
    assert(#messagesFrom("Master", "BEGIN", later) == 1)
end)

test("a follower that is up to date gets one CURRENT and no stream", function()
    advance(31)
    local printMark = #m.prints
    local id, mark = ask(m, "Follower", m.ns.GetUpdatedAt())
    local current = messagesFrom("Master", "CURRENT", mark)
    assert(#current == 1 and current[1] == "CURRENT\t" .. id)
    assert(#delivered == mark + 1 and #m.prints == printMark, "nothing else is sent or printed")
    -- CURRENT replies do not count against the rate limit.
    local _, again = ask(m, "Follower", m.ns.GetUpdatedAt())
    assert(#messagesFrom("Master", "CURRENT", again) == 1)
    local _, stream = ask(m, "Follower", m.ns.GetUpdatedAt() - 1)
    assert(#messagesFrom("Master", "BEGIN", stream) == 1, "an older follower is streamed")
end)

test("an unknown age streams like a fresh follower", function()
    advance(31)
    local _, mark = ask(m, "Follower", 0)
    assert(#messagesFrom("Master", "BEGIN", mark) == 1)
end)

test("malformed and misrouted requests are ignored", function()
    advance(31)
    local mark = #delivered
    ask(m, "Follower", "notanumber")
    ask(m, "Follower", "1\t2")
    ask(m, "Follower", "1099511627777") -- above the stamp bound
    m.ns.OnSyncMessage("Rollover", "REQUEST\tbad id", "WHISPER", "Follower")
    m.ns.OnSyncMessage("Rollover", "REQUEST\t" .. string.rep("a", 65), "WHISPER", "Follower")
    m.ns.OnSyncMessage("Rollover", "REQUEST", "WHISPER", "Follower")
    m.ns.OnSyncMessage("Rollover", "REQUEST\tx-1", "WHISPER", "Stranger") -- not in the guild roster
    m.ns.OnSyncMessage("Rollover", "REQUEST\tx-1", "PARTY", "Follower")
    m.ns.OnSyncMessage("Rollover", "Other\tx-1", "WHISPER", "Follower")
    m.ns.OnSyncMessage("Rollover", secret, "WHISPER", "Follower")
    ask(m, "Follower", nil, "GUILD") -- only ANNOUNCE may use the guild channel
    advance(2)
    assert(#delivered == mark)
end)

test("a master reply to a request is not mistaken for a request", function()
    local mark = #delivered
    m.ns.OnSyncMessage("Rollover", "CURRENT\tx-1", "WHISPER", "Follower")
    m.ns.OnSyncMessage("Rollover", "BEGIN\tx-1\t1\t5", "WHISPER", "Follower")
    advance(2)
    assert(#delivered == mark)
end)

test("a player who is not the master declines with NOT_MASTER", function()
    local plain = client("Plain")
    local printMark = #plain.prints
    local id, mark = ask(plain)
    local replies = messagesFrom("Plain", "ERROR", mark)
    assert(#replies == 1 and replies[1] == "ERROR\t" .. id .. "\tNOT_MASTER")
    assert(#messagesFrom("Plain", "BEGIN", mark) == 0)
    assert(printedSince(plain, printMark):find("not the master", 1, true))
    -- Also when another player is the chosen master, and without being rate limited.
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
        busy.ns.OnSyncMessage("Rollover", "REQUEST\tq-" .. sender, "WHISPER", sender)
    end
    advance(2)
    assert(count(busy, busy.ns.L.DEFERRED) == 1)
    busy.result = 0
    advance(30)
    assert(#messagesFrom("Busy", "BEGIN", mark) == 2)
    local replies = messagesFrom("Busy", "ERROR", mark)
    assert(#replies == 1 and replies[1]:find("BUSY", 1, true))
    for i = mark + 1, #delivered do
        if delivered[i].text:find("ERROR", 1, true) == 1 then assert(delivered[i].target == "ThirdMember") end
    end
end)

test("queued streams are dropped when the master stops being the master", function()
    local lost = member("Lost")
    assert(lost.ns.SelectMaster("Lost") and lost.ns.SetModifier("Lost", 1))
    advance(1)
    lost.result = 11
    local id, mark = ask(lost)
    lost.ns.db.sync.master = "Follower"
    lost.result = 0
    advance(10)
    assert(#delivered == mark)
end)

local bigRoster = { "Big Master" }
for i = 1, 99 do bigRoster[#bigRoster + 1] = string.format("Guild Member Number %03d", i) end

test("large rosters are packed into VALUE messages of at most 255 bytes", function()
    local big = client("Big Master")
    big.roster = bigRoster
    assert(big.ns.SelectMaster("Big Master"))
    for i = 2, #bigRoster do assert(big.ns.SetModifier(bigRoster[i], i * 1.5)) end
    bigRoster[#bigRoster + 1] = "Follower"
    advance(1)
    local id, mark = ask(big, "Follower")
    advance(20) -- the stream is paced at one message per 0.2 s
    local values, seen, nextIndex = 0, 0, 1
    for i = mark + 1, #delivered do
        local text = delivered[i].text
        assert(#text <= 255)
        if text:find("VALUE\t", 1, true) == 1 then
            values = values + 1
            local fields = {}
            for field in (text .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
            assert(fields[2] == id and tonumber(fields[3]) == nextIndex, "indexes are contiguous")
            local entries = (#fields - 3) / 2
            assert(entries == math.floor(entries) and entries >= 1)
            nextIndex, seen = nextIndex + entries, seen + entries
        end
    end
    assert(values > 1 and values < 30 and seen == 101, values .. " " .. seen)
    assert(#messagesFrom("Big Master", "BEGIN", mark) == 1 and messagesFrom("Big Master", "END", mark)[1] == "END\t" .. id .. "\t101")
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
    assert(announce and announce.channel == "GUILD" and #delivered == mark + 1)
    assert(announce.text:match("^ANNOUNCE\t[%w%-]+\t" .. alpha.ns.GetUpdatedAt() .. "$"), announce.text)
end)

test("nothing is announced without data or without being master", function()
    local blank = member("Blank")
    local mark = #delivered
    assert(blank.ns.SelectMaster("Blank") and blank.ns.GetUpdatedAt() == 0)
    blank.ns.AnnounceMaster()
    local bystander = member("Bystander")
    assert(bystander.ns.SelectMaster("Master"))
    bystander.ns.db.modifiers.Bystander = 1
    bystander.ns.TouchModifiers()
    bystander.ns.AnnounceMaster()
    advance(5)
    assert(#delivered == mark)
end)

test("no announcement is sent while the addon prefix is unavailable", function()
    local noPrefix = member("NoPrefix")
    noPrefix.prefix = false
    noPrefix.ns.InitGuildSync()
    assert(noPrefix.ns.SelectMaster("NoPrefix") and noPrefix.ns.SetModifier("NoPrefix", 1))
    noPrefix.ns.AnnounceMaster()
    advance(5)
    assert(#messagesFrom("NoPrefix", "ANNOUNCE") == 0)
end)
