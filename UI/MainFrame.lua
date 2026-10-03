local addonName, ns = ...

local frame

local NAME_WIDTH, CLASS_WIDTH, RANK_WIDTH, MOD_WIDTH = 150, 90, 110, 60
local ROW_HEIGHT = 22
local FRAME_WIDTH, FRAME_HEIGHT = 500, 400
local MIN_WIDTH, MIN_HEIGHT = 480, 250
local MAX_WIDTH, MAX_HEIGHT = 900, 1500

local sortKey, sortAscending = "rank", true
local headers = {}

local function InitRow(row, data)
    if not row.nameText then
        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.nameText:SetPoint("LEFT", 4, 0)
        row.nameText:SetWidth(NAME_WIDTH)
        row.nameText:SetJustifyH("LEFT")

        row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.classText:SetPoint("LEFT", row.nameText, "RIGHT", 4, 0)
        row.classText:SetWidth(CLASS_WIDTH)
        row.classText:SetJustifyH("LEFT")

        row.rankText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.rankText:SetPoint("LEFT", row.classText, "RIGHT", 4, 0)
        row.rankText:SetWidth(RANK_WIDTH)
        row.rankText:SetJustifyH("LEFT")

        local edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        edit:SetSize(MOD_WIDTH, 18)
        edit:SetPoint("LEFT", row.rankText, "RIGHT", 10, 0)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(32)
        edit:SetJustifyH("CENTER")
        edit:SetScript("OnEnterPressed", edit.ClearFocus)
        edit:SetScript("OnEscapePressed", edit.ClearFocus)
        edit:SetScript("OnEditFocusLost", function(self)
            local value = tonumber(self:GetText())
            ns.SetModifier(row.key, value)
            self:SetText(tostring(ns.GetModifier(row.key)))
            self:SetCursorPosition(0)
            self:HighlightText(0, 0)
        end)
        -- A recycled/resized edit box can keep a stale horizontal scroll and render blank.
        edit:SetScript("OnShow", function(self)
            self:SetCursorPosition(0)
        end)
        row.modEdit = edit
    end

    local member = data.member
    local color = member.class and RAID_CLASS_COLORS[member.class]
    local shortName = Ambiguate(data.name, "short")

    row.key = data.name
    row.nameText:SetText(color and color:WrapTextInColorCode(shortName) or shortName)
    row.classText:SetText(member.class and LOCALIZED_CLASS_NAMES_MALE[member.class] or "")
    row.rankText:SetText(member.rank or "")
    row.modEdit:SetText(tostring(member.modifier or 0))
    row.modEdit:SetCursorPosition(0)
    row.modEdit:SetEnabled(ns.CanEditModifiers())
end

local function UpdateHeaderLabels()
    for key, button in pairs(headers) do
        local label = button.label
        if key == sortKey then
            label = label .. (sortAscending and " ^" or " v")
        end
        button:SetText(label)
    end
end

function ns.RefreshRoster()
    if not frame or not frame:IsShown() or not ns.db then return end

    local list = ns.GetRosterList(sortKey, sortAscending)
    frame.scrollBox:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)

    if #list == 0 then
        frame.emptyText:SetText(IsInGuild() and ns.L.LOADING_ROSTER or ns.L.NOT_IN_GUILD)
    else
        frame.emptyText:SetText("")
    end
    ns.RefreshSyncControls()
end

function ns.RefreshSyncControls()
    if not frame or not frame:IsShown() or not ns.db then return end
    frame.syncStatus:SetText(ns.GetSyncStatus())
    if not frame.publisherEdit:HasFocus() then
        frame.publisherEdit:SetText(ns.db.sync.publisher or "")
        frame.publisherEdit:SetCursorPosition(0)
    end
    frame.syncButton:SetText(ns.IsSyncPending() and ns.L.CANCEL_SYNC or ns.L.SYNC)
    frame.syncButton:SetEnabled(ns.IsSyncPending() or (not ns.IsPublisher()
        and ns.db.sync.publisher ~= nil and IsInGuild()))
    frame.publisherButton:SetEnabled(not ns.IsSyncPending())
    frame.publisherEdit:SetEnabled(not ns.IsSyncPending())
end

local function ShowTools(button)
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateButton(ns.L.BACKUP, ns.SaveBackup)
        root:CreateButton(ns.L.EXPORT, ns.ExportModifiers)
        local import = root:CreateButton(ns.L.IMPORT, ns.ShowImportFrame)
        import:SetEnabled(not ns.IsSyncPending())
        local restore = root:CreateButton(ns.L.RESTORE)
        restore:SetEnabled(not ns.IsSyncPending())
        local keys = {}
        for key in pairs(ns.db.backups) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return a > b end)
        if #keys == 0 then
            restore:CreateTitle(ns.L.NO_BACKUPS)
        else
            restore:SetScrollMode(300)
            for _, key in ipairs(keys) do
                restore:CreateButton(key, function() ns.RestoreBackup(key) end)
            end
        end
        root:CreateDivider()
        local publish = root:CreateButton(ns.L.PUBLISH_SELF, function()
            ns.SelectPublisher(ns.GetPlayerName())
        end)
        publish:SetEnabled(not ns.IsSyncPending() and IsInGuild())
    end)
end

local function CreateHeader(parent, key, text, width, justify)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 18)
    button:SetNormalFontObject("GameFontNormal")
    button:SetHighlightFontObject("GameFontHighlight")
    button.label = text
    button:SetText(text)
    button:GetFontString():SetAllPoints()
    button:GetFontString():SetJustifyH(justify)
    button:SetScript("OnClick", function()
        if sortKey == key then
            sortAscending = not sortAscending
        else
            sortKey, sortAscending = key, true
        end
        UpdateHeaderLabels()
        ns.RefreshRoster()
    end)
    headers[key] = button
    return button
end

local function CreateMainFrame()
    frame = CreateFrame("Frame", "RolloverMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetResizable(true)
    frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
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

    local publisher = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    publisher:SetSize(180, 22)
    publisher:SetPoint("TOPLEFT", 20, -33)
    publisher:SetAutoFocus(false)
    publisher:SetMaxLetters(96)
    publisher:SetScript("OnEscapePressed", publisher.ClearFocus)
    publisher:SetScript("OnEnterPressed", function(self)
        if ns.SelectPublisher(self:GetText()) then self:ClearFocus() end
    end)
    publisher:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(ns.L.PUBLISHER_HINT)
        GameTooltip:Show()
    end)
    publisher:SetScript("OnLeave", GameTooltip_Hide)
    frame.publisherEdit = publisher

    local select = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    select:SetSize(60, 24)
    select:SetPoint("LEFT", publisher, "RIGHT", 8, 0)
    select:SetText(ns.L.SET_PUBLISHER)
    select:SetScript("OnClick", function()
        if ns.SelectPublisher(publisher:GetText()) then publisher:ClearFocus() end
    end)
    frame.publisherButton = select

    local sync = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    sync:SetSize(60, 24)
    sync:SetPoint("LEFT", select, "RIGHT", 6, 0)
    sync:SetText(ns.L.SYNC)
    sync:SetScript("OnClick", function()
        if ns.IsSyncPending() then ns.CancelSync() else ns.RequestSync() end
    end)
    frame.syncButton = sync

    local tools = CreateFrame("Button", nil, frame)
    tools:SetSize(24, 24)
    tools:SetPoint("TOPRIGHT", -14, -32)
    tools:SetNormalTexture("Interface\\Icons\\INV_Misc_Gear_01")
    tools:SetPushedTexture("Interface\\Icons\\INV_Misc_Gear_01")
    tools:GetPushedTexture():SetVertexColor(0.7, 0.7, 0.7)
    tools:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    tools:SetScript("OnClick", ShowTools)
    tools:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText(ns.L.TOOLS)
        GameTooltip:Show()
    end)
    tools:SetScript("OnLeave", GameTooltip_Hide)

    frame.syncStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.syncStatus:SetPoint("TOPLEFT", 14, -61)
    frame.syncStatus:SetPoint("TOPRIGHT", -30, -61)
    frame.syncStatus:SetHeight(34)
    frame.syncStatus:SetJustifyH("LEFT")

    -- Roster table: header row, then a scrolling list.
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -101)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -101)
    header:SetHeight(18)
    local nameHeader = CreateHeader(header, "name", "Player", NAME_WIDTH, "LEFT")
    nameHeader:SetPoint("LEFT", 4, 0)
    local classHeader = CreateHeader(header, "class", "Class", CLASS_WIDTH, "LEFT")
    classHeader:SetPoint("LEFT", nameHeader, "RIGHT", 4, 0)
    local rankHeader = CreateHeader(header, "rank", "Rank", RANK_WIDTH, "LEFT")
    rankHeader:SetPoint("LEFT", classHeader, "RIGHT", 4, 0)
    local modHeader = CreateHeader(header, "modifier", "Modifier", MOD_WIDTH + 20, "CENTER")
    modHeader:SetPoint("LEFT", rankHeader, "RIGHT", 0, 0)
    UpdateHeaderLabels()

    local scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    scrollBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 22)

    local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementFactory(function(factory)
        factory("Frame", InitRow)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    frame.scrollBox = scrollBox

    frame.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.emptyText:SetPoint("CENTER", scrollBox)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    frame:SetScript("OnShow", function()
        ns.RequestGuildRoster()
        ns.RefreshRoster()
    end)

    -- Lets Escape close the window.
    tinsert(UISpecialFrames, "RolloverMainFrame")
    frame:Hide()
end

function ns.ToggleMainFrame()
    if not frame then CreateMainFrame() end
    frame:SetShown(not frame:IsShown())
end
