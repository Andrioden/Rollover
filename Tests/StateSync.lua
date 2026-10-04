-- Run with a standalone Lua interpreter: lua Tests\StateSync.lua <addon directory>
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local count, last, printedSince = harness.count, harness.last, harness.printedSince
local delivered, secret = harness.delivered, harness.secret

-- Database, backups, publisher selection, and edit permissions.
local p, f = client("Publisher"), client("Follower")
assert(p.ns.SetModifier("Publisher", 12.5))
assert(p.ns.SetModifier("FormerMember", -4))
assert(not p.ns.SetModifier("Publisher", math.huge))
local backup1, backup2 = p.ns.SaveBackup(), p.ns.SaveBackup()
assert(backup1 ~= backup2)
p.ns.SetModifier("Publisher", 22)
assert(p.ns.db.backups[backup1].Publisher == 12.5)
assert(p.ns.RestoreBackup(backup1) and p.ns.GetPlayerModifier() == 12.5)
assert(p.ns.SelectPublisher("Publisher"))
assert(last(p):find(p.ns.L.LOCAL_PUBLISHER, 1, true))
local printsBeforeEdit = #p.prints
assert(p.ns.SetModifier("Publisher", 12.5) and #p.prints == printsBeforeEdit)
assert(p.ns.GetSyncStatus == nil and p.ns.RefreshSyncControls == nil and p.ns.OnModifierStateChanged == nil)
assert(f.ns.SelectPublisher("Publisher"))
assert(last(f):find(string.format(f.ns.L.PUBLISHER_SET, "Publisher"), 1, true))
for _, line in ipairs(f.prints) do assert(not line:find(f.ns.L.LOCAL_PUBLISHER, 1, true)) end
assert(not f.ns.SetModifier("Follower", 99))

-- JSON import validation, export, and text/debug windows.
f.ns.db.modifiers = { OldMember = 42 }
assert(not f.ns.ImportModifiers('{"bad|name":7}'))
assert(not f.ns.ImportModifiers('{"":7}'))
assert(not f.ns.ImportModifiers('{"Publisher":"bad"}'))
assert(not f.ns.ImportModifiers("{bad}"))
assert(not f.ns.ImportModifiers("[]"))
assert(not f.ns.ImportModifiers(string.rep(" ", 200001)))
assert(f.ns.GetModifier("OldMember") == 42)
assert(f.ns.ImportModifiers('{"Publisher":7,"ZeroMember":0}'))
assert(f.ns.GetModifier("Publisher") == 7 and f.ns.GetModifier("OldMember") == 0)
f.ns.ExportModifiers()
local exportFrame = f.frames.RolloverExportFrame
local exported = '{"Publisher":7,"ZeroMember":0}'
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
assert(importFrame:IsShown() and f.ns.GetModifier("Publisher") == 7)
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

-- Successful streamed sync keeps a pre-sync backup and includes missing roster values.
local syncMark = #f.prints
f.ns.db.modifiers = { OldMember = 42 }
assert(f.ns.RequestSync())
assert(not f.ns.ImportModifiers("{}") and not f.ns.SelectPublisher("Follower"))
local before
for key, state in pairs(f.ns.db.backups) do if state.OldMember == 42 then before = key end end
assert(before)
local publisherMark = #p.prints
advance(0.1)
assert(f.ns.IsSyncPending() and f.ns.GetModifier("OldMember") == 0)
assert(f.ns.GetModifier("Follower") == 0)
assert(printedSince(p, publisherMark):find("Follower requested a sync; sending 5 modifiers.", 1, true))
advance(1)
assert(not f.ns.IsSyncPending())
local syncOutput = printedSince(f, syncMark)
-- All five entries fit in one VALUE message and are listed together.
assert(syncOutput:find("Synced 5/5: Follower (0), FormerMember (-4), Publisher (+12.5), ThirdMember (0), ZeroMember (0)", 1, true))
assert(syncOutput:find("Requesting modifiers from Publisher", 1, true))
assert(syncOutput:find("Receiving 5 modifiers from Publisher", 1, true))
assert(syncOutput:find("Synced 5 modifiers from Publisher", 1, true))
assert(not syncOutput:find("Sync failed", 1, true))
assert(f.ns.GetModifier("Publisher") == 12.5 and f.ns.GetModifier("FormerMember") == -4)
assert(f.ns.db.modifiers.ZeroMember == 0)
assert(f.ns.db.backups[before].OldMember == 42)
assert(f.ns.RestoreBackup(before) and f.ns.GetModifier("OldMember") == 42)
advance(35)

-- Sync protocol validation, spoof guards, and partial-transfer behavior.
assert(f.ns.RequestSync())
local requestId = tostring(f.env.GetServerTime()) .. "-2"
f.ns.OnSyncMessage("Rollover", "1\tBEGIN\t" .. requestId .. "\t1", "WHISPER", "ThirdMember")
f.ns.OnSyncMessage("Rollover", secret, "WHISPER", "Publisher")
f.ns.OnSyncMessage("Rollover", "1\tBEGIN\twrong\t1", "WHISPER", "Publisher")
assert(f.ns.GetModifier("OldMember") == 42)
f.ns.OnSyncMessage("Rollover", "1\tBEGIN\t" .. requestId .. "\t2", "WHISPER", "Publisher")
f.ns.OnSyncMessage("Rollover", "1\tVALUE\t" .. requestId .. "\t1\tPublisher\t-7", "WHISPER", "Publisher")
assert(f.ns.GetModifier("Publisher") == -7)
f.ns.OnSyncMessage("Rollover", "1\tEND\t" .. requestId .. "\t2", "WHISPER", "Publisher")
assert(not f.ns.IsSyncPending() and f.ns.GetModifier("Publisher") == -7)
assert(last(f):find("may be incomplete", 1, true))
advance(35)

-- Lockdown retries, cancellation, throttling, guild loss, and timeout.
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
assert(count(f, "may be incomplete") == 1) -- failures before BEGIN must not claim partial changes
f.result = 0

-- Cancel releases the UI immediately, and throttle retries the request.
assert(f.ns.RequestSync())
f.ns.CancelSync()
assert(not f.ns.IsSyncPending() and last(f):find("cancelled", 1, true))
advance(35)
f.result = 3
local deferredBefore = count(f, f.ns.L.DEFERRED)
assert(f.ns.RequestSync())
advance(2)
assert(f.ns.IsSyncPending() and count(f, f.ns.L.DEFERRED) == deferredBefore) -- throttling is silent
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

-- Main roster, row permissions, publisher crowns, and Tools menu.
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
assert(f.ns.SelectPublisher("Follower"))
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
assert(rowA.key == "Publisher" and rowB.key == "Follower")
local crownA, crownB = rowA.publisherButton, rowB.publisherButton
assert(crownA.icon.desaturated and crownA.icon.alpha < 1)
assert(not crownB.icon.desaturated and crownB.icon.alpha == 1)
assert(crownA.glow == nil and crownB.glow == nil)
crownA.scripts.OnEnter(crownA)
assert(f.env.GameTooltip.text == f.ns.L.SET_PUBLISHER)
crownB.scripts.OnEnter(crownB)
assert(f.env.GameTooltip.text == f.ns.L.CURRENT_PUBLISHER)
crownA.scripts.OnClick()
assert(f.ns.db.sync.publisher == "Publisher" and not f.ns.IsPublisher() and not f.ns.CanEditModifiers())
f.initRow(rowA, main.scrollBox.data[1])
f.initRow(rowB, main.scrollBox.data[2])
assert(not crownA.icon.desaturated and crownA.icon.alpha == 1)
assert(crownB.icon.desaturated and crownB.icon.alpha < 1)
assert(not rowA.modEdit.enabled)
crownA.scripts.OnClick()
assert(f.ns.db.sync.publisher == "Publisher")

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

-- Event registration, unavailable APIs, and member-name resolution.
f.load("Core\\Events.lua")
local events = f.frames[#f.frames]
events.scripts.OnEvent(events, "ADDON_LOADED", "Rollover")
assert(events.events.CHAT_MSG_ADDON and events.events.PLAYER_GUILD_UPDATE)
events.scripts.OnEvent(events, "GUILD_ROSTER_UPDATE")

local noAPI = client("ThirdMember")
advance(35)
assert(f.ns.SelectPublisher("ThirdMember"))
assert(f.ns.RequestSync())
advance(5)
assert(not f.ns.IsSyncPending() and last(f):find("not publishing", 1, true))
assert(count(f, "may be incomplete") == 1)
noAPI.env.C_EncodingUtil = nil
assert(not noAPI.ns.ImportModifiers("{}"))
noAPI.ns.ExportModifiers()
noAPI.prefix = false
noAPI.ns.InitGuildSync()
assert(not noAPI.ns.RequestSync())
local large = {}
for i = 1, 1001 do large["Member" .. i] = 0 end
assert(not f.ns.ValidateModifierState(large))
large.Member1001 = nil
assert(f.ns.ValidateModifierState(large))
f.ns.db.modifiers = {}
f.ns.ExportModifiers()
assert(f.frames.RolloverExportFrame.edit:GetText() == "{}")
f.roster = { "Twin-One", "Twin-Two", "Twin" }
assert(f.ns.ResolveGuildMember("Twin") == "Twin") -- an exact match beats ambiguous short names
f.roster = { "Twin-One", "Twin-Two" }
assert(not f.ns.ResolveGuildMember("Twin"))
f.roster = { "Solo Player" }
assert(f.ns.ResolveGuildMember("Solo Player-Realm") == "Solo Player") -- sender with a realm suffix
assert(not f.ns.ResolveGuildMember("Other Player"))

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

-- Large rosters are packed into several VALUE messages and arrive quickly.
local bp, bf = client("Big Publisher"), client("Big Follower")
local bigRoster = { "Big Publisher", "Big Follower" }
for i = 1, 98 do bigRoster[#bigRoster + 1] = string.format("Guild Member Number %03d", i) end
bp.roster, bf.roster = bigRoster, bigRoster
for i = 3, #bigRoster do bp.ns.db.modifiers[bigRoster[i]] = i * 1.5 end
assert(bp.ns.SelectPublisher("Big Publisher") and bf.ns.SelectPublisher("Big Publisher"))
local bigMark, valueMessages = #bf.prints, 0
local deliveredBefore = #delivered
assert(bf.ns.RequestSync())
advance(10)
assert(not bf.ns.IsSyncPending() and last(bf):find("Synced 100 modifiers from Big Publisher", 1, true))
for i = deliveredBefore + 1, #delivered do
    if delivered[i].text:find("\tVALUE\t", 1, true) then valueMessages = valueMessages + 1 end
end
assert(valueMessages > 1 and valueMessages < 30, valueMessages)
assert(count(bf, "Synced ") - 1 == valueMessages and bf.ns.GetModifier(bigRoster[100]) == 150)
assert(printedSince(bf, bigMark):find("Synced 100/100:", 1, true))
-- A packed VALUE with a duplicate name inside the same message fails the transfer.
advance(35)
assert(bf.ns.RequestSync())
local dupId = tostring(bf.env.GetServerTime()) .. "-2"
bf.ns.OnSyncMessage("Rollover", "1\tBEGIN\t" .. dupId .. "\t2", "WHISPER", "Big Publisher")
bf.ns.OnSyncMessage("Rollover", "1\tVALUE\t" .. dupId .. "\t1\tBig Follower\t1\tBig Follower\t2", "WHISPER", "Big Publisher")
assert(not bf.ns.IsSyncPending() and printedSince(bf, bigMark):find("Invalid or incomplete", 1, true))
print("PASS: backups, JSON boundary validation, export/import frames, icon tools menu, follower permissions, streaming sync, partial failure, spoof guards, lockdown, send failure, timeout and event wiring")
