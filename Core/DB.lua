local addonName, ns = ...

local DB_VERSION = 1

local defaults = {
    version = DB_VERSION,
    rosterImported = false,
    members = {}, -- [Name-Realm] = { class = classFile, rank = rankName, rankIndex = n, modifier = number }
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

-- One-time import; returns true when the import happened.
function ns.TryImportGuildRoster()
    local db = ns.db
    if not db or db.rosterImported or not IsInGuild() then return false end

    local count = GetNumGuildMembers()
    if not count or count == 0 then return false end

    for i = 1, count do
        local name, rankName, rankIndex, _, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
        if name and not db.members[name] then
            db.members[name] = {
                class = classFile,
                rank = rankName,
                rankIndex = rankIndex,
                modifier = 0,
            }
        end
    end

    db.rosterImported = true
    return true
end

function ns.SetModifier(name, value)
    local member = ns.db and ns.db.members[name]
    if member then
        member.modifier = value
    end
end

-- sortKey: "name" | "class" | "rank" | "modifier"; ties fall back to name.
function ns.GetRosterList(sortKey, ascending)
    local list = {}
    for name, member in pairs(ns.db.members) do
        list[#list + 1] = { name = name, member = member }
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
