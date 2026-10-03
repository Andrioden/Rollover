local addonName, ns = ...

local frame

local NAME_WIDTH, CLASS_WIDTH, RANK_WIDTH, MOD_WIDTH = 150, 90, 110, 60
local PUBLISHER_SIZE, PUBLISHER_GAP = 16, 2
-- Gap between the name column and the class column; the publisher button sits inside it.
local CLASS_OFFSET = PUBLISHER_GAP * 2 + PUBLISHER_SIZE
local ROW_HEIGHT = 22
-- Row content is 448 wide (+44 for margins and scrollbar); the defaults keep a little slack.
local FRAME_WIDTH, FRAME_HEIGHT = 520, 400
local MIN_WIDTH, MIN_HEIGHT = 500, 250
local MAX_WIDTH, MAX_HEIGHT = 900, 1500

local sortKey, sortAscending = "rank", true
local headers = {}

local function InitRow(row, data)
    if not row.nameText then
        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.nameText:SetPoint("LEFT", 4, 0)
        row.nameText:SetWidth(NAME_WIDTH)
        row.nameText:SetJustifyH("LEFT")

        -- Crown toggle: bright for the current publisher, dim for everyone else.
        local publisher = CreateFrame("Button", nil, row)
        publisher:SetSize(PUBLISHER_SIZE, PUBLISHER_SIZE)
        publisher:SetPoint("LEFT", row.nameText, "RIGHT", PUBLISHER_GAP, 0)
        publisher.icon = publisher:CreateTexture(nil, "ARTWORK")
        publisher.icon:SetAllPoints()
        publisher.icon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
        publisher:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        publisher:SetScript("OnClick", function() ns.SelectPublisher(row.key) end)
        publisher:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(row.isPublisher and ns.L.CURRENT_PUBLISHER or ns.L.SET_PUBLISHER)
            GameTooltip:Show()
        end)
        publisher:SetScript("OnLeave", GameTooltip_Hide)
        row.publisherButton = publisher

        row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.classText:SetPoint("LEFT", row.nameText, "RIGHT", CLASS_OFFSET, 0)
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
    row.isPublisher = ns.db.sync.publisher == data.name
    row.publisherButton.icon:SetDesaturated(not row.isPublisher)
    row.publisherButton.icon:SetAlpha(row.isPublisher and 1 or 0.35)
    row.publisherButton:SetEnabled(not ns.IsSyncPending())
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
end

local function ShowTools(button)
    MenuUtil.CreateContextMenu(button, function(_, root)
        if ns.IsSyncPending() then
            root:CreateButton(ns.L.CANCEL_SYNC, ns.CancelSync)
        else
            root:CreateButton(ns.L.SYNC_FROM_PUBLISHER, ns.RequestSync)
        end
        root:CreateDivider()
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

    -- Roster table: header row, then a scrolling list.
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -62)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -62)
    header:SetHeight(18)
    local nameHeader = CreateHeader(header, "name", "Player", NAME_WIDTH, "LEFT")
    nameHeader:SetPoint("LEFT", 4, 0)
    local classHeader = CreateHeader(header, "class", "Class", CLASS_WIDTH, "LEFT")
    classHeader:SetPoint("LEFT", nameHeader, "RIGHT", CLASS_OFFSET, 0)
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
