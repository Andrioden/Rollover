-- Run with a standalone Lua interpreter: lua Tests\ImportExportTests.lua <addon directory>
-- Covers JSON import/export (Core\DB.lua) and the export, import and debug windows.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local client = harness.client
local test = harness.suite("Import/export and text windows")

local f = client("Follower")
f.ns.SelectPublisher("Publisher")
local exportFrame, importFrame

test("import rejects invalid JSON and keeps current data", function()
    f.ns.db.modifiers = { OldMember = 42 }
    assert(not f.ns.ImportModifiers('{"bad|name":7}'))
    assert(not f.ns.ImportModifiers('{"":7}'))
    assert(not f.ns.ImportModifiers('{"Publisher":"bad"}'))
    assert(not f.ns.ImportModifiers("{bad}"))
    assert(not f.ns.ImportModifiers("[]"))
    assert(not f.ns.ImportModifiers(string.rep(" ", 200001)))
    assert(f.ns.GetModifier("OldMember") == 42)
end)

test("import replaces the modifier table (followers may import)", function()
    assert(f.ns.ImportModifiers('{"Publisher":7,"ZeroMember":0}'))
    assert(f.ns.GetModifier("Publisher") == 7 and f.ns.GetModifier("OldMember") == 0)
end)

test("export window shows the JSON and is copy-only", function()
    f.ns.ExportModifiers()
    exportFrame = f.frames.RolloverExportFrame
    local exported = '{"Publisher":7,"ZeroMember":0}'
    assert(exportFrame:IsShown() and exportFrame.title == f.ns.L.EXPORT_TITLE)
    assert(exportFrame.edit:GetText() == exported and exportFrame.edit.focused)
    exportFrame.edit:SetText("tampered")
    exportFrame.edit.scripts.OnTextChanged(exportFrame.edit, true)
    assert(exportFrame.edit:GetText() == exported)
end)

test("export of an empty table is {}", function()
    local saved = f.ns.db.modifiers
    f.ns.db.modifiers = {}
    f.ns.ExportModifiers()
    assert(exportFrame.edit:GetText() == "{}")
    f.ns.db.modifiers = saved
end)

test("import window keeps invalid text open and closes after success", function()
    assert(not f.frames.RolloverImportFrame)
    f.ns.ShowImportFrame()
    importFrame = f.frames.RolloverImportFrame
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
end)

test("debug window toggles", function()
    f.ns.ToggleDebugFrame()
    assert(f.frames.RolloverDebugFrame:IsShown())
    f.ns.ToggleDebugFrame()
    assert(not f.frames.RolloverDebugFrame:IsShown())
end)

test("missing JSON API is handled without errors", function()
    local noAPI = client("NoAPI")
    noAPI.env.C_EncodingUtil = nil
    assert(not noAPI.ns.ImportModifiers("{}"))
    noAPI.ns.ExportModifiers()
end)

test("realm-less 'First Last' names export and import", function()
    local rp = client("Andriod En")
    rp.roster = { "Andriod En", "Other Player", "Third Guy" }
    assert(rp.ns.SetModifier("Andriod En", 220) and rp.ns.SetModifier("Other Player", -3))
    rp.ns.ExportModifiers()
    assert(rp.frames.RolloverExportFrame.edit:GetText():find('"Andriod En":220', 1, true))
    assert(rp.ns.ImportModifiers('{"Andriod En":220}') and rp.ns.GetModifier("Other Player") == 0)
    for _, line in ipairs(rp.prints) do assert(not line:find("unambiguous", 1, true), line) end
end)
