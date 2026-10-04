local MockClient = {}

local function copy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = type(value) == "table" and copy(value) or value
    end
    return result
end

-- Minimal JSON for the mocked C_EncodingUtil: objects, strings, numbers, true/false/null.
local function parseJSON(text)
    local pos = 1
    local function skip() pos = text:find("%S", pos) or #text + 1 end
    local value
    local function string_()
        local close = text:find('"', pos + 1, true)
        if text:sub(pos, pos) ~= '"' or not close then error("JSON parse error") end
        local result = text:sub(pos + 1, close - 1)
        pos = close + 1
        return result
    end
    function value()
        skip()
        local char = text:sub(pos, pos)
        if char == "{" then
            local result = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == "}" then pos = pos + 1; return result end
            while true do
                skip()
                local key = string_()
                skip()
                if text:sub(pos, pos) ~= ":" then error("JSON parse error") end
                pos = pos + 1
                result[key] = value()
                skip()
                local separator = text:sub(pos, pos)
                pos = pos + 1
                if separator == "}" then return result end
                if separator ~= "," then error("JSON parse error") end
            end
        elseif char == '"' then
            return string_()
        end
        local literal = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if literal and #literal > 0 then pos = pos + #literal; return tonumber(literal) end
        error("JSON parse error")
    end
    local result = value()
    skip()
    if pos <= #text then error("JSON parse error") end
    return result
end

local function serializeJSON(item)
    if type(item) ~= "table" then
        return type(item) == "string" and '"' .. item .. '"' or tostring(item)
    end
    local rows = {}
    for key, value in pairs(item) do rows[#rows + 1] = '"' .. key .. '":' .. serializeJSON(value) end
    table.sort(rows)
    return "{" .. table.concat(rows, ",") .. "}"
end

function MockClient.new(root)
    local clients, timers, clock, delivered = {}, {}, 0, {}
    local secret = {}

    local function advance(seconds)
        local limit = clock + seconds
        while true do
            table.sort(timers, function(a, b) return a.time < b.time end)
            local timer = timers[1]
            if not timer or timer.time > limit then break end
            table.remove(timers, 1)
            clock = timer.time
            if not timer.cancelled then timer.callback() end
        end
        clock = limit
    end

    local function client(name)
        local c = { name = name, ns = {}, guild = "Guild", prints = {}, frames = {}, result = 0 }
        clients[name] = c
        local env = setmetatable({}, { __index = _G })
        env._G = env
        c.env = env
        env.CopyTable = copy
        env.issecretvalue = function(value) return value == secret end
        env.date = function() return "2026-10-04 12:00:00" end
        env.GetTime = function() return clock end
        env.GetServerTime = function() return 1800000000 + math.floor(clock) end
        env.GetUnitName = function() return name end
        env.Ambiguate = function(value) return value:gsub("%-.*$", "") end
        env.IsInGuild = function() return c.guild ~= nil end
        env.GetNumGuildMembers = function() return #c.roster end
        c.roster = { "Master", "Follower", "ZeroMember", "ThirdMember" }
        c.online = {} -- [roster name] = true; members are offline unless a test says otherwise
        env.GetGuildRosterInfo = function(index)
            return c.roster[index], "Member", index, nil, nil, nil, nil, nil, c.online[c.roster[index]], nil, "MAGE"
        end
        env.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage" }
        env.RAID_CLASS_COLORS = {}
        env.print = function(message) c.prints[#c.prints + 1] = message end
        env.C_GuildInfo = { GuildRoster = function() c.rosterRequested = true end }
        env.C_Timer = {}
        env.C_Timer.NewTimer = function(delay, callback)
            local timer = { time = clock + delay, callback = callback }
            function timer:Cancel() self.cancelled = true end
            timers[#timers + 1] = timer
            return timer
        end
        env.C_Timer.After = env.C_Timer.NewTimer
        env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, AddOnMessageLockdown = 11 } }
        env.C_ChatInfo = {
            RegisterAddonMessagePrefix = function(prefix) assert(#prefix <= 16); return c.prefix ~= false end,
            SendAddonMessage = function(prefix, message, channel, target)
                assert(#message <= 255 and (channel == "WHISPER" or channel == "GUILD"))
                if c.result ~= 0 then return c.result end
                delivered[#delivered + 1] = { sender = name, target = target, text = message, channel = channel, time = clock }
                env.C_Timer.After(0.01, function()
                    if channel == "GUILD" then
                        -- Guild addon messages reach every online client, including the sender.
                        for _, other in pairs(clients) do
                            if other == c or c.online[other.name] then other.ns.OnSyncMessage(prefix, message, channel, name) end
                        end
                    elseif clients[target] then
                        clients[target].ns.OnSyncMessage(prefix, message, channel, name)
                    end
                end)
                return 0
            end,
        }
        -- WoW owns JSON parsing; the mock only needs to feed our boundary validation realistic data.
        env.C_EncodingUtil = { DeserializeJSON = parseJSON, SerializeJSON = serializeJSON }
        local methods = {}
        local function frame(frameName)
            local f = { scripts = {}, events = {}, shown = false }
            setmetatable(f, { __index = function(_, key)
                if methods[key] then return methods[key] end
                if key:match("^%u") then return function() end end
            end })
            c.frames[#c.frames + 1] = f
            if frameName then c.frames[frameName] = f end
            return f
        end
        function methods:SetScript(event, callback) self.scripts[event] = callback end
        function methods:RegisterEvent(event) self.events[event] = true end
        function methods:UnregisterEvent(event) self.events[event] = nil end
        function methods:IsShown() return self.shown end
        function methods:SetShown(shown)
            local changed = self.shown ~= shown
            self.shown = shown
            local callback = self.scripts[shown and "OnShow" or "OnHide"]
            if changed and callback then callback(self) end
        end
        function methods:Show() self:SetShown(true) end
        function methods:Hide() self:SetShown(false) end
        function methods:SetText(text) self.text = text end
        function methods:GetText() return self.text end
        function methods:SetEnabled(enabled) self.enabled = not not enabled end
        function methods:SetFocus() self.focused = true end
        function methods:ClearFocus() self.focused = false end
        function methods:CreateFontString() return frame() end
        function methods:GetFontString() return self end
        function methods:SetDataProvider(data) self.data = data end
        function methods:SetTitle(title) self.title = title end
        function methods:SetNormalTexture(path) self.normalTexture = path end
        function methods:GetPushedTexture() return frame() end
        function methods:CreateTexture() return frame() end
        function methods:SetDesaturated(value) self.desaturated = value end
        function methods:SetAlpha(value) self.alpha = value end
        env.CreateFrame = function(_, frameName) return frame(frameName) end
        env.UIParent, env.GameTooltip = frame(), frame()
        env.GameTooltip_Hide = function() end
        env.UISpecialFrames, env.SlashCmdList = {}, {}
        env.tinsert = table.insert
        env.ScrollBoxConstants = { RetainScrollPosition = 1 }
        env.CreateDataProvider = function(data) return data end
        env.CreateScrollBoxListLinearView = function()
            return { SetElementExtent = function() end, SetElementFactory = function(self, callback) self.factory = callback end }
        end
        env.ScrollUtil = { InitScrollBoxListWithScrollBar = function(_, _, view)
            view.factory(function(_, initializer) c.initRow = initializer end)
        end }
        env.ACCEPT, env.CANCEL, env.StaticPopupDialogs = "Accept", "Cancel", {}
        env.StaticPopup_Show = function(which) c.popup = which end
        env.MenuUtil = { CreateContextMenu = function(_, callback)
            local entries = {}
            local function menu()
                local m = {}
                function m:CreateButton(label, action)
                    local entry = menu()
                    entry.label, entry.action = label, action
                    entries[#entries + 1] = entry
                    return entry
                end
                function m:SetEnabled(value) self.enabled = value end
                function m:SetScrollMode() end
                function m:CreateTitle() end
                function m:CreateDivider() end
                return m
            end
            callback(nil, menu())
            c.menu = entries
        end }
        function c.load(path)
            local chunk
            if setfenv then
                chunk = assert(loadfile(root .. "\\" .. path))
                setfenv(chunk, env)
            else
                chunk = assert(loadfile(root .. "\\" .. path, "t", env))
            end
            chunk("Rollover", c.ns)
        end
        c.load("Locales\\enUS.lua")
        c.load("Core\\Utils.lua")
        c.load("Core\\DB.lua")
        c.load("Sync\\SyncCore.lua")
        c.load("Sync\\SyncMaster.lua")
        c.load("Sync\\SyncClient.lua")
        c.load("UI\\Window.lua")
        c.load("UI\\DebugFrame.lua")
        c.load("UI\\TextDialog.lua")
        c.load("UI\\ExportFrame.lua")
        c.load("UI\\ImportFrame.lua")
        c.load("UI\\MainFrame.lua")
        c.ns.version = "0.0.1"
        c.ns.InitDB()
        c.ns.InitGuildSync()
        return c
    end

    local function last(c) return c.prints[#c.prints] or "" end
    local function printedSince(c, mark) return table.concat(c.prints, "\n", mark + 1) end
    local function count(c, text, mark)
        local total = 0
        for i = (mark or 0) + 1, #c.prints do
            if c.prints[i]:find(text, 1, true) then total = total + 1 end
        end
        return total
    end

    -- Prints a header, then one PASS line per test; a failing test prints FAIL and stops the run.
    local function suite(title)
        print(title)
        return function(name, body)
            local ok, err = xpcall(body, debug.traceback)
            if not ok then
                print("  FAIL: " .. name)
                error(err, 0)
            end
            print("  PASS: " .. name)
        end
    end

    -- Starts a manual sync that always streams: updatedAt is cleared, so the request asks with age 0.
    local function requestSync(c)
        c.ns.db.sync.updatedAt = nil
        return c.ns.RequestSync()
    end

    -- Addon messages delivered from `name` whose type is `kind`, after delivered[mark].
    local function messagesFrom(name, kind, mark)
        local found = {}
        for i = (mark or 0) + 1, #delivered do
            local entry = delivered[i]
            if entry.sender == name and entry.text:find(kind .. "\t", 1, true) == 1 then found[#found + 1] = entry.text end
        end
        return found
    end

    local function backupCount(c)
        local total = 0
        for _ in pairs(c.ns.db.backups) do total = total + 1 end
        return total
    end

    -- Simulates a login/reload followed by the first roster update.
    local function login(c)
        c.ns.OnPlayerEnteringWorld(true, false)
        c.ns.OnGuildRosterUpdate()
    end

    return {
        advance = advance,
        backupCount = backupCount,
        login = login,
        messagesFrom = messagesFrom,
        client = client,
        clients = clients,
        count = count,
        delivered = delivered,
        last = last,
        printedSince = printedSince,
        requestSync = requestSync,
        secret = secret,
        suite = suite,
    }
end

return MockClient
