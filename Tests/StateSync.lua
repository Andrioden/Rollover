-- Run with a standalone Lua interpreter: lua Tests\StateSync.lua <addon directory>
local root = arg[1] or "."
local clients, timers, clock, delivered = {}, {}, 0, {}
local secret = {}

local function copy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = type(value) == "table" and copy(value) or value
    end
    return result
end

local function advance(seconds)
    local limit = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.time < b.time end)
        local timer = timers[1]
        if not timer or timer.time > limit then break end
        table.remove(timers, 1)
        clock = timer.time
        if not timer.cancelled then timer.callback() end
    end
    clock = limit
end

local function client(name)
    local c = { name = name, ns = {}, guild = "Guild", prints = {}, frames = {}, result = 0 }
    clients[name] = c
    local env = setmetatable({}, { __index = _G })
    env._G = env
    c.env = env
    env.CopyTable = copy
    env.issecretvalue = function(value) return value == secret end
    env.strtrim = function(text) return text:match("^%s*(.-)%s*$") end
    env.date = function() return "2026-10-04 12:00:00" end
    env.GetTime = function() return clock end
    env.GetServerTime = function() return 1800000000 + math.floor(clock) end
    env.GetUnitName = function() return name:gsub("%-Realm$", "") end
    env.Ambiguate = function(value) return value:gsub("%-.*$", "") end
    env.IsInGuild = function() return c.guild ~= nil end
    env.GetGuildInfo = function() return c.guild, nil, nil, "Realm" end
    env.GetNormalizedRealmName = function() return "Realm" end
    env.GetNumGuildMembers = function() return #c.roster end
    c.roster = { "Publisher-Realm", "Follower-Realm", "Zero-Realm", "Third-Realm" }
    env.GetGuildRosterInfo = function(index)
        return c.roster[index], "Member", index, nil, nil, nil, nil, nil, nil, nil, "MAGE"
    end
    env.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage" }
    env.RAID_CLASS_COLORS = {}
    env.print = function(message) c.prints[#c.prints + 1] = message end
    env.C_GuildInfo = { GuildRoster = function() c.rosterRequested = true end }
    env.C_Timer = {}
    env.C_Timer.NewTimer = function(delay, callback)
        local timer = { time = clock + delay, callback = callback }
        function timer:Cancel() self.cancelled = true end
        timers[#timers + 1] = timer
        return timer
    end
    env.C_Timer.After = env.C_Timer.NewTimer
    env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, AddOnMessageLockdown = 11 } }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(prefix) assert(#prefix <= 16); return c.prefix ~= false end,
        SendAddonMessage = function(prefix, message, channel, target)
            assert(#message <= 255 and channel == "WHISPER")
            if c.result ~= 0 then return c.result end
            delivered[#delivered + 1] = { sender = name, target = target, text = message, time = clock }
            env.C_Timer.After(0.01, function()
                if clients[target] then clients[target].ns.OnSyncMessage(prefix, message, channel, name) end
            end)
            return 0
        end,
    }
    -- WoW owns JSON parsing; mock its success/error results to test our boundary validation.
    env.C_EncodingUtil = {
        DeserializeJSON = function(text)
            if text == '{"Publisher-Realm":7,"Zero-Realm":0}' then
                return { ["Publisher-Realm"] = 7, ["Zero-Realm"] = 0 }
            elseif text == '{"bad|name":7}' then return { ["bad|name"] = 7 }
            elseif text == '{"":7}' then return { [""] = 7 }
            elseif text == '{"Andriod En":220}' then return { ["Andriod En"] = 220 }
            elseif text == '{"Publisher-Realm":"bad"}' then return { ["Publisher-Realm"] = "bad" }
            elseif text == "{}" then return {} end
            error("JSON parse error")
        end,
        SerializeJSON = function(state)
            local rows = {}
            for key, value in pairs(state) do rows[#rows + 1] = '"' .. key .. '":' .. tostring(value) end
            table.sort(rows)
            return "{" .. table.concat(rows, ",") .. "}"
        end,
    }
    local methods = {}
    local function frame(frameName)
        local f = { scripts = {}, events = {}, shown = false }
        setmetatable(f, { __index = function(_, key)
            if methods[key] then return methods[key] end
            if key:match("^%u") then return function() end end
        end })
        c.frames[#c.frames + 1] = f
        if frameName then c.frames[frameName] = f end
        return f
    end
    function methods:SetScript(event, callback) self.scripts[event] = callback end
    function methods:RegisterEvent(event) self.events[event] = true end
    function methods:UnregisterEvent(event) self.events[event] = nil end
    function methods:IsShown() return self.shown end
    function methods:SetShown(shown)
        local changed = self.shown ~= shown
        self.shown = shown
        local callback = self.scripts[shown and "OnShow" or "OnHide"]
        if changed and callback then callback(self) end
    end
    function methods:Show() self:SetShown(true) end
    function methods:Hide() self:SetShown(false) end
    function methods:SetText(text) self.text = text end
    function methods:GetText() return self.text end
    function methods:SetEnabled(enabled) self.enabled = not not enabled end
    function methods:HasFocus() return self.focused end
    function methods:SetFocus() self.focused = true end
    function methods:ClearFocus() self.focused = false end
    function methods:CreateFontString() local fontString = frame(); fontString.owner = self; return fontString end
    function methods:GetFontString() return self end
    function methods:SetDataProvider(data) self.data = data end
    function methods:SetTitle(title) self.title = title end
    function methods:SetNormalTexture(path) self.normalTexture = path end
    function methods:GetPushedTexture() return frame() end
    function methods:SetPoint(point, ...) self.point, self.pointArgs = point, { ... } end
    function methods:CreateTexture() return frame() end
    function methods:SetDesaturated(value) self.desaturated = value end
    function methods:SetAlpha(value) self.alpha = value end
    function methods:SetSize(width, height) self.width, self.height = width, height end
    function methods:SetResizeBounds(minWidth) self.minWidth = minWidth end
    function methods:SetVerticalScroll(value) self.verticalScroll = value end
    env.CreateFrame = function(_, frameName) return frame(frameName) end
    env.UIParent, env.GameTooltip = frame(), frame()
    env.GameTooltip_Hide = function() end
    env.UISpecialFrames, env.SlashCmdList = {}, {}
    env.tinsert = table.insert
    env.ScrollBoxConstants = { RetainScrollPosition = 1 }
    env.CreateDataProvider = function(data) return data end
    env.CreateScrollBoxListLinearView = function()
        return { SetElementExtent = function() end, SetElementFactory = function(self, callback) self.factory = callback end }
    end
    env.ScrollUtil = { InitScrollBoxListWithScrollBar = function(_, _, view)
        view.factory(function(_, initializer) c.initRow = initializer end)
    end }
    env.MenuUtil = { CreateContextMenu = function(_, callback)
        local entries = {}
        local function menu()
            local m = {}
            function m:CreateButton(label, action)
                local entry = menu()
                entry.label, entry.action = label, action
                entries[#entries + 1] = entry
                return entry
            end
            function m:SetEnabled(value) self.enabled = value end
            function m:SetScrollMode() end
            function m:CreateTitle() end
            function m:CreateDivider() end
            return m
        end
        callback(nil, menu())
        c.menu = entries
    end }
    function c.load(path)
        local chunk
        if setfenv then
            chunk = assert(loadfile(root .. "\\" .. path))
            setfenv(chunk, env)
        else
            chunk = assert(loadfile(root .. "\\" .. path, "t", env))
        end
        chunk("Rollover", c.ns)
    end
    c.load("Locales\\enUS.lua")
    c.load("Core\\Utils.lua")
    c.load("Core\\DB.lua")
    c.load("Modules\\GuildSync.lua")
    c.load("UI\\DebugFrame.lua")
    c.load("UI\\ExportFrame.lua")
    c.load("UI\\ImportFrame.lua")
    c.load("UI\\MainFrame.lua")
    c.ns.version = "0.0.1"
    c.ns.InitDB()
    c.ns.InitGuildSync()
    return c
end

-- Sync feedback is chat-only: helpers to inspect what a client printed.
local function last(c) return c.prints[#c.prints] or "" end
local function printedSince(c, mark) return table.concat(c.prints, "\n", mark + 1) end
local function count(c, text)
    local total = 0
    for _, line in ipairs(c.prints) do if line:find(text, 1, true) then total = total + 1 end end
    return total
end

local p, f = client("Publisher-Realm"), client("Follower-Realm")
assert(p.ns.SetModifier("Publisher-Realm", 12.5))
assert(p.ns.SetModifier("Former-Realm", -4))
assert(not p.ns.SetModifier("Publisher-Realm", math.huge))
local backup1, backup2 = p.ns.SaveBackup(), p.ns.SaveBackup()
assert(backup1 ~= backup2)
p.ns.SetModifier("Publisher-Realm", 22)
assert(p.ns.db.backups[backup1]["Publisher-Realm"] == 12.5)
assert(p.ns.RestoreBackup(backup1) and p.ns.GetPlayerModifier() == 12.5)
assert(p.ns.SelectPublisher("Publisher"))
assert(last(p):find(p.ns.L.LOCAL_PUBLISHER, 1, true))
local printsBeforeEdit = #p.prints
assert(p.ns.SetModifier("Publisher-Realm", 12.5) and #p.prints == printsBeforeEdit)
assert(p.ns.GetSyncStatus == nil and p.ns.RefreshSyncControls == nil and p.ns.OnModifierStateChanged == nil)
assert(f.ns.SelectPublisher("Publisher-Realm"))
assert(last(f):find(string.format(f.ns.L.PUBLISHER_SET, "Publisher-Realm"), 1, true))
for _, line in ipairs(f.prints) do assert(not line:find(f.ns.L.LOCAL_PUBLISHER, 1, true)) end
assert(not f.ns.SetModifier("Follower-Realm", 99))
f.ns.db.modifiers = { ["Old-Realm"] = 42 }
assert(not f.ns.ImportModifiers('{"bad|name":7}'))
assert(not f.ns.ImportModifiers('{"":7}'))
assert(not f.ns.ImportModifiers('{"Publisher-Realm":"bad"}'))
assert(not f.ns.ImportModifiers("{bad}"))
assert(not f.ns.ImportModifiers("[]"))
assert(not f.ns.ImportModifiers(string.rep(" ", 200001)))
assert(f.ns.GetModifier("Old-Realm") == 42)
assert(f.ns.ImportModifiers('{"Publisher-Realm":7,"Zero-Realm":0}'))
assert(f.ns.GetModifier("Publisher-Realm") == 7 and f.ns.GetModifier("Old-Realm") == 0)
f.ns.ExportModifiers()
local exportFrame = f.frames.RolloverExportFrame
local exported = '{"Publisher-Realm":7,"Zero-Realm":0}'
assert(exportFrame:IsShown() and exportFrame.title == f.ns.L.EXPORT_TITLE)
assert(exportFrame.edit:GetText() == exported and exportFrame.edit.focused)
exportFrame.edit:SetText("tampered")
exportFrame.edit.scripts.OnTextChanged(exportFrame.edit, true)
assert(exportFrame.edit:GetText() == exported)
assert(not f.frames.RolloverImportFrame)
f.ns.ShowImportFrame()
local importFrame = f.frames.RolloverImportFrame
assert(importFrame:IsShown() and importFrame.title == f.ns.L.IMPORT_TITLE)
assert(importFrame.edit:GetText() == "" and importFrame.edit.focused)
importFrame.edit:SetText("{bad}")
local importButton
for _, button in ipairs(f.frames) do
    if button.text == f.ns.L.IMPORT_BUTTON then importButton = button end
end
importButton.scripts.OnClick()
assert(importFrame:IsShown() and f.ns.GetModifier("Publisher-Realm") == 7)
importFrame.edit:SetText("{}")
importButton.scripts.OnClick()
assert(next(f.ns.db.modifiers) == nil and not importFrame:IsShown())
f.ns.ShowImportFrame()
assert(importFrame.edit:GetText() == "")
importFrame:Hide()
f.ns.ToggleDebugFrame()
assert(f.frames.RolloverDebugFrame:IsShown())
f.ns.ToggleDebugFrame()
assert(not f.frames.RolloverDebugFrame:IsShown())
local syncMark = #f.prints
f.ns.db.modifiers = { ["Old-Realm"] = 42 }
assert(f.ns.RequestSync())
assert(not f.ns.ImportModifiers("{}") and not f.ns.SelectPublisher("Follower-Realm"))
local before
for key, state in pairs(f.ns.db.backups) do if state["Old-Realm"] == 42 then before = key end end
assert(before)
advance(3.1)
assert(f.ns.IsSyncPending() and f.ns.GetModifier("Old-Realm") == 0)
assert(f.ns.GetModifier("Follower-Realm") == 0)
advance(10)
assert(not f.ns.IsSyncPending())
local syncOutput = printedSince(f, syncMark)
assert(syncOutput:find("Requesting modifiers from Publisher-Realm", 1, true))
assert(syncOutput:find("Receiving 5 modifiers from Publisher-Realm", 1, true))
assert(syncOutput:find("Synced 5 modifiers from Publisher-Realm", 1, true))
assert(not syncOutput:find("Sync failed", 1, true))
assert(f.ns.GetModifier("Publisher-Realm") == 12.5 and f.ns.GetModifier("Former-Realm") == -4)
assert(f.ns.db.modifiers["Zero-Realm"] == 0)
assert(f.ns.db.backups[before]["Old-Realm"] == 42)
assert(f.ns.RestoreBackup(before) and f.ns.GetModifier("Old-Realm") == 42)
advance(35)

-- Wrong sender, secret payloads, unsolicited messages and mismatched IDs cannot modify state.
assert(f.ns.RequestSync())
local requestId = tostring(f.env.GetServerTime()) .. "-2"
f.ns.OnSyncMessage("Rollover", "1\tBEGIN\t" .. requestId .. "\t1", "WHISPER", "Third-Realm")
f.ns.OnSyncMessage("Rollover", secret, "WHISPER", "Publisher-Realm")
f.ns.OnSyncMessage("Rollover", "1\tBEGIN\twrong\t1", "WHISPER", "Publisher-Realm")
assert(f.ns.GetModifier("Old-Realm") == 42)
f.ns.OnSyncMessage("Rollover", "1\tBEGIN\t" .. requestId .. "\t2", "WHISPER", "Publisher-Realm")
f.ns.OnSyncMessage("Rollover", "1\tVALUE\t" .. requestId .. "\t1\tPublisher-Realm\t-7", "WHISPER", "Publisher-Realm")
assert(f.ns.GetModifier("Publisher-Realm") == -7)
f.ns.OnSyncMessage("Rollover", "1\tEND\t" .. requestId .. "\t2", "WHISPER", "Publisher-Realm")
assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Publisher-Realm") == -7)
assert(last(f):find("Partial changes remain", 1, true))
advance(35)

-- Lockdown defers without losing the pre-sync backup (reported once, not on every retry).
f.result = 11
assert(f.ns.RequestSync())
advance(2)
assert(f.ns.IsSyncPending() and last(f):find(f.ns.L.DEFERRED, 1, true))
advance(12)
assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == 1)
f.result = 0
advance(20)
assert(not f.ns.IsSyncPending() and last(f):find("Synced", 1, true))
advance(35)
f.result = 12
assert(f.ns.RequestSync())
advance(2)
assert(not f.ns.IsSyncPending() and last(f):find("12", 1, true))
f.result = 0

-- Cancel releases the UI immediately, and throttle retries the request.
assert(f.ns.RequestSync())
f.ns.CancelSync()
assert(not f.ns.IsSyncPending() and last(f):find("cancelled", 1, true))
advance(35)
f.result = 3
assert(f.ns.RequestSync())
advance(2)
assert(f.ns.IsSyncPending() and last(f):find(f.ns.L.DEFERRED, 1, true))
f.result = 0
advance(20)
assert(not f.ns.IsSyncPending() and last(f):find("Synced", 1, true))

-- Losing the guild cancels an active receive; timeout leaves applied values.
assert(f.ns.RequestSync())
f.guild = nil
f.ns.OnSyncContextChanged()
assert(not f.ns.IsSyncPending())
f.guild = "Guild"
advance(35)
f.result = 11
assert(f.ns.RequestSync())
advance(1801)
assert(not f.ns.IsSyncPending() and last(f):find("timed out", 1, true))
f.result = 0

f.ns.ToggleMainFrame()
local main = f.frames.RolloverMainFrame
assert(main:IsShown() and f.rosterRequested)
-- No status text anywhere in the window: the only font string owned by the frame is the empty-roster label.
local mainFontStrings = 0
for _, object in ipairs(f.frames) do if object.owner == main then mainFontStrings = mainFontStrings + 1 end end
assert(mainFontStrings == 1 and main.syncStatus == nil)
local row = f.env.CreateFrame("Frame")
f.initRow(row, main.scrollBox.data[1])
assert(not row.modEdit.enabled)
assert(f.ns.SelectPublisher("Follower-Realm"))
f.initRow(row, main.scrollBox.data[1])
assert(row.modEdit.enabled)
row.modEdit:SetText("-9")
row.modEdit.scripts.OnEditFocusLost(row.modEdit)
assert(f.ns.GetModifier(row.key) == -9)
local tools
for _, button in ipairs(f.frames) do
    if button.normalTexture and button.normalTexture:find("Gear", 1, true) then tools = button end
end
assert(tools and tools.point == "TOPRIGHT" and not tools.text)
tools.scripts.OnEnter(tools)
assert(f.env.GameTooltip.text == f.ns.L.TOOLS)

-- The top input, Set and Sync controls are gone; publishing is chosen with the row crowns.
for _, frame in ipairs(f.frames) do
    assert(frame.text ~= "Set" and frame.text ~= "Sync" and not frame.scripts.OnEnterPressed
        or frame == row.modEdit, "removed publisher control still exists")
end

-- Width fits the table: margins 14+30, columns 4+150+(2+16+2)+90+4+110+10+60.
local requiredWidth = 14 + 4 + 150 + 20 + 90 + 4 + 110 + 10 + 60 + 30
assert(main.width >= requiredWidth and main.minWidth >= requiredWidth)
local classHeader
for _, frame in ipairs(f.frames) do if frame.label == "Class" then classHeader = frame end end
assert(classHeader.pointArgs[3] == 20 and row.classText.pointArgs[3] == 20)

-- Crown buttons: bright for the current publisher, dim for others (no border/glow).
local rowA, rowB = f.env.CreateFrame("Frame"), f.env.CreateFrame("Frame")
f.initRow(rowA, main.scrollBox.data[1])
f.initRow(rowB, main.scrollBox.data[2])
assert(rowA.key == "Publisher-Realm" and rowB.key == "Follower-Realm")
local crownA, crownB = rowA.publisherButton, rowB.publisherButton
assert(crownA.icon.desaturated and crownA.icon.alpha < 1)
assert(not crownB.icon.desaturated and crownB.icon.alpha == 1)
assert(crownA.glow == nil and crownB.glow == nil)
crownA.scripts.OnEnter(crownA)
assert(f.env.GameTooltip.text == f.ns.L.SET_PUBLISHER)
crownB.scripts.OnEnter(crownB)
assert(f.env.GameTooltip.text == f.ns.L.CURRENT_PUBLISHER)
crownA.scripts.OnClick()
assert(f.ns.db.sync.publisher == "Publisher-Realm" and not f.ns.IsPublisher() and not f.ns.CanEditModifiers())
f.initRow(rowA, main.scrollBox.data[1])
f.initRow(rowB, main.scrollBox.data[2])
assert(not crownA.icon.desaturated and crownA.icon.alpha == 1)
assert(crownB.icon.desaturated and crownB.icon.alpha < 1)
assert(not rowA.modEdit.enabled)
crownA.scripts.OnClick()
assert(f.ns.db.sync.publisher == "Publisher-Realm")

-- Tools menu: sync lives here, switches to Cancel while receiving, and the crowns lock.
local function menuEntries()
    tools.scripts.OnClick(tools)
    local labels = {}
    for _, entry in ipairs(f.menu) do labels[entry.label] = entry end
    return labels
end
local labels = menuEntries()
for _, key in ipairs({ "SYNC_FROM_PUBLISHER", "BACKUP", "EXPORT", "IMPORT", "RESTORE" }) do
    assert(labels[f.ns.L[key]], key)
end
assert(not labels[f.ns.L.CANCEL_SYNC])
advance(35)
labels[f.ns.L.SYNC_FROM_PUBLISHER].action()
assert(f.ns.IsSyncPending())
f.initRow(rowA, main.scrollBox.data[1])
assert(not crownA.enabled)
labels = menuEntries()
assert(labels[f.ns.L.CANCEL_SYNC] and not labels[f.ns.L.SYNC_FROM_PUBLISHER])
assert(labels[f.ns.L.IMPORT].enabled == false and labels[f.ns.L.RESTORE].enabled == false)
labels[f.ns.L.CANCEL_SYNC].action()
assert(not f.ns.IsSyncPending())
f.initRow(rowA, main.scrollBox.data[1])
assert(crownA.enabled)
assert(menuEntries()[f.ns.L.SYNC_FROM_PUBLISHER])
advance(35)
f.load("Core\\Events.lua")
local events = f.frames[#f.frames]
events.scripts.OnEvent(events, "ADDON_LOADED", "Rollover")
assert(events.events.CHAT_MSG_ADDON and events.events.PLAYER_GUILD_UPDATE)
events.scripts.OnEvent(events, "GUILD_ROSTER_UPDATE")

local noAPI = client("Third-Realm")
advance(35)
assert(f.ns.SelectPublisher("Third-Realm"))
assert(f.ns.RequestSync())
advance(5)
assert(not f.ns.IsSyncPending() and last(f):find("not publishing", 1, true))
noAPI.env.C_EncodingUtil = nil
assert(not noAPI.ns.ImportModifiers("{}"))
noAPI.ns.ExportModifiers()
noAPI.prefix = false
noAPI.ns.InitGuildSync()
assert(not noAPI.ns.RequestSync())
local large = {}
for i = 1, 1001 do large["Member" .. i .. "-Realm"] = 0 end
assert(not f.ns.ValidateModifierState(large))
large["Member1001-Realm"] = nil
assert(f.ns.ValidateModifierState(large))
f.ns.db.modifiers = {}
f.ns.ExportModifiers()
assert(f.frames.RolloverExportFrame.edit:GetText() == "{}")
f.roster = { "Twin-One", "Twin-Two" }
assert(not f.ns.ResolveGuildMember("Twin"))

-- Forever's roster has no realm suffix ("First Last"): edit, export/import and sync must work.
local rp, rf = client("Andriod En"), client("Other Player")
for _, c in ipairs({ rp, rf }) do c.roster = { "Andriod En", "Other Player", "Third Guy" } end
assert(rp.ns.IsValidMemberName("Andriod En") and not rp.ns.IsValidMemberName(""))
assert(rp.ns.SelectPublisher("Andriod En") and rp.ns.IsPublisher())
rp.ns.ToggleMainFrame()
local realmlessRow = rp.env.CreateFrame("Frame")
rp.initRow(realmlessRow, rp.frames.RolloverMainFrame.scrollBox.data[1])
assert(realmlessRow.key == "Andriod En")
realmlessRow.modEdit:SetText("220")
realmlessRow.modEdit.scripts.OnEditFocusLost(realmlessRow.modEdit)
assert(rp.ns.GetModifier("Andriod En") == 220 and rp.ns.GetPlayerModifier() == 220)
assert(rp.ns.SetModifier("Other Player", -3))
for _, line in ipairs(rp.prints) do assert(not line:find("unambiguous", 1, true), line) end
assert(rf.ns.SelectPublisher("Andriod En"))
assert(rf.ns.RequestSync())
advance(20)
assert(not rf.ns.IsSyncPending() and last(rf):find("Synced 3 modifiers from Andriod En", 1, true))
assert(rf.ns.GetModifier("Andriod En") == 220 and rf.ns.GetModifier("Other Player") == -3)
assert(rf.ns.db.modifiers["Third Guy"] == 0 and rf.ns.GetPlayerModifier() == -3)
assert(rf.ns.ImportModifiers('{"Andriod En":220}') and rf.ns.GetModifier("Other Player") == 0)
rp.ns.ExportModifiers()
assert(rp.frames.RolloverExportFrame.edit:GetText():find('"Andriod En":220', 1, true))
for _, line in ipairs(rf.prints) do assert(not line:find("unambiguous", 1, true), line) end
for _, message in ipairs(delivered) do assert(#message.text <= 255) end
print("PASS: backups, JSON boundary validation, export/import frames, icon tools menu, follower permissions, streaming sync, partial failure, spoof guards, lockdown, send failure, timeout and event wiring")
