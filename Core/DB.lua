local addonName, ns = ...

local DB_VERSION = 1
local MAX_JSON_BYTES = 200000
ns.MAX_MEMBERS = 1000
ns.MAX_AUTO_BACKUPS = 10

local defaults = {
    version = DB_VERSION,
    modifiers = {}, -- [guild roster name] = number
    backups = {}, -- [date-time] = { name, updatedAt, modifiers }
    -- master = guild roster name; updatedAt = server time of the last real change to the modifiers,
    -- carried along with the data itself (0 or nil = no known age, e.g. after a reset)
    sync = {},
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

function ns.RequestGuildRoster()
    if IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end

function ns.GetModifier(name)
    return ns.db and ns.db.modifiers[name] or 0
end

function ns.IsValidModifier(value)
    return not issecretvalue(value) and type(value) == "number"
        and value == value and value > -math.huge and value < math.huge
end

-- Names are exactly as GetGuildRosterInfo returns them. On the Forever beta that is
-- "First Last" with no realm suffix, so a "-Realm" part must not be required.
function ns.IsValidMemberName(name)
    return not issecretvalue(name) and type(name) == "string"
        and #name > 0 and #name <= 96 and not name:find("[%c|]")
end

-- Exact roster name, or the unambiguous roster member with the same realm-less name
-- (addon message senders may carry a realm suffix that the roster lacks, or vice versa).
function ns.ResolveGuildMember(input)
    if issecretvalue(input) or type(input) ~= "string" or not IsInGuild() then return end
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

function ns.IsMaster()
    local player = ns.ResolveGuildMember(ns.GetPlayerName())
    return player ~= nil and ns.db.sync.master == player
end

function ns.CanEditModifiers()
    return ns.IsMaster() and not ns.IsSyncPending()
end

function ns.GetUpdatedAt()
    return ns.db.sync.updatedAt or 0
end

-- Called only when a modifier really changed. Server time is shared by all clients, so stamps are
-- comparable; the +1 keeps it strictly increasing for edits within the same second.
function ns.TouchModifiers()
    ns.db.sync.updatedAt = math.max(GetServerTime(), (ns.db.sync.updatedAt or 0) + 1)
end

function ns.SetModifier(name, value)
    if not ns.CanEditModifiers() then ns.Print(ns.L.READ_ONLY); return false end
    if not ns.IsValidMemberName(name) then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if not ns.IsValidModifier(value) then ns.Print(ns.L.INVALID_MODIFIER); return false end
    if ns.db.modifiers[name] ~= value then
        ns.db.modifiers[name] = value
        ns.TouchModifiers()
    end
    return true
end

-- Only automatic sync backups are pruned, oldest first; the others stay until removed by hand.
local function PruneAutoBackups()
    local keys = {}
    for key in pairs(ns.db.backups) do
        if ns.db.backups[key].name == "auto sync" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return a > b end)
    for i = ns.MAX_AUTO_BACKUPS + 1, #keys do ns.db.backups[keys[i]] = nil end
end

-- name is a short label for the source of the backup (manual, restore, import, reset, sync, ...).
function ns.SaveBackup(name)
    assert(type(name) == "string" and name ~= "", "a backup needs a name")
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

-- Only the master changes modifiers; select yourself as master to edit locally.
function ns.CanReplaceModifiers()
    if ns.IsSyncPending() then ns.Print(ns.L.BUSY); return false end
    if not ns.IsMaster() then ns.Print(ns.L.FOLLOWER_LOCKED); return false end
    return true
end

function ns.ValidateModifierState(state)
    if type(state) ~= "table" then return false, ns.L.INVALID_STATE end
    local count = 0
    for name, value in pairs(state) do
        if not ns.IsValidMemberName(name) or not ns.IsValidModifier(value) then
            return false, ns.L.INVALID_STATE
        end
        count = count + 1
        if count > ns.MAX_MEMBERS then return false, string.format(ns.L.STATE_TOO_LARGE, ns.MAX_MEMBERS) end
    end
    return true
end

function ns.FormatStamp(stamp)
    return date("%Y-%m-%d %H:%M:%S", stamp)
end

function ns.RestoreBackup(key)
    if not ns.CanReplaceModifiers() then return false end
    local backup = ns.db.backups[key]
    if not backup then ns.Print(ns.L.BACKUP_MISSING); return false end
    if type(backup.modifiers) ~= "table" or type(backup.updatedAt) ~= "number" then
        ns.Print(ns.L.BACKUP_INVALID)
        return false
    end
    -- Restoring is going back in time unless the backup is as new as the current data.
    if backup.updatedAt < ns.GetUpdatedAt() then
        ns.Print(string.format(ns.L.RESTORE_OLDER, key, ns.FormatStamp(backup.updatedAt), ns.FormatStamp(ns.GetUpdatedAt())))
        return false
    end
    ns.SaveBackup("restore")
    ns.db.modifiers = CopyTable(backup.modifiers)
    ns.db.sync.updatedAt = backup.updatedAt
    ns.RefreshRoster()
    ns.Print(string.format(ns.L.BACKUP_RESTORED, key))
    return true
end

function ns.ExportModifiers()
    if not C_EncodingUtil or not C_EncodingUtil.SerializeJSON then
        ns.Print(ns.L.JSON_UNAVAILABLE)
        return
    end
    ns.ShowExportFrame(C_EncodingUtil.SerializeJSON({
        updatedAt = ns.GetUpdatedAt(),
        modifiers = ns.db.modifiers,
    }))
end

-- JSON is { "updatedAt": seconds, "modifiers": { name: number } }. A missing updatedAt counts as the
-- oldest possible state, so it is only accepted over data that is itself unstamped or reset. The
-- stamp must not be in the future: server time is shared, so no real state can be.
local function ParseImport(text)
    local ok, parsed = pcall(function() return C_EncodingUtil.DeserializeJSON(text) end)
    if not ok then return nil, string.format(ns.L.INVALID_JSON, tostring(parsed)) end
    if type(parsed) ~= "table" or type(parsed.modifiers) ~= "table" then return nil, ns.L.INVALID_STATE end
    local stamp = parsed.updatedAt or 0
    if not ns.IsValidModifier(stamp) or stamp ~= math.floor(stamp) or stamp < 0
        or stamp > GetServerTime() then
        return nil, ns.L.INVALID_STATE
    end
    local valid, message = ns.ValidateModifierState(parsed.modifiers)
    if not valid then return nil, message end
    return parsed.modifiers, nil, stamp
end

function ns.ImportModifiers(text)
    if not ns.CanReplaceModifiers() then return false end
    if not C_EncodingUtil or not C_EncodingUtil.DeserializeJSON then
        ns.Print(ns.L.JSON_UNAVAILABLE)
        return false
    end
    if #text > MAX_JSON_BYTES then ns.Print(string.format(ns.L.JSON_TOO_LARGE, MAX_JSON_BYTES)); return false end
    if not text:match("^%s*{") or not text:match("}%s*$") then
        ns.Print(ns.L.INVALID_STATE)
        return false
    end
    local state, message, stamp = ParseImport(text)
    if not state then ns.Print(message); return false end
    local own = ns.GetUpdatedAt()
    if stamp < own then
        ns.Print(string.format(ns.L.IMPORT_OLDER, ns.FormatStamp(stamp), ns.FormatStamp(own)))
        return false
    end
    ns.SaveBackup("import")
    ns.db.modifiers = state
    ns.db.sync.updatedAt = stamp
    ns.RefreshRoster()
    ns.Print(ns.L.IMPORTED)
    return true
end

-- Clears every modifier and marks the data as older than anything, so any later import, restore or
-- sync is accepted. This is the only way to take an older data set (see the age checks above and in
-- GuildSync). Allowed for followers too.
function ns.ResetData()
    if ns.IsSyncPending() then ns.Print(ns.L.BUSY); return false end
    if next(ns.db.modifiers) then ns.SaveBackup("reset") end
    ns.db.modifiers = {}
    ns.db.sync.updatedAt = 0
    ns.RefreshRoster()
    ns.Print(ns.L.RESET_DONE)
    return true
end

-- Forever names have a first and last name; UnitName only returns the first.
function ns.GetPlayerName()
    return GetUnitName("player", true)
end

-- Modifier of the current player; 0 when not in the roster.
function ns.GetPlayerModifier()
    local modifiers = ns.db and ns.db.modifiers
    if not modifiers then return 0 end

    local name = ns.GetPlayerName()
    if issecretvalue(name) or type(name) ~= "string" then return 0 end
    for key, modifier in pairs(modifiers) do
        if key == name or Ambiguate(key, "short") == name then
            return modifier
        end
    end
    return 0
end

-- sortKey: "name" | "class" | "rank" | "modifier"; ties fall back to name.
function ns.GetRosterList(sortKey, ascending)
    local list = {}
    if not IsInGuild() then return list end

    for i = 1, GetNumGuildMembers() do
        local name, rankName, rankIndex, _, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
        if not issecretvalue(name) and type(name) == "string" then
            list[#list + 1] = {
                name = name,
                member = {
                    class = classFile,
                    rank = rankName,
                    rankIndex = rankIndex,
                    modifier = ns.GetModifier(name),
                },
            }
        end
    end

    local function value(entry)
        local m = entry.member
        if sortKey == "class" then
            return LOCALIZED_CLASS_NAMES_MALE[m.class] or m.class or ""
        elseif sortKey == "rank" then
            return m.rankIndex or 99
        elseif sortKey == "modifier" then
            return m.modifier or 0
        end
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
