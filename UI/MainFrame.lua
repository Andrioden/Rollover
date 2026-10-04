local addonName, ns = ...

local frame

local NAME_WIDTH, CLASS_WIDTH, RANK_WIDTH, MOD_WIDTH = 170, 90, 110, 60
local MASTER_SIZE, MASTER_GAP = 16, 2
local ROW_HEIGHT = 22
-- Row content (column widths plus gaps), then the left margin and the right margin with scrollbar.
local ROW_WIDTH = 4 + MASTER_SIZE + MASTER_GAP + NAME_WIDTH + MASTER_GAP + CLASS_WIDTH + 4 + RANK_WIDTH + 10 + MOD_WIDTH
local MIN_WIDTH, MIN_HEIGHT = 14 + ROW_WIDTH + 30, 250
local MAX_WIDTH, MAX_HEIGHT = 900, 1500

local sortKey, sortAscending = "rank", true
local headers = {}

local function InitRow(row, data)
    if not row.nameText then
        -- Master selection column.
        local master = CreateFrame("Button", nil, row)
        master:SetSize(MASTER_SIZE, MASTER_SIZE)
        master:SetPoint("LEFT", row, "LEFT", 4, 0)
        master.icon = master:CreateTexture(nil, "ARTWORK")
        master.icon:SetAllPoints()
        master.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
        master.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        master:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        master:SetScript("OnClick", function() ns.ToggleMaster(row.key) end)
        master:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(row.isMaster and ns.L.CLEAR_MASTER or ns.L.SET_AS_MASTER)
            GameTooltip:Show()
        end)
        master:SetScript("OnLeave", GameTooltip_Hide)
        row.masterButton = master

        -- Player name column.
        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.nameText:SetPoint("LEFT", master, "RIGHT", MASTER_GAP, 0)
        row.nameText:SetWidth(NAME_WIDTH)
        row.nameText:SetJustifyH("LEFT")

        -- Class column.
        row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.classText:SetPoint("LEFT", row.nameText, "RIGHT", MASTER_GAP, 0)
        row.classText:SetWidth(CLASS_WIDTH)
        row.classText:SetJustifyH("LEFT")

        -- Rank column.
        row.rankText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.rankText:SetPoint("LEFT", row.classText, "RIGHT", 4, 0)
        row.rankText:SetWidth(RANK_WIDTH)
        row.rankText:SetJustifyH("LEFT")

        -- Modifier column.
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

    local color = data.class and RAID_CLASS_COLORS[data.class]
    local shortName = Ambiguate(data.name, "short")

    row.key = data.name
    row.isMaster = ns.db.sync.master == data.name
    row.masterButton.icon:SetDesaturated(not row.isMaster)
    row.masterButton.icon:SetAlpha(row.isMaster and 1 or 0.35)
    row.masterButton:SetEnabled(not ns.IsSyncPending())
    row.nameText:SetText(color and color:WrapTextInColorCode(shortName) or shortName)
    row.classText:SetText(data.class and LOCALIZED_CLASS_NAMES_MALE[data.class] or "")
    row.rankText:SetText(data.rank or "")
    row.modEdit:SetText(tostring(data.modifier))
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
    if not frame or not frame:IsShown() then return end

    local list = ns.GetRosterList(sortKey, sortAscending)
    frame.scrollBox:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)

    if #list > 0 then
        frame.emptyText:SetText("")
    else
        frame.emptyText:SetText(IsInGuild() and ns.L.LOADING_ROSTER or ns.L.NOT_IN_GUILD)
    end
end

StaticPopupDialogs["ROLLOVER_RESET_DATA"] = {
    text = ns.L.RESET_CONFIRM,
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function() ns.ResetData() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function ShowTools(button)
    MenuUtil.CreateContextMenu(button, function(_, root)
        if ns.IsSyncPending() then
            root:CreateButton(ns.L.CANCEL_SYNC, ns.CancelSync)
        else
            root:CreateButton(ns.L.SYNC_FROM_MASTER, ns.RequestSync)
        end
        local setMaster = root:CreateButton(ns.L.SET_MASTER, function()
            ns.SelectMaster(ns.GetPlayerName())
        end)
        setMaster:SetEnabled(not ns.IsSyncPending() and not ns.IsMaster())
        root:CreateDivider()
        root:CreateButton(ns.L.BACKUP, function() ns.SaveBackup("manual") end)
        root:CreateButton(ns.L.EXPORT, ns.ExportModifiers)
        local import = root:CreateButton(ns.L.IMPORT, ns.ShowImportFrame)
        import:SetEnabled(ns.CanEditModifiers())
        local restore = root:CreateButton(ns.L.RESTORE)
        restore:SetEnabled(ns.CanEditModifiers())
        local keys = {}
        for key in pairs(ns.db.backups) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return a > b end)
        if #keys == 0 then
            restore:CreateTitle(ns.L.NO_BACKUPS)
        else
            restore:SetScrollMode(300)
            for _, key in ipairs(keys) do
                local label = key .. " (" .. ns.db.backups[key].name .. ")"
                restore:CreateButton(label, function() ns.RestoreBackup(key) end)
            end
        end
        root:CreateDivider()
        local reset = root:CreateButton(ns.L.RESET, function() StaticPopup_Show("ROLLOVER_RESET_DATA") end)
        reset:SetEnabled(not ns.IsSyncPending())
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
    frame = ns.CreateWindow("RolloverMainFrame", "Rollover " .. ns.version, 520, 400)
    frame:SetFrameStrata("HIGH")
    frame:SetResizable(true)
    frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)

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
    local nameHeader = CreateHeader(header, "name", "Name", NAME_WIDTH, "LEFT")
    nameHeader:SetPoint("LEFT", 4 + MASTER_SIZE + MASTER_GAP, 0)
    local classHeader = CreateHeader(header, "class", "Class", CLASS_WIDTH, "LEFT")
    classHeader:SetPoint("LEFT", nameHeader, "RIGHT", MASTER_GAP, 0)
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
end

function ns.ToggleMainFrame()
    if not frame then CreateMainFrame() end
    frame:SetShown(not frame:IsShown())
end
