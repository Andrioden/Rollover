local addonName, ns = ...

local DB_VERSION = 1

local defaults = {
    version = DB_VERSION,
    modifiers = {}, -- [guild roster name] = number
    backups = {}, -- [date-time] = copy of modifiers
    sync = {}, -- { publisher = guild roster name }
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

function ns.ResolveGuildMember(input)
    if issecretvalue(input) or type(input) ~= "string" or not IsInGuild() then return end
    local found
    for i = 1, GetNumGuildMembers() do
        local name = GetGuildRosterInfo(i)
        if not issecretvalue(name) and type(name) == "string" then
            if name == input then return name end
            if not input:find("-", 1, true) and Ambiguate(name, "short") == input then
                if found then return end
                found = name
            end
        end
    end
    return found
end

function ns.IsPublisher()
    local player = ns.ResolveGuildMember(ns.GetPlayerName())
    return player ~= nil and ns.db.sync.publisher == player
end

function ns.CanEditModifiers()
    return ns.db and (not ns.db.sync.publisher or ns.IsPublisher())
        and not ns.IsSyncPending()
end

function ns.SetModifier(name, value)
    if not ns.CanEditModifiers() then ns.Print(ns.L.READ_ONLY); return false end
    if not ns.IsValidMemberName(name) then ns.Print(ns.L.UNKNOWN_PLAYER); return false end
    if not ns.IsValidModifier(value) then ns.Print(ns.L.INVALID_MODIFIER); return false end
    ns.db.modifiers[name] = value
    return true
end

function ns.SaveBackup()
    local base = date("%Y-%m-%d %H:%M:%S")
    local key, suffix = base, 1
    while ns.db.backups[key] do
        suffix = suffix + 1
        key = base .. " (" .. suffix .. ")"
    end
    ns.db.backups[key] = CopyTable(ns.db.modifiers)
    ns.Print(string.format(ns.L.BACKUP_SAVED, key))
    return key
end

function ns.ValidateModifierState(state)
    if type(state) ~= "table" then return false, ns.L.INVALID_STATE end
    local count = 0
    for name, value in pairs(state) do
        if not ns.IsValidMemberName(name) or not ns.IsValidModifier(value) then
            return false, ns.L.INVALID_STATE
        end
        count = count + 1
        if count > 1000 then return false, ns.L.STATE_TOO_LARGE end
    end
    return true
end

function ns.RestoreBackup(key)
    if ns.IsSyncPending() then ns.Print(ns.L.BUSY); return false end
    local backup = ns.db.backups[key]
    if not backup then ns.Print(ns.L.BACKUP_MISSING); return false end
    local valid, message = ns.ValidateModifierState(backup)
    if not valid then ns.Print(message); return false end
    ns.SaveBackup()
    ns.db.modifiers = CopyTable(backup)
    ns.RefreshRoster()
    ns.Print(string.format(ns.L.BACKUP_RESTORED, key))
    return true
end

function ns.ExportModifiers()
    if not C_EncodingUtil or not C_EncodingUtil.SerializeJSON then
        ns.Print(ns.L.JSON_UNAVAILABLE)
        return
    end
    local valid, message = ns.ValidateModifierState(ns.db.modifiers)
    if not valid then ns.Print(message); return end
    local ok, text = pcall(C_EncodingUtil.SerializeJSON, ns.db.modifiers)
    if not ok or type(text) ~= "string" then
        ns.Print(string.format(ns.L.JSON_FAILED, tostring(text)))
        return
    end
    -- An empty Lua table can serialize as an array; the exchange format is an object.
    if next(ns.db.modifiers) == nil then text = "{}" end
    ns.ShowExportFrame(text)
end

function ns.ImportModifiers(text)
    if ns.IsSyncPending() then ns.Print(ns.L.BUSY); return false end
    if not C_EncodingUtil or not C_EncodingUtil.DeserializeJSON then
        ns.Print(ns.L.JSON_UNAVAILABLE)
        return false
    end
    if #text > 200000 then ns.Print(ns.L.JSON_TOO_LARGE); return false end
    if not text:match("^%s*{") or not text:match("}%s*$") then
        ns.Print(ns.L.INVALID_STATE)
        return false
    end
    local ok, state = pcall(function() return C_EncodingUtil.DeserializeJSON(text) end)
    if not ok then ns.Print(string.format(ns.L.INVALID_JSON, tostring(state))); return false end
    local valid, message = ns.ValidateModifierState(state)
    if not valid then ns.Print(message); return false end
    ns.SaveBackup()
    ns.db.modifiers = state
    ns.RefreshRoster()
    ns.Print(ns.L.IMPORTED)
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
