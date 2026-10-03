local addonName, ns = ...

local frame
local log = {}
local MAX_LINES = 200

function ns.Debug(msg)
    log[#log + 1] = date("%H:%M:%S") .. " " .. msg
    if #log > MAX_LINES then
        table.remove(log, 1)
    end
end

local function CreateDebugFrame()
    frame = CreateFrame("Frame", "RolloverDebugFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, 300)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    local title = "Rollover | Debug log (Ctrl+C to copy)"
    if frame.SetTitle then
        frame:SetTitle(title)
    else
        frame.TitleText:SetText(title)
    end

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -34)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(410)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    scroll:SetScrollChild(edit)
    frame.edit = edit

    frame:SetScript("OnShow", function()
        -- Escape pipes so link/color codes show as plain text.
        local text = table.concat(log, "\n"):gsub("|", "||")
        edit:SetText(text ~= "" and text or "(no debug messages yet)")
        edit:SetFocus()
        edit:HighlightText()
    end)

    tinsert(UISpecialFrames, "RolloverDebugFrame")
    frame:Hide()
end

function ns.ToggleDebugFrame()
    if not frame then CreateDebugFrame() end
    frame:SetShown(not frame:IsShown())
end
