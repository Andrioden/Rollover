local addonName, ns = ...

local frame

function ns.ShowImportFrame()
    if not frame then
        frame = ns.CreateTextDialog("RolloverImportFrame", ns.L.IMPORT_TITLE, 44)
        local import = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        import:SetSize(100, 24)
        import:SetPoint("BOTTOM", 0, 12)
        import:SetText(ns.L.IMPORT_BUTTON)
        import:SetScript("OnClick", function()
            if ns.ImportModifiers(frame.edit:GetText()) then frame:Hide() end
        end)
    end
    frame.edit:SetText("")
    frame.scroll:SetVerticalScroll(0)
    frame:Show()
    frame.edit:SetFocus()
end