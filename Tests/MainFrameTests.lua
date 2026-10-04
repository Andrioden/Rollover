-- Run with a standalone Lua interpreter: lua Tests\MainFrameTests.lua <addon directory>
-- Covers UI\MainFrame.lua: roster rows, permissions, master buttons and the Tools menu.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local test = harness.suite("UI\\MainFrame.lua")

local p, f = client("Master"), client("Follower")
assert(p.ns.SelectMaster("Master") and f.ns.SelectMaster("Master"))
local main, row, tools, rowA, rowB, masterA, masterB, labels

local function menuEntries()
    tools.scripts.OnClick(tools)
    local entries = {}
    for _, entry in ipairs(f.menu) do entries[entry.label] = entry end
    return entries
end

test("opening shows the window and requests the roster", function()
    f.ns.ToggleMainFrame()
    main = f.frames.RolloverMainFrame
    assert(main:IsShown() and f.rosterRequested)
end)

test("window has no status text", function()
    -- The only font string owned by the frame is the empty-roster label.
    local fontStrings = 0
    for _, object in ipairs(f.frames) do if object.owner == main then fontStrings = fontStrings + 1 end end
    assert(fontStrings == 1 and main.syncStatus == nil)
end)

test("rows are read-only for followers and editable for the master", function()
    row = f.env.CreateFrame("Frame")
    f.initRow(row, main.scrollBox.data[1])
    assert(not row.modEdit.enabled)
    assert(f.ns.SelectMaster("Follower"))
    f.initRow(row, main.scrollBox.data[1])
    assert(row.modEdit.enabled)
    row.modEdit:SetText("-9")
    row.modEdit.scripts.OnEditFocusLost(row.modEdit)
    assert(f.ns.GetModifier(row.key) == -9)
end)

test("gear-icon Tools button sits top-right with a tooltip", function()
    for _, button in ipairs(f.frames) do
        if button.normalTexture and button.normalTexture:find("Gear", 1, true) then tools = button end
    end
    assert(tools and tools.point == "TOPRIGHT" and not tools.text)
    tools.scripts.OnEnter(tools)
    assert(f.env.GameTooltip.text == f.ns.L.TOOLS)
end)

test("legacy top input, Set and Sync controls are gone", function()
    for _, frame in ipairs(f.frames) do
        assert(frame.text ~= "Set" and frame.text ~= "Sync" and not frame.scripts.OnEnterPressed
            or frame == row.modEdit, "removed master control still exists")
    end
end)

test("window width fits the table columns", function()
    -- Margins 14+30, columns 4+16+2+170+2+90+4+110+10+60.
    local requiredWidth = 14 + 4 + 16 + 2 + 170 + 2 + 90 + 4 + 110 + 10 + 60 + 30
    assert(main.width >= requiredWidth and main.minWidth >= requiredWidth)
    local playerHeader, classHeader
    for _, frame in ipairs(f.frames) do
        if frame.label == "Player" then playerHeader = frame end
        if frame.label == "Class" then classHeader = frame end
    end
    assert(playerHeader.pointArgs[1] == 22)
    assert(classHeader.pointArgs[3] == 2 and row.classText.pointArgs[3] == 2)
end)

test("master buttons are bright for the master and dim for others", function()
    rowA, rowB = f.env.CreateFrame("Frame"), f.env.CreateFrame("Frame")
    f.initRow(rowA, main.scrollBox.data[1])
    f.initRow(rowB, main.scrollBox.data[2])
    assert(rowA.key == "Master" and rowB.key == "Follower")
    masterA, masterB = rowA.masterButton, rowB.masterButton
    assert(masterA.pointArgs[1] == rowA and masterA.pointArgs[2] == "LEFT" and masterA.pointArgs[3] == 4)
    assert(rowA.nameText.pointArgs[1] == masterA and rowA.nameText.pointArgs[2] == "RIGHT")
    assert(masterA.icon.desaturated and masterA.icon.alpha < 1)
    assert(not masterB.icon.desaturated and masterB.icon.alpha == 1)
    assert(masterA.glow == nil and masterB.glow == nil)
end)

test("master button tooltips describe the action", function()
    masterA.scripts.OnEnter(masterA)
    assert(f.env.GameTooltip.text == f.ns.L.SET_AS_MASTER)
    masterB.scripts.OnEnter(masterB)
    assert(f.env.GameTooltip.text == f.ns.L.CLEAR_MASTER)
end)

test("clicking a master button selects that master and locks local edits", function()
    masterA.scripts.OnClick()
    assert(f.ns.db.sync.master == "Master" and not f.ns.IsMaster() and not f.ns.CanEditModifiers())
    f.initRow(rowA, main.scrollBox.data[1])
    f.initRow(rowB, main.scrollBox.data[2])
    assert(not masterA.icon.desaturated and masterA.icon.alpha == 1)
    assert(masterB.icon.desaturated and masterB.icon.alpha < 1)
    assert(not rowA.modEdit.enabled)
    masterA.scripts.OnClick()
    assert(f.ns.db.sync.master == nil and not f.ns.CanEditModifiers(), "no master: read-only")
    f.initRow(rowA, main.scrollBox.data[1])
    assert(masterA.icon.desaturated and masterA.icon.alpha < 1 and not rowA.modEdit.enabled)
    masterB.scripts.OnClick()
    assert(f.ns.IsMaster() and f.ns.CanEditModifiers())
    masterA.scripts.OnClick()
    assert(f.ns.db.sync.master == "Master")
end)

test("Tools menu lists sync, self-master, backup, export, import, restore and reset", function()
    labels = menuEntries()
    for _, key in ipairs({ "SYNC_FROM_MASTER", "SET_MASTER", "BACKUP", "EXPORT", "IMPORT", "RESTORE", "RESET" }) do
        assert(labels[f.ns.L[key]], key)
    end
    local syncIndex, masterIndex
    for index, entry in ipairs(f.menu) do
        if entry.label == f.ns.L.SYNC_FROM_MASTER then syncIndex = index end
        if entry.label == f.ns.L.SET_MASTER then masterIndex = index end
    end
    assert(masterIndex == syncIndex + 1, "Set as master should follow Sync from master")
    labels[f.ns.L.SET_MASTER].action()
    assert(f.ns.db.sync.master == "Follower" and f.ns.IsMaster())
    assert(menuEntries()[f.ns.L.SET_MASTER].enabled == false, "greyed out while already master")
    assert(f.ns.SelectMaster("Master"))
    assert(not labels[f.ns.L.CANCEL_SYNC])
end)

test("Reset data asks for confirmation, then resets and stays available to followers", function()
    f.ns.db.modifiers = { Master = 3 }
    f.ns.db.sync.updatedAt = 99
    local entry = menuEntries()[f.ns.L.RESET]
    assert(entry.enabled ~= false and not f.ns.CanEditModifiers())
    entry.action()
    assert(f.popup == "ROLLOVER_RESET_DATA" and f.ns.GetModifier("Master") == 3, "nothing happens before confirming")
    assert(f.env.StaticPopupDialogs.ROLLOVER_RESET_DATA.text == f.ns.L.RESET_CONFIRM)
    f.env.StaticPopupDialogs.ROLLOVER_RESET_DATA.OnAccept()
    assert(f.ns.GetModifier("Master") == 0 and f.ns.db.sync.updatedAt == 0)
end)

test("Tools sync becomes Cancel while receiving and locks the master buttons", function()
    advance(35)
    labels[f.ns.L.SYNC_FROM_MASTER].action()
    assert(f.ns.IsSyncPending())
    f.initRow(rowA, main.scrollBox.data[1])
    assert(not masterA.enabled)
    labels = menuEntries()
    assert(labels[f.ns.L.CANCEL_SYNC] and not labels[f.ns.L.SYNC_FROM_MASTER])
    assert(labels[f.ns.L.SET_MASTER].enabled == false)
    assert(labels[f.ns.L.IMPORT].enabled == false and labels[f.ns.L.RESTORE].enabled == false)
    assert(labels[f.ns.L.RESET].enabled == false)
end)

test("Cancel restores the Tools sync entry and unlocks the master buttons", function()
    labels[f.ns.L.CANCEL_SYNC].action()
    assert(not f.ns.IsSyncPending())
    f.initRow(rowA, main.scrollBox.data[1])
    assert(masterA.enabled)
    assert(menuEntries()[f.ns.L.SYNC_FROM_MASTER])
    advance(35)
end)

test("realm-less 'First Last' names can be edited in the roster", function()
    local rp = client("Andriod En")
    rp.roster = { "Andriod En", "Other Player", "Third Guy" }
    assert(rp.ns.SelectMaster("Andriod En") and rp.ns.IsMaster())
    rp.ns.ToggleMainFrame()
    local realmlessRow = rp.env.CreateFrame("Frame")
    rp.initRow(realmlessRow, rp.frames.RolloverMainFrame.scrollBox.data[1])
    assert(realmlessRow.key == "Andriod En")
    realmlessRow.modEdit:SetText("220")
    realmlessRow.modEdit.scripts.OnEditFocusLost(realmlessRow.modEdit)
    assert(rp.ns.GetModifier("Andriod En") == 220 and rp.ns.GetPlayerModifier() == 220)
end)
