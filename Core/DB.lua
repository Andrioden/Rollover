local addonName, ns = ...

local MAX_JSON_BYTES = 200000
ns.MAX_MEMBERS = 1000
ns.MAX_AUTO_BACKUPS = 10

local defaults = {
    version = 1,
    modifiers = {}, -- [guild roster name] = number
    backups = {}, -- [date-time] = { name, updatedAt, modifiers }
    sync = {}, -- { master = guild roster name, updatedAt = server time of the last real modifier change }
}

function ns.InitDB()
    RolloverDB = RolloverDB or {}
    for k, v in pairs(defaults) do
        if RolloverDB[k] == nil then
            RolloverDB[k] = type(v) == "table" and CopyTable(v) or v
        end
    end
    ns.db = RolloverDB
end

local function Refuse(message)
    ns.Print(message)
    return false
end

function ns.RequestGuildRoster()
    if IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end

function ns.GetModifier(name)
    return ns.db.modifiers[name] or 0
end

function ns.IsValidModifier(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- Names are exactly as GetGuildRosterInfo returns them. On the Forever beta that is
-- "First Last" with no realm suffix, so a "-Realm" part must not be required.
function ns.IsValidMemberName(name)
    return type(name) == "string" and #name > 0 and #name <= 96 and not name:find("[%c|]")
end

-- Exact roster name, or the unambiguous roster member with the same realm-less name
-- (addon message senders may carry a realm suffix that the roster lacks, or vice versa).
function ns.ResolveGuildMember(input)
    if type(input) ~= "string" or not IsInGuild() then return end
    local short = Ambiguate(input, "short")
    local found, ambiguous
    for i = 1, GetNumGuildMembers() do
        local name = GetGuildRosterInfo(i)
        if not issecretvalue(name) and type(name) == "string" then
            if name == input then return name end
            if Ambiguate(name, "short") == short then
                if found then ambiguous = true end
                found = name
            end
        end
    end
    if not ambiguous then return found end
end

-- True/false for a member in the current roster, nil when the member is not in it.
function ns.IsGuildMemberOnline(name)
    if not IsInGuild() then return end
    for i = 1, GetNumGuildMembers() do
        local rosterName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if rosterName == name then return isOnline and true or false end
    end
end

-- Forever names have a first and last name; UnitName only returns the first.
function ns.GetPlayerName()
    return GetUnitName("player", true)
end

function ns.GetPlayerModifier()
    local name = ns.GetPlayerName()
    return ns.GetModifier(ns.ResolveGuildMember(name) or name)
end

function ns.IsMaster()
    local player = ns.ResolveGuildMember(ns.GetPlayerName())
    return player ~= nil and ns.db.sync.master == player
end

function ns.CanEditModifiers()
    return ns.IsMaster() and not ns.IsSyncPending()
end

-- Import and restore replace the whole table; only the master may, and never while receiving.
function ns.CanReplaceModifiers()
    if ns.IsSyncPending() then return Refuse(ns.L.BUSY) end
    if not ns.IsMaster() then return Refuse(ns.L.FOLLOWER_LOCKED) end
    return true
end

-- updatedAt is the age of the local data (0 = reset/unknown). It travels with the data through sync,
-- import, export and backups and only a real edit sets it to "now".
function ns.GetUpdatedAt()
    return ns.db.sync.updatedAt or 0
end

-- Server time is shared by all clients, so stamps are comparable; the +1 keeps the stamp strictly
-- increasing for edits within the same second.
function ns.TouchModifiers()
    ns.db.sync.updatedAt = math.max(GetServerTime(), ns.GetUpdatedAt() + 1)
end

function ns.FormatStamp(stamp)
    return date("%Y-%m-%d %H:%M:%S", stamp)
end

function ns.SetModifier(name, value)
    if not ns.CanEditModifiers() then return Refuse(ns.L.READ_ONLY) end
    if not ns.IsValidMemberName(name) then return Refuse(ns.L.UNKNOWN_PLAYER) end
    if not ns.IsValidModifier(value) then return Refuse(ns.L.INVALID_MODIFIER) end
    if ns.db.modifiers[name] ~= value then
        ns.db.modifiers[name] = value
        ns.TouchModifiers()
    end
    return true
end

-- Only automatic sync backups are pruned, oldest first; the others stay until removed by hand.
local function PruneAutoBackups()
    local keys = {}
    for key, backup in pairs(ns.db.backups) do
        if backup.name == "auto sync" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return a > b end)
    for i = ns.MAX_AUTO_BACKUPS + 1, #keys do ns.db.backups[keys[i]] = nil end
end

-- name is a short label for the source of the backup (manual, restore, import, reset, sync, auto sync).
function ns.SaveBackup(name)
    local base = date("%Y-%m-%d %H:%M:%S")
    local key, suffix = base, 1
    while ns.db.backups[key] do
        suffix = suffix + 1
        key = base .. " (" .. suffix .. ")"
    end
    ns.db.backups[key] = { name = name, updatedAt = ns.GetUpdatedAt(), modifiers = CopyTable(ns.db.modifiers) }
    if name == "auto sync" then PruneAutoBackups() end
    ns.Print(string.format(ns.L.BACKUP_SAVED, key, name))
    return key
end

-- Replaces the modifier table and its age, after backing up the current state when backupName is set.
function ns.ReplaceModifiers(backupName, modifiers, updatedAt)
    if backupName then ns.SaveBackup(backupName) end
    ns.db.modifiers = modifiers
    ns.db.sync.updatedAt = updatedAt
    ns.RefreshRoster()
end

function ns.RestoreBackup(key)
    if not ns.CanReplaceModifiers() then return false end
    local backup = ns.db.backups[key]
    if not backup then return Refuse(ns.L.BACKUP_MISSING) end
    if backup.updatedAt < ns.GetUpdatedAt() then
        return Refuse(string.format(ns.L.RESTORE_OLDER, key, ns.FormatStamp(backup.updatedAt), ns.FormatStamp(ns.GetUpdatedAt())))
    end
    ns.ReplaceModifiers("restore", CopyTable(backup.modifiers), backup.updatedAt)
    ns.Print(string.format(ns.L.BACKUP_RESTORED, key))
    return true
end

-- Clears every modifier and marks the data as older than anything, so the next import, restore or
-- sync is accepted. The only way to take older data. Allowed for followers too.
function ns.ResetData()
    if ns.IsSyncPending() then return Refuse(ns.L.BUSY) end
    ns.ReplaceModifiers(next(ns.db.modifiers) and "reset", {}, 0)
    ns.Print(ns.L.RESET_DONE)
    return true
end

function ns.ExportModifiers()
    if not C_EncodingUtil or not C_EncodingUtil.SerializeJSON then return Refuse(ns.L.JSON_UNAVAILABLE) end
    ns.ShowExportFrame(C_EncodingUtil.SerializeJSON({ updatedAt = ns.GetUpdatedAt(), modifiers = ns.db.modifiers }))
end

local function ValidateModifiers(modifiers)
    if type(modifiers) ~= "table" then return false, ns.L.INVALID_STATE end
    local count = 0
    for name, value in pairs(modifiers) do
        if not ns.IsValidMemberName(name) or not ns.IsValidModifier(value) then return false, ns.L.INVALID_STATE end
        count = count + 1
        if count > ns.MAX_MEMBERS then return false, string.format(ns.L.STATE_TOO_LARGE, ns.MAX_MEMBERS) end
    end
    return true
end

-- JSON is { "updatedAt": seconds, "modifiers": { name: number } }.
function ns.ImportModifiers(text)
    if not ns.CanReplaceModifiers() then return false end
    if not C_EncodingUtil or not C_EncodingUtil.DeserializeJSON then return Refuse(ns.L.JSON_UNAVAILABLE) end
    if #text > MAX_JSON_BYTES then return Refuse(string.format(ns.L.JSON_TOO_LARGE, MAX_JSON_BYTES)) end
    local ok, parsed = pcall(C_EncodingUtil.DeserializeJSON, text)
    if not ok then return Refuse(string.format(ns.L.INVALID_JSON, tostring(parsed))) end
    if type(parsed) ~= "table" then return Refuse(ns.L.INVALID_STATE) end
    -- A missing stamp is 0, the oldest. Server time is shared, so a stamp from the future is invalid.
    local stamp = parsed.updatedAt or 0
    if type(stamp) ~= "number" or stamp ~= math.floor(stamp) or stamp < 0 or stamp > GetServerTime() then
        return Refuse(ns.L.INVALID_STATE)
    end
    local valid, message = ValidateModifiers(parsed.modifiers)
    if not valid then return Refuse(message) end
    if stamp < ns.GetUpdatedAt() then
        return Refuse(string.format(ns.L.IMPORT_OLDER, ns.FormatStamp(stamp), ns.FormatStamp(ns.GetUpdatedAt())))
    end
    ns.ReplaceModifiers("import", parsed.modifiers, stamp)
    ns.Print(ns.L.IMPORTED)
    return true
end

-- Current guild roster merged with saved modifiers.
-- sortKey: "name" | "class" | "rank" | "modifier"; ties fall back to name.
function ns.GetRosterList(sortKey, ascending)
    local list = {}
    if not IsInGuild() then return list end

    for i = 1, GetNumGuildMembers() do
        local name, rank, rankIndex, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
        if not issecretvalue(name) and type(name) == "string" then
            list[#list + 1] = { name = name, class = class, rank = rank, rankIndex = rankIndex, modifier = ns.GetModifier(name) }
        end
    end

    local function value(entry)
        if sortKey == "class" then return LOCALIZED_CLASS_NAMES_MALE[entry.class] or entry.class or "" end
        if sortKey == "rank" then return entry.rankIndex end
        if sortKey == "modifier" then return entry.modifier end
        return entry.name
    end

    table.sort(list, function(a, b)
        local va, vb = value(a), value(b)
        if va ~= vb then
            if ascending then return va < vb end
            return va > vb
        end
        return a.name < b.name
    end)
    return list
end
