local addonName, ns = ...

-- Shared sync transport: message helpers, the bounded send queue and the message router.
-- SyncMaster.lua serves data, SyncClient.lua requests and applies it; both use ns.Sync.
local PREFIX = "Rollover"
local TIMEOUT, MAX_MEMBERS = 1800, ns.MAX_MEMBERS
-- The server allows a burst of ~10 messages per prefix, then 1/sec; throttled sends retry.
local SEND_INTERVAL, THROTTLE_RETRY, LOCKDOWN_RETRY = 0.2, 1, 5
local MAX_QUEUE = 3
local queue = {}
local timer, ready
local sequence = 0

local Sync = {
    TIMEOUT = TIMEOUT,
    MAX_MEMBERS = MAX_MEMBERS,
    MAX_STAMP = 2 ^ 40,
    MAX_QUEUE = MAX_QUEUE,
}
ns.Sync = Sync

function Sync.Message(kind, id, ...)
    local fields = { kind, id, ... }
    for i = 1, #fields do fields[i] = tostring(fields[i]) end
    return table.concat(fields, "\t")
end

function Sync.Integer(text, maximum)
    if not text or not text:match("^%d+$") then return end
    local value = tonumber(text)
    if value and value <= maximum then return value end
end

function Sync.NewID()
    sequence = sequence + 1
    return string.format("%d-%d", GetServerTime(), sequence)
end

function Sync.IsReady()
    return ready
end

function Sync.QueueLength()
    return #queue
end

local Pump
local function Schedule(delay)
    if timer then return end
    timer = C_Timer.NewTimer(delay, function()
        timer = nil
        Pump()
    end)
end

-- A task is { target | channel, messages, current?, quiet?, fail? }:
-- current() tells whether the task is still wanted (checked before every send),
-- quiet() makes the lockdown deferral debug-only, fail(message) reports a send error
-- (default: chat message).
function Sync.Enqueue(task)
    if #queue >= MAX_QUEUE then ns.Debug("Sync send queue is full"); return false end
    task.index, task.expires = 1, GetTime() + TIMEOUT
    queue[#queue + 1] = task
    Schedule(0)
    return true
end

-- Queued messages are dropped once their target left the roster or the owner says they are stale.
local function IsCurrent(task)
    if task.target and not ns.ResolveGuildMember(task.target) then return false end
    return not task.current or task.current()
end

Pump = function()
    local task = queue[1]
    if not task then return end
    if not IsCurrent(task) or GetTime() >= task.expires then
        table.remove(queue, 1)
        ns.Debug("Dropped queued sync message for " .. (task.target or task.channel))
    else
        local result = C_ChatInfo.SendAddonMessage(PREFIX, task.messages[task.index], task.channel or "WHISPER", task.target)
        local results = Enum.SendAddonMessageResult
        if result == results.Success then
            task.index = task.index + 1
            task.deferred = nil
            if task.index > #task.messages then table.remove(queue, 1) end
        elseif result == results.AddonMessageThrottle then
            -- Normal once the burst allowance is used up; it regains 1 message per second.
            ns.Debug("Sync send throttled; retrying")
            Schedule(THROTTLE_RETRY)
            return
        elseif result == results.AddOnMessageLockdown then
            -- Tell the player once per deferral.
            if not task.deferred then
                task.deferred = true
                if task.quiet and task.quiet() then
                    ns.Debug("Automatic sync check deferred: communication restricted")
                else
                    ns.Print(ns.L.DEFERRED)
                end
            end
            Schedule(LOCKDOWN_RETRY)
            return
        else
            table.remove(queue, 1)
            local message = string.format(ns.L.SEND_FAILED, tostring(result))
            if task.fail then task.fail(message) else ns.Print(message) end
        end
    end
    if #queue > 0 then Schedule(SEND_INTERVAL) end
end

-- Validates the envelope, then routes by message type: ANNOUNCE and replies to the follower side,
-- REQUEST to the master side.
function ns.OnSyncMessage(prefix, text, channel, sender)
    if issecretvalue(prefix) or issecretvalue(text) or issecretvalue(channel) or issecretvalue(sender) then return end
    if prefix ~= PREFIX or (channel ~= "WHISPER" and channel ~= "GUILD") or type(text) ~= "string"
        or #text > 255 or type(sender) ~= "string" then return end
    local member = ns.ResolveGuildMember(sender)
    if not member then return end
    local fields = {}
    for field in (text .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    local id = fields[2]
    if not id or #id > 64 or not id:match("^[%w%-]+$") then return end
    -- ANNOUNCE is the only message sent to the guild channel, and the only one accepted from it.
    if (fields[1] == "ANNOUNCE") ~= (channel == "GUILD") then return end
    if fields[1] == "ANNOUNCE" then
        ns.OnSyncAnnounce(member, fields)
    elseif fields[1] == "REQUEST" then
        ns.OnSyncRequest(member, id, fields)
    else
        ns.OnSyncReply(member, id, fields)
    end
end

function ns.InitGuildSync()
    ready = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    if not ready then ns.Print(ns.L.PREFIX_FAILED) end
end
