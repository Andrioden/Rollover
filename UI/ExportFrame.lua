local addonName, ns = ...

local frame

local function CreateExportFrame()
    frame = CreateFrame("Frame", "RolloverExportFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, 300)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    if frame.SetTitle then
        frame:SetTitle(ns.L.EXPORT_TITLE)
    else
        frame.TitleText:SetText(ns.L.EXPORT_TITLE)
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
    -- Copy-only: typing restores the exported text.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(frame.text)
            self:HighlightText()
        end
    end)
    scroll:SetScrollChild(edit)
    frame.edit, frame.scroll = edit, scroll

    tinsert(UISpecialFrames, "RolloverExportFrame")
    frame:Hide()
end

function ns.ShowExportFrame(text)
    if not frame then CreateExportFrame() end
    frame.text = text
    frame.edit:SetText(text)
    frame.scroll:SetVerticalScroll(0)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end
