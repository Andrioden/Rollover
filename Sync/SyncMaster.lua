local addonName, ns = ...

-- Master side of the sync: announces the master's data stamp and serves follower requests.
local Sync = ns.Sync
local Message, Integer, Enqueue = Sync.Message, Sync.Integer, Sync.Enqueue
local recentRequests = {}

-- Tells every online guild member the new master's updatedAt. Followers that picked this player
-- as master earlier (while they were offline or not yet master) then run a normal check.
function ns.AnnounceMaster()
    if not Sync.IsReady() or not IsInGuild() or not ns.IsMaster() or ns.GetUpdatedAt() == 0 then return end
    Enqueue({
        channel = "GUILD", current = ns.IsMaster,
        messages = { Message("ANNOUNCE", Sync.NewID(), ns.GetUpdatedAt()) },
    })
end

local function SendError(sender, id, code)
    local reasons = { NOT_MASTER = ns.L.NOT_MASTER_LOCAL, BUSY = ns.L.REQUESTED_TOO_SOON, INVALID_TRANSFER = ns.L.INVALID_TRANSFER }
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
    if ns.IsMaster() then
        if have == ns.GetUpdatedAt() then
            if Sync.QueueLength() >= 2 then ns.Debug("Dropped CURRENT reply: send queue is busy"); return end
            ns.Debug(sender .. " is up to date")
            Enqueue({ target = sender, current = ns.IsMaster, messages = { Message("CURRENT", id) } })
            return
        end
    end
    -- Declined before the rate limit, so a follower is not locked out right after this player
    -- becomes master (see ns.AnnounceMaster).
    if not ns.IsMaster() then SendError(sender, id, "NOT_MASTER"); return end
    local now = GetTime()
    if recentRequests[sender] and now - recentRequests[sender] < 30 then
        SendError(sender, id, "BUSY")
        return
    end
    recentRequests[sender] = now
    if Sync.QueueLength() >= 2 then SendError(sender, id, "BUSY"); return end
    local modifiers = CopyTable(ns.db.modifiers)
    for _, entry in ipairs(ns.GetRosterList("name", true)) do
        if modifiers[entry.name] == nil then modifiers[entry.name] = 0 end
    end
    local valid = ns.ValidateModifierState(modifiers)
    if not valid then SendError(sender, id, "INVALID_TRANSFER"); return end
    local names = {}
    for name in pairs(modifiers) do names[#names + 1] = name end
    table.sort(names)
    local messages = { Message("BEGIN", id, #names, ns.GetUpdatedAt()) }
    for _, message in ipairs(ValueMessages(id, names, modifiers)) do messages[#messages + 1] = message end
    messages[#messages + 1] = Message("END", id, #names)
    if Enqueue({ target = sender, current = ns.IsMaster, messages = messages }) then
        ns.Print(string.format(ns.L.SYNC_REQUESTED, sender, #names))
    end
end

-- REQUEST [have]: `have` is the requester's updatedAt, so an up-to-date follower gets CURRENT.
function ns.OnSyncRequest(member, id, fields)
    local have
    if #fields == 3 then
        have = Integer(fields[3], Sync.MAX_STAMP)
        if not have then return end
    elseif #fields ~= 2 then
        return
    end
    Respond(member, id, have)
end
