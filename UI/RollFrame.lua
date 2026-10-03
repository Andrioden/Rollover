local addonName, ns = ...

local frame
local pending -- { modifier } snapshot while waiting for the /roll result

local ROLL_MIN, ROLL_MAX = 1, 100
local ROLL_TIMEOUT = 5

-- Turns RANDOM_ROLL_RESULT ("%s rolls %d (%d-%d)") into a Lua pattern.
local rollPattern = "^" .. RANDOM_ROLL_RESULT
    :gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    :gsub("%%s", "(.+)")
    :gsub("%%d", "(%%d+)") .. "$"

local function FormatModifier(value)
    return value >= 0 and ("+" .. value) or tostring(value)
end

local function ClearPending()
    pending = nil
    frame.events:UnregisterEvent("CHAT_MSG_SYSTEM")
    frame.rollButton:Enable()
end

local function UpdateRollButton()
    frame.rollButton:SetText("Roll (" .. FormatModifier(ns.GetPlayerModifier()) .. ")")
end

local function OnRollResult(text)
    if not pending then return end
    if issecretvalue(text) then
        ns.Debug("CHAT_MSG_SYSTEM text is secret")
        return
    end

    local name, roll, low, high = text:match(rollPattern)
    if not name or tonumber(low) ~= ROLL_MIN or tonumber(high) ~= ROLL_MAX then return end

    if name ~= ns.GetPlayerName() then return end

    local modifier = pending.modifier
    ns.Print(format("%s rolled %d %s %s = %s for %s", name, roll,
        modifier >= 0 and "+" or "-", math.abs(modifier), tonumber(roll) + modifier, frame.link))
    frame:Hide()
end

local function StartRoll()
    if pending then return end
    local current = { modifier = ns.GetPlayerModifier() }
    pending = current
    frame.rollButton:Disable()
    frame.events:RegisterEvent("CHAT_MSG_SYSTEM")
    RandomRoll(ROLL_MIN, ROLL_MAX)

    C_Timer.After(ROLL_TIMEOUT, function()
        if pending == current then
            ns.Debug("Timed out waiting for the roll result")
            ClearPending()
            ns.Print("Could not read your roll result.")
        end
    end)
end

local function CreateRollFrame()
    frame = CreateFrame("Frame", "RolloverRollFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(320, 150)
    frame:SetPoint("CENTER", 0, 150)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    local title = "Rollover | Roll for item"
    if frame.SetTitle then
        frame:SetTitle(title)
    else
        frame.TitleText:SetText(title)
    end

    local icon = CreateFrame("Button", nil, frame)
    icon:SetSize(44, 44)
    icon:SetPoint("TOPLEFT", 16, -38)
    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetAllPoints()
    icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    icon:SetScript("OnEnter", function(self)
        if frame.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(frame.link)
            GameTooltip:Show()
        end
    end)
    icon:SetScript("OnLeave", GameTooltip_Hide)
    frame.icon = icon

    frame.nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.nameText:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    frame.nameText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    frame.nameText:SetJustifyH("LEFT")

    local pass = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    pass:SetSize(110, 26)
    pass:SetPoint("BOTTOMLEFT", 24, 16)
    pass:SetText("Pass")
    pass:SetScript("OnClick", function() frame:Hide() end)

    local roll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    roll:SetSize(130, 26)
    roll:SetPoint("BOTTOMRIGHT", -24, 16)
    roll:SetScript("OnClick", StartRoll)
    frame.rollButton = roll

    frame.events = CreateFrame("Frame", nil, frame)
    frame.events:SetScript("OnEvent", function(_, _, text) OnRollResult(text) end)

    frame:SetScript("OnHide", ClearPending)

    tinsert(UISpecialFrames, "RolloverRollFrame")
    frame:Hide()
end

function ns.ShowRollFrame(link)
    if not frame then CreateRollFrame() end
    ClearPending()

    frame.link = link
    frame.nameText:SetText(link)
    frame.icon.texture:SetTexture(select(5, C_Item.GetItemInfoInstant(link)))
    UpdateRollButton()
    frame:Show()
end

-- Opens the popup with a test item.
function ns.DebugRoll()
    ns.ShowRollFrame("|cffffffff|Hitem:6948::::::::::::::|h[Hearthstone]|h|r")
end
