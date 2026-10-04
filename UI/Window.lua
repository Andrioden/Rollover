local addonName, ns = ...

-- Hidden, movable dialog window that Escape closes.
function ns.CreateWindow(name, title, width, height)
    local frame = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if frame.SetTitle then
        frame:SetTitle(title)
    else
        frame.TitleText:SetText(title)
    end
    tinsert(UISpecialFrames, name)
    frame:Hide()
    return frame
end
