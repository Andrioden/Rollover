-- Run with a standalone Lua interpreter: lua Tests\MainFrameTests.lua <addon directory>
-- Covers UI\MainFrame.lua: roster rows, permissions, publisher crowns and the Tools menu.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local test = harness.suite("UI\\MainFrame.lua")

local p, f = client("Publisher"), client("Follower")
assert(p.ns.SelectPublisher("Publisher") and f.ns.SelectPublisher("Publisher"))
local main, row, tools, rowA, rowB, crownA, crownB, labels

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

test("rows are read-only for followers and editable for the publisher", function()
    row = f.env.CreateFrame("Frame")
    f.initRow(row, main.scrollBox.data[1])
    assert(not row.modEdit.enabled)
    assert(f.ns.SelectPublisher("Follower"))
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
            or frame == row.modEdit, "removed publisher control still exists")
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

test("crowns are bright for the publisher and dim for others", function()
    rowA, rowB = f.env.CreateFrame("Frame"), f.env.CreateFrame("Frame")
    f.initRow(rowA, main.scrollBox.data[1])
    f.initRow(rowB, main.scrollBox.data[2])
    assert(rowA.key == "Publisher" and rowB.key == "Follower")
    crownA, crownB = rowA.publisherButton, rowB.publisherButton
    assert(crownA.pointArgs[1] == rowA and crownA.pointArgs[2] == "LEFT" and crownA.pointArgs[3] == 4)
    assert(rowA.nameText.pointArgs[1] == crownA and rowA.nameText.pointArgs[2] == "RIGHT")
    assert(crownA.icon.desaturated and crownA.icon.alpha < 1)
    assert(not crownB.icon.desaturated and crownB.icon.alpha == 1)
    assert(crownA.glow == nil and crownB.glow == nil)
end)

test("crown tooltips describe the action", function()
    crownA.scripts.OnEnter(crownA)
    assert(f.env.GameTooltip.text == f.ns.L.SET_PUBLISHER)
    crownB.scripts.OnEnter(crownB)
    assert(f.env.GameTooltip.text == f.ns.L.CURRENT_PUBLISHER)
end)

test("clicking a crown selects that publisher and locks local edits", function()
    crownA.scripts.OnClick()
    assert(f.ns.db.sync.publisher == "Publisher" and not f.ns.IsPublisher() and not f.ns.CanEditModifiers())
    f.initRow(rowA, main.scrollBox.data[1])
    f.initRow(rowB, main.scrollBox.data[2])
    assert(not crownA.icon.desaturated and crownA.icon.alpha == 1)
    assert(crownB.icon.desaturated and crownB.icon.alpha < 1)
    assert(not rowA.modEdit.enabled)
    crownA.scripts.OnClick()
    assert(f.ns.db.sync.publisher == "Publisher")
end)

test("Tools menu lists sync, self-publisher, backup, export, import and restore", function()
    labels = menuEntries()
    for _, key in ipairs({ "SYNC_FROM_PUBLISHER", "SET_PUBLISHER", "BACKUP", "EXPORT", "IMPORT", "RESTORE" }) do
        assert(labels[f.ns.L[key]], key)
    end
    local syncIndex, publisherIndex
    for index, entry in ipairs(f.menu) do
        if entry.label == f.ns.L.SYNC_FROM_PUBLISHER then syncIndex = index end
        if entry.label == f.ns.L.SET_PUBLISHER then publisherIndex = index end
    end
    assert(publisherIndex == syncIndex + 1, "Set as publisher should follow Sync from publisher")
    labels[f.ns.L.SET_PUBLISHER].action()
    assert(f.ns.db.sync.publisher == "Follower" and f.ns.IsPublisher())
    assert(f.ns.SelectPublisher("Publisher"))
    assert(not labels[f.ns.L.CANCEL_SYNC])
end)

test("Tools sync becomes Cancel while receiving and locks the crowns", function()
    advance(35)
    labels[f.ns.L.SYNC_FROM_PUBLISHER].action()
    assert(f.ns.IsSyncPending())
    f.initRow(rowA, main.scrollBox.data[1])
    assert(not crownA.enabled)
    labels = menuEntries()
    assert(labels[f.ns.L.CANCEL_SYNC] and not labels[f.ns.L.SYNC_FROM_PUBLISHER])
    assert(labels[f.ns.L.SET_PUBLISHER].enabled == false)
    assert(labels[f.ns.L.IMPORT].enabled == false and labels[f.ns.L.RESTORE].enabled == false)
end)

test("Cancel restores the Tools sync entry and unlocks the crowns", function()
    labels[f.ns.L.CANCEL_SYNC].action()
    assert(not f.ns.IsSyncPending())
    f.initRow(rowA, main.scrollBox.data[1])
    assert(crownA.enabled)
    assert(menuEntries()[f.ns.L.SYNC_FROM_PUBLISHER])
    advance(35)
end)

test("realm-less 'First Last' names can be edited in the roster", function()
    local rp = client("Andriod En")
    rp.roster = { "Andriod En", "Other Player", "Third Guy" }
    assert(rp.ns.SelectPublisher("Andriod En") and rp.ns.IsPublisher())
    rp.ns.ToggleMainFrame()
    local realmlessRow = rp.env.CreateFrame("Frame")
    rp.initRow(realmlessRow, rp.frames.RolloverMainFrame.scrollBox.data[1])
    assert(realmlessRow.key == "Andriod En")
    realmlessRow.modEdit:SetText("220")
    realmlessRow.modEdit.scripts.OnEditFocusLost(realmlessRow.modEdit)
    assert(rp.ns.GetModifier("Andriod En") == 220 and rp.ns.GetPlayerModifier() == 220)
end)
