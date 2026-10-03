local addonName, ns = ...

local DB_VERSION = 1

local defaults = {
    version = DB_VERSION,
    modifiers = {}, -- [Name-Realm] = number
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

function ns.SetModifier(name, value)
    ns.db.modifiers[name] = value
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
        if name then
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
