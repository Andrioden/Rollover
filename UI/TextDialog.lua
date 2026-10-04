local addonName, ns = ...

-- Window with a scrolling multi-line edit box (frame.edit, frame.scroll).
-- bottomInset leaves room under the text for buttons.
function ns.CreateTextDialog(name, title, bottomInset)
    local frame = ns.CreateWindow(name, title, 460, 300)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -34)
    scroll:SetPoint("BOTTOMRIGHT", -32, bottomInset or 12)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(410)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    scroll:SetScrollChild(edit)
    frame.edit, frame.scroll = edit, scroll
    return frame
end
