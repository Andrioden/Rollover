local addonName, ns = ...

-- Follower side of the sync: selecting a master, manual/automatic requests, and receiving and
-- applying the master's stream.
local Sync = ns.Sync
local Message, Integer, Enqueue = Sync.Message, Sync.Integer, Sync.Enqueue
local TIMEOUT, MAX_MEMBERS, MAX_STAMP, MAX_QUEUE = Sync.TIMEOUT, Sync.MAX_MEMBERS, Sync.MAX_STAMP, Sync.MAX_QUEUE
-- Automatic checks: how long to wait for the master's reply, cooldown between checks,
-- and delays that let a freshly loaded roster/master addon settle.
local CHECK_TIMEOUT, CHECK_RETRY_DELAY, CHECK_COOLDOWN = 15, 5, 60
local LOGIN_DELAY, ONLINE_DELAY = 2, 5
-- Followers answering a master announcement wait a random time so they do not all hit the
-- master's small send queue at once. The spread grows with the number of online guild members.
local ANNOUNCE_DELAY, ANNOUNCE_SPREAD_PER_MEMBER, ANNOUNCE_MAX_SPREAD = 1, 0.5, 30
local pending
local masterOnline, awaitingLogin, lastAutoCheck
-- Master stamp of the last "older than yours" rejection, so automatic checks warn once per stamp.
local rejectedStamp

-- Ends the active transfer with a chat message. The received values are only applied at END, so
-- a failed or cancelled transfer never changes local data. Automatic checks that fail before
-- BEGIN (nothing was announced to the player yet) only log to the debug window.
local function EndTransfer(message)
    local quiet = pending.auto and pending.count == nil
    pending = nil
    if quiet then ns.Debug(message) else ns.Print(message) end
    ns.RefreshRoster()
end

local function Fail(message)
    EndTransfer(string.format(ns.L.SYNC_FAILED, message))
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

-- Requests send the local updatedAt so an up-to-date master answers CURRENT instead of streaming.
local AutoCheck
local function StartRequest(auto, attempt)
    local transfer = {
        id = Sync.NewID(),
        sender = ns.db.sync.master, received = 0, modifiers = {}, auto = auto,
        have = ns.GetUpdatedAt(),
    }
    pending = transfer
    local request = transfer.have and Message("REQUEST", transfer.id, transfer.have) or Message("REQUEST", transfer.id)
    Enqueue({
        target = transfer.sender, messages = { request },
        current = function() return pending == transfer end,
        quiet = function() return transfer.auto and not transfer.count end,
        fail = function(message)
            if pending == transfer then Fail(message) else ns.Print(message) end
        end,
    })
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

-- An "announced" check follows a master announcement: the master is known to be online even if
-- the roster has not caught up yet, and the announcement bypasses the cooldown.
AutoCheck = function(attempt, announced)
    local source = ns.db.sync.master
    if not Sync.IsReady() or pending or not source or not IsInGuild() or ns.IsMaster() then return end
    if not announced and ns.IsGuildMemberOnline(source) ~= true then
        ns.Debug("Automatic sync check skipped: master offline")
        return
    end
    if Sync.QueueLength() >= MAX_QUEUE then return end
    if attempt == 1 then
        local now = GetTime()
        if lastAutoCheck and not announced and now - lastAutoCheck < CHECK_COOLDOWN then
            ns.Debug("Automatic sync check skipped: cooldown")
            return
        end
        lastAutoCheck = now
    end
    ns.Debug("Automatic sync check with " .. source)
    StartRequest(true, attempt)
end

function ns.SelectMaster(name)
    if pending then ns.Print(ns.L.BUSY); return false end
    name = ns.ResolveGuildMember(name)
    if not name then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if name == ns.db.sync.master then return true end
    ns.db.sync.master = name
    masterOnline = nil
    if ns.IsMaster() then
        ns.Print(ns.L.LOCAL_MASTER)
        ns.AnnounceMaster()
    else
        masterOnline = ns.IsGuildMemberOnline(name)
        if masterOnline then
            ns.Print(string.format(ns.L.MASTER_SET, name))
            ns.RequestSync()
        else
            ns.Print(string.format(ns.L.MASTER_OFFLINE, name))
        end
    end
    ns.RefreshRoster()
    return true
end

function ns.RequestSync()
    if not Sync.IsReady() then ns.Print(ns.L.PREFIX_FAILED); return false end
    if pending then ns.Print(ns.L.BUSY); return false end
    local source = ns.db.sync.master
    if not source then ns.Print(ns.L.SELECT_MASTER); return false end
    if ns.IsMaster() then ns.Print(ns.L.LOCAL_MASTER); return false end
    if not IsInGuild() then ns.Print(ns.L.NO_GUILD); return false end
    if not ns.ResolveGuildMember(source) then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if Sync.QueueLength() >= MAX_QUEUE then ns.Print(ns.L.BUSY); return false end
    StartRequest(false, 1)
    ns.Print(string.format(ns.L.REQUESTING, source))
    return true
end

-- A transfer cannot continue once its master left the guild roster.
function ns.OnSyncContextChanged()
    if pending and not ns.ResolveGuildMember(pending.sender) then Fail(ns.L.NO_GUILD) end
end

-- Roster updates also announce guild members coming online (verified on the Forever beta),
-- so a master logging in is detected as an offline -> online change of the last snapshot.
function ns.OnGuildRosterUpdate()
    ns.OnSyncContextChanged()
    local source = ns.db.sync.master
    if not source or ns.IsMaster() then
        masterOnline, awaitingLogin = nil, false
        return
    end
    local online = ns.IsGuildMemberOnline(source)
    if online == nil then return end
    local was = masterOnline
    masterOnline = online
    if awaitingLogin then
        awaitingLogin = false
        if online then C_Timer.After(LOGIN_DELAY, function() AutoCheck(1) end) end
    elseif was == false and online then
        C_Timer.After(ONLINE_DELAY, function() AutoCheck(1) end)
    end
end

-- Login/reload: check once the roster shows whether the master is online.
function ns.OnPlayerEnteringWorld(isLogin, isReload)
    if not (isLogin or isReload) or not ns.db.sync.master then return end
    awaitingLogin = true
    ns.RequestGuildRoster()
end

-- Only the master this player selected is followed. A newer updatedAt means the master has data
-- we have not synced, which the normal request/CURRENT/stream check settles. Older or equal
-- announcements are ignored: data only moves forward.
local function AnnounceDelay()
    local online = 0
    for i = 1, GetNumGuildMembers() do
        if select(9, GetGuildRosterInfo(i)) then online = online + 1 end
    end
    local spread = math.min(math.max(online * ANNOUNCE_SPREAD_PER_MEMBER, 1), ANNOUNCE_MAX_SPREAD)
    return ANNOUNCE_DELAY + math.random() * spread
end

local function OnAnnounce(member, stamp)
    if member ~= ns.db.sync.master or ns.IsMaster() or stamp <= ns.GetUpdatedAt() then return end
    masterOnline = true
    ns.Debug(member .. " announced newer modifiers")
    C_Timer.After(AnnounceDelay(), function()
        if ns.db.sync.master == member and stamp > ns.GetUpdatedAt() then AutoCheck(1, true) end
    end)
end

function ns.OnSyncAnnounce(member, fields)
    local stamp = #fields == 3 and Integer(fields[3], MAX_STAMP)
    if stamp then OnAnnounce(member, stamp) end
end

-- Handles the master's reply to the active request (BEGIN, VALUE, END, CURRENT, ERROR).
function ns.OnSyncReply(member, id, fields)
    if not pending or member ~= pending.sender or id ~= pending.id then return end
    if fields[1] == "BEGIN" then
        local count = #fields == 4 and Integer(fields[3], MAX_MEMBERS)
        local stamp = #fields == 4 and Integer(fields[4], MAX_STAMP)
        if not count or not stamp or pending.count then Fail(ns.L.INVALID_TRANSFER); return end
        -- Data only moves forward: a master older than the local data is refused, however it got to be
        -- master (Tools > Reset data is the deliberate way around this). Automatic checks stay quiet
        -- when the same stale stamp was already reported.
        local own = ns.GetUpdatedAt()
        if stamp < own then
            if not (pending.auto and rejectedStamp == stamp) then pending.auto = nil end
            rejectedStamp = stamp
            Fail(string.format(ns.L.STALE_MASTER, member, ns.FormatStamp(stamp), ns.FormatStamp(own)))
            return
        end
        -- Values are buffered; local data and its updatedAt are replaced together at END.
        pending.count, pending.updatedAt = count, stamp
        ns.Print(string.format(ns.L.RECEIVING, count, member))
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
                or pending.modifiers[name] or seen[name] then
                Fail(ns.L.INVALID_TRANSFER)
                return
            end
            seen[name] = true
            entries[#entries + 1] = { name = name, value = value }
        end
        for _, entry in ipairs(entries) do pending.modifiers[entry.name] = entry.value end
        pending.received = last
        ns.Print(string.format(ns.L.RECEIVED_ENTRIES, last, pending.count))
    elseif fields[1] == "END" then
        local count = #fields == 3 and Integer(fields[3], MAX_MEMBERS)
        if not pending.count or count ~= pending.count or pending.received ~= count then
            Fail(ns.L.INVALID_TRANSFER)
            return
        end
        -- The backup is taken right before the local table is replaced.
        ns.SaveBackup(pending.auto and "auto sync" or "sync")
        ns.db.modifiers = pending.modifiers
        ns.db.sync.updatedAt = pending.updatedAt
        pending = nil
        ns.Print(string.format(ns.L.SYNCED, count, member))
        ns.RefreshRoster()
    elseif fields[1] == "CURRENT" then
        if #fields ~= 2 or pending.count then Fail(ns.L.INVALID_TRANSFER); return end
        local auto = pending.auto
        pending = nil
        if auto then
            ns.Debug(member .. " has no newer modifiers")
        else
            ns.Print(string.format(ns.L.UP_TO_DATE, member))
        end
        ns.RefreshRoster()
    elseif fields[1] == "ERROR" then
        local errors = { NOT_MASTER = ns.L.NOT_MASTER, BUSY = ns.L.MASTER_BUSY, INVALID_TRANSFER = ns.L.INVALID_TRANSFER }
        Fail(#fields == 3 and errors[fields[3]] or ns.L.INVALID_TRANSFER)
    else
        Fail(ns.L.INVALID_TRANSFER)
    end
end
