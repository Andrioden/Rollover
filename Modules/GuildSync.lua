local addonName, ns = ...

local PREFIX, PROTOCOL = "Rollover", "1"
local TIMEOUT, MAX_MEMBERS = 1800, 1000
local queue, recentRequests = {}, {}
local pending, timer, ready
local sequence = 0

local function GuildKey()
    if not IsInGuild() then return end
    local guild, _, _, realm = GetGuildInfo("player")
    if issecretvalue(guild) or issecretvalue(realm) or type(guild) ~= "string" then return end
    realm = realm or GetNormalizedRealmName()
    if issecretvalue(realm) or type(realm) ~= "string" then return end
    return realm .. ":" .. guild
end

local function Fail(message)
    pending = nil
    ns.Print(string.format(ns.L.SYNC_FAILED, message))
    ns.RefreshRoster()
end

local function Message(kind, id, ...)
    local fields = { PROTOCOL, kind, id, ... }
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
    task.index, task.expires, task.guild = 1, GetTime() + TIMEOUT, GuildKey()
    queue[#queue + 1] = task
    Schedule(1)
    return true
end

Pump = function()
    local task = queue[1]
    if not task then return end
    local current = task.guild and task.guild == GuildKey() and ns.ResolveGuildMember(task.target)
    if task.request then current = current and pending == task.request end
    if task.snapshot then current = current and ns.IsPublisher() and task.publisher == ns.db.sync.publisher end
    if not current or GetTime() >= task.expires then
        table.remove(queue, 1)
        if task.request and pending == task.request then Fail(ns.L.TIMEOUT)
        elseif task.snapshot then ns.Print(string.format(ns.L.SYNC_FAILED, ns.L.TIMEOUT)) end
    else
        local result = C_ChatInfo.SendAddonMessage(PREFIX, task.messages[task.index], "WHISPER", task.target)
        local results = Enum.SendAddonMessageResult
        if result == results.Success then
            task.index = task.index + 1
            task.deferred = nil
            if task.index > #task.messages then table.remove(queue, 1) end
        elseif result == results.AddOnMessageLockdown or result == results.AddonMessageThrottle then
            -- Retried every 5 seconds; tell the player once per deferral.
            if not task.deferred then
                task.deferred = true
                ns.Print(ns.L.DEFERRED)
            end
            Schedule(5)
            return
        else
            table.remove(queue, 1)
            local message = string.format(ns.L.SEND_FAILED, tostring(result))
            if task.request and pending == task.request then Fail(message) else ns.Print(message) end
        end
    end
    if #queue > 0 then Schedule(1) end
end

function ns.IsSyncPending()
    return pending ~= nil
end

function ns.CancelSync()
    if pending then Fail(ns.L.SYNC_CANCELLED) end
end

function ns.SelectPublisher(name)
    if pending then ns.Print(ns.L.BUSY); return false end
    name = ns.ResolveGuildMember(name)
    if not name then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if name == ns.db.sync.publisher then return true end
    ns.db.sync.publisher = name
    if ns.IsPublisher() then
        ns.Print(ns.L.LOCAL_PUBLISHER)
    else
        ns.Print(string.format(ns.L.PUBLISHER_SET, name))
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
    local guild = GuildKey()
    if not guild then ns.Print(ns.L.NO_GUILD); return false end
    if not ns.ResolveGuildMember(source) then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if #queue >= 3 then ns.Print(ns.L.BUSY); return false end
    ns.SaveBackup()
    sequence = sequence + 1
    local transfer = {
        id = string.format("%d-%d", GetServerTime(), sequence),
        sender = source, guild = guild, received = 0, names = {},
    }
    pending = transfer
    Enqueue({ target = source, request = transfer, messages = { Message("REQUEST", transfer.id) } })
    ns.Print(string.format(ns.L.REQUESTING, source))
    ns.RefreshRoster()
    C_Timer.After(TIMEOUT, function()
        if pending == transfer then Fail(ns.L.TIMEOUT) end
    end)
    return true
end

local function SendError(sender, id, code)
    Enqueue({ target = sender, messages = { Message("ERROR", id, code) } })
end

local function Respond(sender, id)
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
    local messages = { Message("BEGIN", id, #names) }
    for i, name in ipairs(names) do
        local message = Message("VALUE", id, i, name, string.format("%.17g", modifiers[name]))
        if #message > 255 then SendError(sender, id, "INVALID_TRANSFER"); return end
        messages[#messages + 1] = message
    end
    messages[#messages + 1] = Message("END", id, #names)
    Enqueue({ target = sender, snapshot = true, publisher = ns.db.sync.publisher, messages = messages })
end

function ns.OnSyncContextChanged()
    if pending and (pending.guild ~= GuildKey()
        or not ns.ResolveGuildMember(pending.sender) or ns.db.sync.publisher ~= pending.sender) then
        Fail(ns.L.NO_GUILD)
    end
end

function ns.OnSyncMessage(prefix, text, channel, sender)
    if issecretvalue(prefix) or issecretvalue(text) or issecretvalue(channel) or issecretvalue(sender) then return end
    if prefix ~= PREFIX or channel ~= "WHISPER" or type(text) ~= "string"
        or #text > 255 or type(sender) ~= "string" then return end
    local member = ns.ResolveGuildMember(sender)
    if not member or not GuildKey() then return end
    local fields = {}
    for field in (text .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    local id = fields[3]
    if not id or #id > 64 or not id:match("^[%w%-]+$") then return end
    if fields[1] ~= PROTOCOL then
        if pending and member == pending.sender and id == pending.id then Fail(ns.L.INCOMPATIBLE) end
        return
    end
    if fields[2] == "REQUEST" then
        if #fields == 3 then Respond(member, id) end
        return
    end
    if not pending or member ~= pending.sender or id ~= pending.id
        or pending.guild ~= GuildKey() or ns.db.sync.publisher ~= member then return end
    if fields[2] == "BEGIN" then
        local count = #fields == 4 and Integer(fields[4], MAX_MEMBERS)
        if not count or pending.count then Fail(ns.L.INVALID_TRANSFER); return end
        pending.count = count
        ns.db.modifiers = {}
        ns.Print(string.format(ns.L.RECEIVING, count, member))
        ns.RefreshRoster()
    elseif fields[2] == "VALUE" then
        local index = #fields == 6 and Integer(fields[4], MAX_MEMBERS)
        local name, value = fields[5], tonumber(fields[6])
        if not pending.count or not index or index ~= pending.received + 1 or index > pending.count
            or not ns.IsValidMemberName(name) or not ns.IsValidModifier(value) or pending.names[name] then
            Fail(ns.L.INVALID_TRANSFER)
            return
        end
        pending.names[name] = true
        pending.received = index
        ns.db.modifiers[name] = value
        ns.RefreshRoster()
    elseif fields[2] == "END" then
        local count = #fields == 4 and Integer(fields[4], MAX_MEMBERS)
        if not pending.count or count ~= pending.count or pending.received ~= count then
            Fail(ns.L.INVALID_TRANSFER)
            return
        end
        pending = nil
        ns.Print(string.format(ns.L.SYNCED, count, member))
        ns.RefreshRoster()
    elseif fields[2] == "ERROR" then
        local errors = { NOT_PUBLISHER = ns.L.NOT_PUBLISHER, BUSY = ns.L.BUSY, INVALID_TRANSFER = ns.L.INVALID_TRANSFER }
        Fail(#fields == 4 and errors[fields[4]] or ns.L.INVALID_TRANSFER)
    else
        Fail(ns.L.INVALID_TRANSFER)
    end
end

function ns.InitGuildSync()
    ready = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    if not ready then ns.Print(ns.L.PREFIX_FAILED) end
end
