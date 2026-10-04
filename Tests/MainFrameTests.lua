-- Run with a standalone Lua interpreter: lua Tests\MainFrameTests.lua <addon directory>
-- Covers UI\MainFrame.lua: roster rows and sorting, master buttons and the Tools menu.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client, delivered = harness.advance, harness.client, harness.delivered
local test = harness.suite("UI\\MainFrame.lua")

local p, f = client("Master"), client("Follower")
assert(p.ns.SelectMaster("Master") and f.ns.SelectMaster("Master"))
local main, tools

local function find(predicate)
    for _, frame in ipairs(f.frames) do if predicate(frame) then return frame end end
end

-- A row initialized with the index-th roster entry, as the ScrollBox would.
local function row(index)
    local r = f.env.CreateFrame("Frame")
    f.initRow(r, main.scrollBox.data[index])
    return r
end

local function names()
    local list = {}
    for _, entry in ipairs(main.scrollBox.data) do list[#list + 1] = entry.name end
    return table.concat(list, ",")
end

local function menu()
    tools.scripts.OnClick(tools)
    local entries = {}
    for _, entry in ipairs(f.menu) do entries[entry.label] = entry end
    return entries
end

test("opening requests the roster and lists it by rank", function()
    f.ns.ToggleMainFrame()
    main = f.frames.RolloverMainFrame
    tools = find(function(frame) return frame.normalTexture and frame.normalTexture:find("Gear", 1, true) end)
    assert(main:IsShown() and f.rosterRequested and tools)
    assert(names() == "Master,Follower,ZeroMember,ThirdMember", names())
end)

test("clicking a header sorts by it, clicking again reverses", function()
    local nameHeader = find(function(frame) return frame.label == "Name" end)
    nameHeader.scripts.OnClick()
    assert(names() == "Follower,Master,ThirdMember,ZeroMember", names())
    nameHeader.scripts.OnClick()
    assert(names() == "ZeroMember,ThirdMember,Master,Follower", names())
    find(function(frame) return frame.label == "Rank" end).scripts.OnClick()
end)

test("modifiers are editable only for the master", function()
    assert(not row(1).modEdit.enabled)
    assert(f.ns.SelectMaster("Follower"))
    local edit = row(1).modEdit
    assert(edit.enabled)
    edit:SetText("-9")
    edit.scripts.OnEditFocusLost(edit)
    assert(f.ns.GetModifier("Master") == -9)
    edit:SetText("abc")
    edit.scripts.OnEditFocusLost(edit)
    assert(f.ns.GetModifier("Master") == -9 and edit:GetText() == "-9", "invalid input shows the saved value")
end)

test("master buttons are bright for the master, describe their action and toggle it", function()
    local masterRow, followerRow = row(1), row(2)
    assert(masterRow.masterButton.icon.desaturated and masterRow.masterButton.icon.alpha < 1)
    assert(not followerRow.masterButton.icon.desaturated and followerRow.masterButton.icon.alpha == 1)
    masterRow.masterButton.scripts.OnEnter(masterRow.masterButton)
    assert(f.env.GameTooltip.text == f.ns.L.SET_AS_MASTER)
    followerRow.masterButton.scripts.OnEnter(followerRow.masterButton)
    assert(f.env.GameTooltip.text == f.ns.L.CLEAR_MASTER)
    masterRow.masterButton.scripts.OnClick()
    assert(f.ns.db.sync.master == "Master" and not f.ns.CanEditModifiers())
    assert(not row(1).masterButton.icon.desaturated and row(2).masterButton.icon.desaturated)
    masterRow.masterButton.scripts.OnClick()
    assert(f.ns.db.sync.master == nil, "clicking the current master deselects it")
    masterRow.masterButton.scripts.OnClick()
end)

test("Tools menu: self-master, and import/restore only for the master", function()
    local entries = menu()
    for _, key in ipairs({ "SYNC_FROM_MASTER", "SET_MASTER", "BACKUP", "EXPORT", "IMPORT", "RESTORE", "RESET" }) do
        assert(entries[f.ns.L[key]], key)
    end
    assert(entries[f.ns.L.IMPORT].enabled == false and entries[f.ns.L.RESTORE].enabled == false)
    entries[f.ns.L.SET_MASTER].action()
    assert(f.ns.IsMaster())
    entries = menu()
    assert(entries[f.ns.L.SET_MASTER].enabled == false and entries[f.ns.L.IMPORT].enabled)
    assert(f.ns.SelectMaster("Master"))
end)

test("Reset data asks for confirmation first", function()
    f.ns.db.modifiers = { Master = 3 }
    menu()[f.ns.L.RESET].action()
    assert(f.popup == "ROLLOVER_RESET_DATA" and f.ns.GetModifier("Master") == 3)
    f.env.StaticPopupDialogs.ROLLOVER_RESET_DATA.OnAccept()
    assert(f.ns.GetModifier("Master") == 0)
end)

test("Sync from master is not initiated while the master is offline", function()
    advance(35)
    local mark = #delivered
    menu()[f.ns.L.SYNC_FROM_MASTER].action()
    assert(not f.ns.IsSyncPending() and #delivered == mark)
    assert(f.prints[#f.prints]:find("Sync not initiated: master Master is offline.", 1, true))
end)

test("while receiving, Sync becomes Cancel and master changes are locked", function()
    advance(35)
    f.online.Master = true
    menu()[f.ns.L.SYNC_FROM_MASTER].action()
    assert(f.ns.IsSyncPending() and not row(1).masterButton.enabled)
    local entries = menu()
    assert(entries[f.ns.L.CANCEL_SYNC] and not entries[f.ns.L.SYNC_FROM_MASTER])
    for _, key in ipairs({ "SET_MASTER", "IMPORT", "RESTORE", "RESET" }) do
        assert(entries[f.ns.L[key]].enabled == false, key)
    end
    entries[f.ns.L.CANCEL_SYNC].action()
    assert(not f.ns.IsSyncPending() and row(1).masterButton.enabled and menu()[f.ns.L.SYNC_FROM_MASTER])
end)
