local addonName, ns = ...

local PREFIX = "Rollover"
local TIMEOUT, MAX_MEMBERS = 1800, ns.MAX_MEMBERS
-- The server allows a burst of ~10 messages per prefix, then 1/sec; throttled sends retry.
local SEND_INTERVAL, THROTTLE_RETRY, LOCKDOWN_RETRY = 0.2, 1, 5
-- Automatic checks: how long to wait for the publisher's reply, cooldown between checks,
-- and delays that let a freshly loaded roster/publisher addon settle.
local CHECK_TIMEOUT, CHECK_RETRY_DELAY, CHECK_COOLDOWN = 15, 5, 60
local LOGIN_DELAY, ONLINE_DELAY = 2, 5
local MAX_STAMP = 2 ^ 40
local queue, recentRequests = {}, {}
local pending, timer, ready
local sequence = 0
local publisherOnline, awaitingLogin, lastAutoCheck

-- Ends the active transfer with a chat message. Once BEGIN arrived the local table was
-- cleared, so the player is also told that the data may be incomplete. Automatic checks
-- that fail before BEGIN only log to the debug window.
local function EndTransfer(message)
    local started = pending.count ~= nil
    local quiet = pending.auto and not started
    pending = nil
    if quiet then ns.Debug(message) else ns.Print(message) end
    if started then ns.Print(ns.L.PARTIAL_CHANGES) end
    ns.RefreshRoster()
end

local function Fail(message)
    EndTransfer(string.format(ns.L.SYNC_FAILED, message))
end

local function Message(kind, id, ...)
    local fields = { kind, id, ... }
    for i = 1, #fields do fields[i] = tostring(fields[i]) end
    return table.concat(fields, "\t")
end

local function Integer(text, maximum)
    if not text or not text:match("^%d+$") then return end
    local value = tonumber(text)
    if value and value <= maximum then return value end
end

local Pump
local function Schedule(delay)
    if timer then return end
    timer = C_Timer.NewTimer(delay, function()
        timer = nil
        Pump()
    end)
end

local function Enqueue(task)
    if #queue >= 3 then ns.Debug("Sync send queue is full"); return false end
    task.index, task.expires = 1, GetTime() + TIMEOUT
    queue[#queue + 1] = task
    Schedule(0)
    return true
end

-- Queued messages are dropped once their target left the roster, their request ended,
-- or the owner of a snapshot stopped publishing.
local function IsCurrent(task)
    if not ns.ResolveGuildMember(task.target) then return false end
    if task.request then return pending == task.request end
    return not task.snapshot or ns.IsPublisher()
end

Pump = function()
    local task = queue[1]
    if not task then return end
    if not IsCurrent(task) or GetTime() >= task.expires then
        table.remove(queue, 1)
        ns.Debug("Dropped queued sync message for " .. task.target)
    else
        local result = C_ChatInfo.SendAddonMessage(PREFIX, task.messages[task.index], "WHISPER", task.target)
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
                if task.request and task.request.auto and not task.request.count then
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
            if task.request and pending == task.request then Fail(message) else ns.Print(message) end
        end
    end
    if #queue > 0 then Schedule(SEND_INTERVAL) end
end

local function FormatEntry(name, value)
    return string.format("%s (%s)", name, value > 0 and "+" .. value or tostring(value))
end

function ns.IsSyncPending()
    return pending ~= nil
end

function ns.CancelSync()
    if pending then
        pending.auto = nil -- the player asked for this, so report it
        EndTransfer(ns.L.SYNC_CANCELLED)
    end
end

-- Automatic checks send the stored updatedAt so an up-to-date publisher answers CURRENT
-- instead of streaming. Manual and publisher-change syncs omit it and always stream.
local AutoCheck
local function StartRequest(auto, attempt)
    sequence = sequence + 1
    local transfer = {
        id = string.format("%d-%d", GetServerTime(), sequence),
        sender = ns.db.sync.publisher, received = 0, names = {}, auto = auto,
        have = auto and ns.db.sync.updatedAt or nil,
    }
    pending = transfer
    local request = transfer.have and Message("REQUEST", transfer.id, transfer.have) or Message("REQUEST", transfer.id)
    Enqueue({ target = transfer.sender, request = transfer, messages = { request } })
    ns.RefreshRoster()
    C_Timer.After(TIMEOUT, function()
        if pending == transfer then Fail(ns.L.TIMEOUT) end
    end)
    if auto then
        C_Timer.After(CHECK_TIMEOUT, function()
            if pending ~= transfer or transfer.count then return end
            pending = nil
            ns.Debug("Automatic sync check timed out")
            ns.RefreshRoster()
            if attempt < 2 then C_Timer.After(CHECK_RETRY_DELAY, function() AutoCheck(attempt + 1) end) end
        end)
    end
end

AutoCheck = function(attempt)
    local source = ns.db.sync.publisher
    if not ready or pending or not source or not IsInGuild() or ns.IsPublisher() then return end
    if ns.IsGuildMemberOnline(source) ~= true then ns.Debug("Automatic sync check skipped: publisher offline"); return end
    if #queue >= 3 then return end
    if attempt == 1 then
        local now = GetTime()
        if lastAutoCheck and now - lastAutoCheck < CHECK_COOLDOWN then
            ns.Debug("Automatic sync check skipped: cooldown")
            return
        end
        lastAutoCheck = now
    end
    ns.Debug("Automatic sync check with " .. source)
    StartRequest(true, attempt)
end

function ns.SelectPublisher(name)
    if pending then ns.Print(ns.L.BUSY); return false end
    name = ns.ResolveGuildMember(name)
    if not name then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if name == ns.db.sync.publisher then return true end
    ns.db.sync.publisher = name
    publisherOnline = nil
    if ns.IsPublisher() then
        if not ns.db.sync.updatedAt then ns.TouchModifiers() end
        ns.Print(ns.L.LOCAL_PUBLISHER)
    else
        -- The local table came from somewhere else, so the new publisher must always stream.
        ns.db.sync.updatedAt = nil
        publisherOnline = ns.IsGuildMemberOnline(name)
        if publisherOnline then
            ns.Print(string.format(ns.L.PUBLISHER_SET, name))
            ns.RequestSync()
        else
            ns.Print(string.format(ns.L.PUBLISHER_OFFLINE, name))
        end
    end
    ns.RefreshRoster()
    return true
end

function ns.RequestSync()
    if not ready then ns.Print(ns.L.PREFIX_FAILED); return false end
    if pending then ns.Print(ns.L.BUSY); return false end
    local source = ns.db.sync.publisher
    if not source then ns.Print(ns.L.SELECT_PUBLISHER); return false end
    if ns.IsPublisher() then ns.Print(ns.L.LOCAL_PUBLISHER); return false end
    if not IsInGuild() then ns.Print(ns.L.NO_GUILD); return false end
    if not ns.ResolveGuildMember(source) then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if #queue >= 3 then ns.Print(ns.L.BUSY); return false end
    StartRequest(false, 1)
    ns.Print(string.format(ns.L.REQUESTING, source))
    return true
end

local function SendError(sender, id, code)
    local reasons = { NOT_PUBLISHER = ns.L.NOT_PUBLISHING_LOCAL, BUSY = ns.L.BUSY, INVALID_TRANSFER = ns.L.INVALID_TRANSFER }
    ns.Print(string.format(ns.L.SYNC_DECLINED, sender, reasons[code]))
    Enqueue({ target = sender, messages = { Message("ERROR", id, code) } })
end

-- Packs as many name/value pairs into each VALUE message as fit in 255 bytes:
-- VALUE, id, index of the first entry, then name, value, name, value, ...
local function ValueMessages(id, names, modifiers)
    local messages, current, first = {}, nil, nil
    for i, name in ipairs(names) do
        local entry = "\t" .. name .. "\t" .. string.format("%.17g", modifiers[name])
        if current and #current + #entry > 255 then
            messages[#messages + 1] = current
            current = nil
        end
        current = (current or Message("VALUE", id, i)) .. entry
    end
    if current then messages[#messages + 1] = current end
    return messages
end

local function Respond(sender, id, have)
    -- An up-to-date follower costs one tiny reply, is not rate limited and is not announced.
    if ns.IsPublisher() then
        if not ns.db.sync.updatedAt then ns.TouchModifiers() end
        if have == ns.db.sync.updatedAt then
            if #queue >= 2 then ns.Debug("Dropped CURRENT reply: send queue is busy"); return end
            ns.Debug(sender .. " is up to date")
            Enqueue({ target = sender, snapshot = true, messages = { Message("CURRENT", id) } })
            return
        end
    end
    local now = GetTime()
    if recentRequests[sender] and now - recentRequests[sender] < 30 then
        SendError(sender, id, "BUSY")
        return
    end
    recentRequests[sender] = now
    if not ns.IsPublisher() then SendError(sender, id, "NOT_PUBLISHER"); return end
    if #queue >= 2 then SendError(sender, id, "BUSY"); return end
    local modifiers = CopyTable(ns.db.modifiers)
    for _, entry in ipairs(ns.GetRosterList("name", true)) do
        if modifiers[entry.name] == nil then modifiers[entry.name] = 0 end
    end
    local valid = ns.ValidateModifierState(modifiers)
    if not valid then SendError(sender, id, "INVALID_TRANSFER"); return end
    local names = {}
    for name in pairs(modifiers) do names[#names + 1] = name end
    table.sort(names)
    local messages = { Message("BEGIN", id, #names, ns.db.sync.updatedAt) }
    for _, message in ipairs(ValueMessages(id, names, modifiers)) do messages[#messages + 1] = message end
    messages[#messages + 1] = Message("END", id, #names)
    if Enqueue({ target = sender, snapshot = true, messages = messages }) then
        ns.Print(string.format(ns.L.SYNC_REQUESTED, sender, #names))
    end
end

-- A transfer cannot continue once its publisher left the guild roster.
function ns.OnSyncContextChanged()
    if pending and not ns.ResolveGuildMember(pending.sender) then Fail(ns.L.NO_GUILD) end
end

-- Roster updates also announce guild members coming online (verified on the Forever beta),
-- so a publisher logging in is detected as an offline -> online change of the last snapshot.
function ns.OnGuildRosterUpdate()
    ns.OnSyncContextChanged()
    local source = ns.db.sync.publisher
    if not source or ns.IsPublisher() then
        publisherOnline, awaitingLogin = nil, false
        return
    end
    local online = ns.IsGuildMemberOnline(source)
    if online == nil then return end
    local was = publisherOnline
    publisherOnline = online
    if awaitingLogin then
        awaitingLogin = false
        if online then C_Timer.After(LOGIN_DELAY, function() AutoCheck(1) end) end
    elseif was == false and online then
        C_Timer.After(ONLINE_DELAY, function() AutoCheck(1) end)
    end
end

-- Login/reload: check once the roster shows whether the publisher is online.
function ns.OnPlayerEnteringWorld(isLogin, isReload)
    if not (isLogin or isReload) or not ns.db.sync.publisher then return end
    awaitingLogin = true
    ns.RequestGuildRoster()
end

function ns.OnSyncMessage(prefix, text, channel, sender)
    if issecretvalue(prefix) or issecretvalue(text) or issecretvalue(channel) or issecretvalue(sender) then return end
    if prefix ~= PREFIX or channel ~= "WHISPER" or type(text) ~= "string"
        or #text > 255 or type(sender) ~= "string" then return end
    local member = ns.ResolveGuildMember(sender)
    if not member then return end
    local fields = {}
    for field in (text .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    local id = fields[2]
    if not id or #id > 64 or not id:match("^[%w%-]+$") then return end
    if fields[1] == "REQUEST" then
        local have
        if #fields == 3 then
            have = Integer(fields[3], MAX_STAMP)
            if not have then return end
        elseif #fields ~= 2 then
            return
        end
        Respond(member, id, have)
        return
    end
    if not pending or member ~= pending.sender or id ~= pending.id then return end
    if fields[1] == "BEGIN" then
        local count = #fields == 4 and Integer(fields[3], MAX_MEMBERS)
        local stamp = #fields == 4 and Integer(fields[4], MAX_STAMP)
        if not count or not stamp or pending.count then Fail(ns.L.INVALID_TRANSFER); return end
        -- The backup is taken here, right before the local table is replaced.
        ns.SaveBackup(pending.auto)
        pending.count, pending.updatedAt = count, stamp
        ns.db.modifiers = {}
        -- Stays empty unless END arrives, so an incomplete transfer is repaired by the next check.
        ns.db.sync.updatedAt = nil
        ns.Print(string.format(ns.L.RECEIVING, count, member))
        ns.RefreshRoster()
    elseif fields[1] == "VALUE" then
        local index = #fields >= 5 and #fields % 2 == 1 and Integer(fields[3], MAX_MEMBERS)
        local last = index and index + (#fields - 3) / 2 - 1
        if not pending.count or not index or index ~= pending.received + 1 or last > pending.count then
            Fail(ns.L.INVALID_TRANSFER)
            return
        end
        local entries, seen = {}, {}
        for i = 4, #fields, 2 do
            local name, value = fields[i], tonumber(fields[i + 1])
            if not ns.IsValidMemberName(name) or not ns.IsValidModifier(value)
                or pending.names[name] or seen[name] then
                Fail(ns.L.INVALID_TRANSFER)
                return
            end
            seen[name] = true
            entries[#entries + 1] = { name = name, value = value }
        end
        local labels = {}
        for _, entry in ipairs(entries) do
            pending.names[entry.name] = true
            ns.db.modifiers[entry.name] = entry.value
            labels[#labels + 1] = FormatEntry(entry.name, entry.value)
        end
        pending.received = last
        ns.Print(string.format(ns.L.SYNCED_ENTRIES, last, pending.count, table.concat(labels, ", ")))
        ns.RefreshRoster()
    elseif fields[1] == "END" then
        local count = #fields == 3 and Integer(fields[3], MAX_MEMBERS)
        if not pending.count or count ~= pending.count or pending.received ~= count then
            Fail(ns.L.INVALID_TRANSFER)
            return
        end
        ns.db.sync.updatedAt = pending.updatedAt
        pending = nil
        ns.Print(string.format(ns.L.SYNCED, count, member))
        ns.RefreshRoster()
    elseif fields[1] == "CURRENT" then
        if #fields ~= 2 or pending.count or not pending.have then Fail(ns.L.INVALID_TRANSFER); return end
        pending = nil
        ns.Debug(member .. " has no newer modifiers")
        ns.RefreshRoster()
    elseif fields[1] == "ERROR" then
        local errors = { NOT_PUBLISHER = ns.L.NOT_PUBLISHER, BUSY = ns.L.BUSY, INVALID_TRANSFER = ns.L.INVALID_TRANSFER }
        Fail(#fields == 3 and errors[fields[3]] or ns.L.INVALID_TRANSFER)
    else
        Fail(ns.L.INVALID_TRANSFER)
    end
end

function ns.InitGuildSync()
    ready = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    if not ready then ns.Print(ns.L.PREFIX_FAILED) end
end
