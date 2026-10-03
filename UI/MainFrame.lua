local addonName, ns = ...

local frame

local function CreateMainFrame()
    frame = CreateFrame("Frame", "RolloverMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(500, 400)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    local title = "Rollover " .. ns.version
    if frame.SetTitle then
        frame:SetTitle(title)
    else
        frame.TitleText:SetText(title)
    end

    -- Lets Escape close the window.
    tinsert(UISpecialFrames, "RolloverMainFrame")
    frame:Hide()
end

function ns.ToggleMainFrame()
    if not frame then CreateMainFrame() end
    frame:SetShown(not frame:IsShown())
end
