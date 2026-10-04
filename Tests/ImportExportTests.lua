-- Run with a standalone Lua interpreter: lua Tests\ImportExportTests.lua <addon directory>
-- Covers JSON import/export (Core\DB.lua) and the export, import and debug windows.
local root = arg[1] or "."
package.path = root .. "\\?.lua;" .. package.path
local harness = require("Tests.MockClient").new(root)
local client, last, backupCount = harness.client, harness.last, harness.backupCount
local test = harness.suite("Import/export and text windows")

local f = client("Follower")
assert(f.ns.SelectMaster("Follower"))

local function json(modifiers, stamp)
    return '{"updatedAt":' .. stamp .. ',"modifiers":' .. modifiers .. '}'
end

-- Server time of the mocked client; imports may not be from the future.
local function T() return f.env.GetServerTime() end

test("invalid JSON, shapes, names, values and stamps are rejected without changes", function()
    f.ns.db.modifiers = { OldMember = 42 }
    local backups = backupCount(f)
    local invalid = {
        "{bad}", "[]", "5", '{"Master":7}', '{"updatedAt":' .. T() .. '}', string.rep(" ", 200001),
        json('{"bad|name":7}', T()), json('{"":7}', T()), json('{"Master":"bad"}', T()),
        json("{}", '"text"'), json("{}", -1), json("{}", 1.5), json("{}", T() + 1), json("{}", "1e300"),
    }
    for _, text in ipairs(invalid) do assert(not f.ns.ImportModifiers(text), text:sub(1, 60)) end
    assert(f.ns.GetModifier("OldMember") == 42 and backupCount(f) == backups)
end)

test("imports are limited to ns.MAX_MEMBERS entries", function()
    local entries = {}
    for i = 1, f.ns.MAX_MEMBERS + 1 do entries[i] = '"Member' .. i .. '":0' end
    assert(not f.ns.ImportModifiers(json("{" .. table.concat(entries, ",") .. "}", T())))
    assert(last(f):find(string.format(f.ns.L.STATE_TOO_LARGE, f.ns.MAX_MEMBERS), 1, true))
    entries[#entries] = nil
    assert(f.ns.ImportModifiers(json("{" .. table.concat(entries, ",") .. "}", T() - 10)))
end)

test("import replaces the table, keeps its own age and backs up the previous state", function()
    local backups = backupCount(f)
    assert(f.ns.ImportModifiers(json('{"Master":7,"ZeroMember":0}', T() - 10)))
    assert(f.ns.GetModifier("Master") == 7 and f.ns.GetModifier("Member1") == 0)
    assert(f.ns.GetUpdatedAt() == T() - 10 and backupCount(f) == backups + 1)
end)

test("older imports are blocked; equal or newer ones are accepted", function()
    local stamp = f.ns.GetUpdatedAt()
    assert(not f.ns.ImportModifiers(json('{"Master":99}', stamp - 1)) and last(f):find("Import blocked", 1, true))
    assert(not f.ns.ImportModifiers('{"modifiers":{"Master":99}}'), "a missing updatedAt is the oldest")
    assert(f.ns.GetModifier("Master") == 7)
    assert(f.ns.ImportModifiers(json('{"Master":8}', stamp)) and f.ns.GetModifier("Master") == 8)
    assert(f.ns.ImportModifiers(json('{"Master":9}', stamp + 1)) and f.ns.GetUpdatedAt() == stamp + 1)
end)

test("reset data lets older data be imported", function()
    assert(f.ns.ResetData())
    assert(f.ns.ImportModifiers('{"modifiers":{"Master":3}}') and f.ns.GetModifier("Master") == 3)
end)

test("export shows copy-only JSON that round-trips through import", function()
    f.ns.db.modifiers, f.ns.db.sync.updatedAt = { Master = 7 }, T()
    f.ns.ExportModifiers()
    local window = f.frames.RolloverExportFrame
    local exported = '{"modifiers":{"Master":7},"updatedAt":' .. T() .. '}'
    assert(window:IsShown() and window.edit:GetText() == exported)
    window.edit:SetText("tampered")
    window.edit.scripts.OnTextChanged(window.edit, true)
    assert(window.edit:GetText() == exported)
    f.ns.db.modifiers = {}
    assert(f.ns.ImportModifiers(exported) and f.ns.GetModifier("Master") == 7)
end)

test("import window stays open on invalid text and closes after success", function()
    f.ns.ShowImportFrame()
    local window = f.frames.RolloverImportFrame
    local importButton
    for _, button in ipairs(f.frames) do
        if button.text == f.ns.L.IMPORT_BUTTON then importButton = button end
    end
    window.edit:SetText("{bad}")
    importButton.scripts.OnClick()
    assert(window:IsShown() and f.ns.GetModifier("Master") == 7)
    window.edit:SetText(json("{}", f.ns.GetUpdatedAt()))
    importButton.scripts.OnClick()
    assert(next(f.ns.db.modifiers) == nil and not window:IsShown())
    f.ns.ShowImportFrame()
    assert(window.edit:GetText() == "", "reopening clears the text")
end)

test("debug window toggles", function()
    f.ns.ToggleDebugFrame()
    assert(f.frames.RolloverDebugFrame:IsShown())
    f.ns.ToggleDebugFrame()
    assert(not f.frames.RolloverDebugFrame:IsShown())
end)

test("a missing JSON API is reported instead of erroring", function()
    local noAPI = client("NoAPI")
    noAPI.env.C_EncodingUtil = nil
    noAPI.roster = { "NoAPI" }
    assert(noAPI.ns.SelectMaster("NoAPI"))
    assert(not noAPI.ns.ImportModifiers(json("{}", T())) and     last(noAPI):find(noAPI.ns.L.JSON_UNAVAILABLE, 1, true))
    noAPI.ns.ExportModifiers()
    assert(last(noAPI):find(noAPI.ns.L.JSON_UNAVAILABLE, 1, true))
end)
