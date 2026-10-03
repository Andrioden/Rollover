local addonName, ns = ...

local frame

local function CreateImportFrame()
    frame = CreateFrame("Frame", "RolloverImportFrame", UIParent, "BasicFrameTemplateWithInset")
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
        frame:SetTitle(ns.L.IMPORT_TITLE)
    else
        frame.TitleText:SetText(ns.L.IMPORT_TITLE)
    end

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -34)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(410)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    scroll:SetScrollChild(edit)
    frame.edit, frame.scroll = edit, scroll

    local import = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    import:SetSize(100, 24)
    import:SetPoint("BOTTOM", 0, 12)
    import:SetText(ns.L.IMPORT_BUTTON)
    import:SetScript("OnClick", function()
        if ns.ImportModifiers(edit:GetText()) then frame:Hide() end
    end)

    tinsert(UISpecialFrames, "RolloverImportFrame")
    frame:Hide()
end

function ns.ShowImportFrame()
    if not frame then CreateImportFrame() end
    frame.edit:SetText("")
    frame.scroll:SetVerticalScroll(0)
    frame:Show()
    frame.edit:SetFocus()
end
