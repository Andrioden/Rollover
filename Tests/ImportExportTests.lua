-- Run with a standalone Lua interpreter: lua Tests\ImportExportTests.lua <addon directory>
-- Covers JSON import/export (Core\DB.lua) and the export, import and debug windows.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local advance, client = harness.advance, harness.client
local test = harness.suite("Import/export and text windows")

local f = client("Follower")
local exportFrame, importFrame

local function json(modifiers, stamp)
    return '{"updatedAt":' .. stamp .. ',"modifiers":' .. modifiers .. '}'
end

-- Server time of the mocked client; imports may not be from the future.
local function T() return f.env.GetServerTime() end

test("import rejects invalid JSON and keeps current data", function()
    assert(f.ns.SelectMaster("Follower"))
    f.ns.db.modifiers = { OldMember = 42 }
    assert(not f.ns.ImportModifiers(json('{"bad|name":7}', T())))
    assert(not f.ns.ImportModifiers(json('{"":7}', T())))
    assert(not f.ns.ImportModifiers(json('{"Master":"bad"}', T())))
    assert(not f.ns.ImportModifiers("{bad}"))
    assert(not f.ns.ImportModifiers("[]"))
    assert(not f.ns.ImportModifiers('{"Master":7}'), "the old flat format has no modifiers key")
    assert(not f.ns.ImportModifiers('{"updatedAt":' .. T() .. '}'))
    assert(not f.ns.ImportModifiers(string.rep(" ", 200001)))
    assert(f.ns.GetModifier("OldMember") == 42)
end)

test("import rejects an invalid updatedAt", function()
    for _, stamp in ipairs({ '"text"', "-1", "1.5", T() + 1, "1e300" }) do
        assert(not f.ns.ImportModifiers(json('{"Master":7}', stamp)), tostring(stamp))
    end
    assert(f.ns.GetModifier("OldMember") == 42)
end)

test("import replaces the modifier table", function()
    assert(f.ns.ImportModifiers(json('{"Master":7,"ZeroMember":0}', T())))
    assert(f.ns.GetModifier("Master") == 7 and f.ns.GetModifier("OldMember") == 0)
    assert(f.ns.db.sync.updatedAt == T(), "the data keeps the age it came with")
end)

test("import of data older than the current state is blocked, equal or newer is accepted", function()
    advance(100)
    local stamp = f.ns.db.sync.updatedAt
    assert(stamp)
    local backups = 0
    for _ in pairs(f.ns.db.backups) do backups = backups + 1 end
    assert(not f.ns.ImportModifiers(json('{"Master":99}', stamp - 1)))
    assert(f.ns.GetModifier("Master") == 7 and f.ns.db.sync.updatedAt == stamp)
    local after = 0
    for _ in pairs(f.ns.db.backups) do after = after + 1 end
    assert(after == backups, "a blocked import does not touch backups")
    local output = table.concat(f.prints, "\n")
    assert(output:find("Import blocked", 1, true))
    assert(f.ns.ImportModifiers(json('{"Master":8}', stamp)) and f.ns.GetModifier("Master") == 8)
    assert(f.ns.db.sync.updatedAt == stamp, "an import never makes data look newer than it is")
    assert(f.ns.ImportModifiers(json('{"Master":9}', T())) and f.ns.GetModifier("Master") == 9)
    assert(f.ns.db.sync.updatedAt == T())
end)

test("a missing updatedAt counts as the oldest state", function()
    assert(not f.ns.ImportModifiers('{"modifiers":{"Master":1}}'))
    f.ns.ResetData()
    assert(f.ns.ImportModifiers('{"modifiers":{"Master":1}}') and f.ns.GetModifier("Master") == 1)
    assert(f.ns.ImportModifiers(json('{"Master":7,"ZeroMember":0}', T())))
end)

test("reset data lets an old export be imported", function()
    local oldJSON = json('{"Master":3}', T() - 50)
    assert(not f.ns.ImportModifiers(oldJSON))
    assert(f.ns.ResetData() and f.ns.db.sync.updatedAt == 0)
    assert(f.ns.ImportModifiers(oldJSON) and f.ns.GetModifier("Master") == 3)
    assert(f.ns.db.sync.updatedAt == T() - 50)
    assert(f.ns.ImportModifiers(json('{"Master":7,"ZeroMember":0}', T())))
end)

test("export window shows the JSON and is copy-only", function()
    f.ns.ExportModifiers()
    exportFrame = f.frames.RolloverExportFrame
    local exported = '{"modifiers":{"Master":7,"ZeroMember":0},"updatedAt":' .. f.ns.db.sync.updatedAt .. '}'
    assert(exportFrame:IsShown() and exportFrame.title == f.ns.L.EXPORT_TITLE)
    assert(exportFrame.edit:GetText() == exported and exportFrame.edit.focused)
    exportFrame.edit:SetText("tampered")
    exportFrame.edit.scripts.OnTextChanged(exportFrame.edit, true)
    assert(exportFrame.edit:GetText() == exported)
end)

test("export carries updatedAt (0 when unknown) and round-trips through import", function()
    local saved, stamp = f.ns.db.modifiers, f.ns.db.sync.updatedAt
    f.ns.db.modifiers, f.ns.db.sync.updatedAt = {}, nil
    f.ns.ExportModifiers()
    assert(exportFrame.edit:GetText() == '{"modifiers":{},"updatedAt":0}')
    f.ns.db.modifiers, f.ns.db.sync.updatedAt = saved, stamp
    f.ns.ExportModifiers()
    local text = exportFrame.edit:GetText()
    assert(f.ns.ImportModifiers(text) and f.ns.GetModifier("Master") == 7)
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
    assert(importFrame:IsShown() and f.ns.GetModifier("Master") == 7)
    importFrame.edit:SetText(json("{}", f.ns.db.sync.updatedAt))
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
    noAPI.roster = { "NoAPI" }
    assert(noAPI.ns.SelectMaster("NoAPI"))
    assert(not noAPI.ns.ImportModifiers(json("{}", T())))
    noAPI.ns.ExportModifiers()
end)

test("realm-less 'First Last' names export and import", function()
    local rp = client("Andriod En")
    rp.roster = { "Andriod En", "Other Player", "Third Guy" }
    assert(rp.ns.SelectMaster("Andriod En") and rp.ns.SetModifier("Andriod En", 220) and rp.ns.SetModifier("Other Player", -3))
    rp.ns.ExportModifiers()
    assert(rp.frames.RolloverExportFrame.edit:GetText():find('"Andriod En":220', 1, true))
    advance(5) -- edits may push the stamp up to a few seconds past the server clock
    assert(rp.ns.ImportModifiers(json('{"Andriod En":220}', rp.ns.db.sync.updatedAt)) and rp.ns.GetModifier("Other Player") == 0)
    for _, line in ipairs(rp.prints) do assert(not line:find("unambiguous", 1, true), line) end
end)
