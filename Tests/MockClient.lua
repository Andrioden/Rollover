local MockClient = {}

local function copy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = type(value) == "table" and copy(value) or value
    end
    return result
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
        env.strtrim = function(text) return text:match("^%s*(.-)%s*$") end
        env.date = function() return "2026-10-04 12:00:00" end
        env.GetTime = function() return clock end
        env.GetServerTime = function() return 1800000000 + math.floor(clock) end
        env.GetUnitName = function() return name end
        env.Ambiguate = function(value) return value:gsub("%-.*$", "") end
        env.IsInGuild = function() return c.guild ~= nil end
        env.GetGuildInfo = function() return c.guild, nil, nil, "Realm" end
        env.GetNormalizedRealmName = function() return "Realm" end
        env.GetNumGuildMembers = function() return #c.roster end
        c.roster = { "Publisher", "Follower", "ZeroMember", "ThirdMember" }
        env.GetGuildRosterInfo = function(index)
            return c.roster[index], "Member", index, nil, nil, nil, nil, nil, nil, nil, "MAGE"
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
                assert(#message <= 255 and channel == "WHISPER")
                if c.result ~= 0 then return c.result end
                delivered[#delivered + 1] = { sender = name, target = target, text = message, time = clock }
                env.C_Timer.After(0.01, function()
                    if clients[target] then clients[target].ns.OnSyncMessage(prefix, message, channel, name) end
                end)
                return 0
            end,
        }
        -- WoW owns JSON parsing; mock its success/error results to test our boundary validation.
        env.C_EncodingUtil = {
            DeserializeJSON = function(text)
                if text == '{"Publisher":7,"ZeroMember":0}' then
                    return { Publisher = 7, ZeroMember = 0 }
                elseif text == '{"bad|name":7}' then return { ["bad|name"] = 7 }
                elseif text == '{"":7}' then return { [""] = 7 }
                elseif text == '{"Andriod En":220}' then return { ["Andriod En"] = 220 }
                elseif text == '{"Publisher":"bad"}' then return { Publisher = "bad" }
                elseif text == "{}" then return {} end
                error("JSON parse error")
            end,
            SerializeJSON = function(state)
                local rows = {}
                for key, value in pairs(state) do rows[#rows + 1] = '"' .. key .. '":' .. tostring(value) end
                table.sort(rows)
                return "{" .. table.concat(rows, ",") .. "}"
            end,
        }
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
        function methods:HasFocus() return self.focused end
        function methods:SetFocus() self.focused = true end
        function methods:ClearFocus() self.focused = false end
        function methods:CreateFontString() local fontString = frame(); fontString.owner = self; return fontString end
        function methods:GetFontString() return self end
        function methods:SetDataProvider(data) self.data = data end
        function methods:SetTitle(title) self.title = title end
        function methods:SetNormalTexture(path) self.normalTexture = path end
        function methods:GetPushedTexture() return frame() end
        function methods:SetPoint(point, ...) self.point, self.pointArgs = point, { ... } end
        function methods:CreateTexture() return frame() end
        function methods:SetDesaturated(value) self.desaturated = value end
        function methods:SetAlpha(value) self.alpha = value end
        function methods:SetSize(width, height) self.width, self.height = width, height end
        function methods:SetResizeBounds(minWidth) self.minWidth = minWidth end
        function methods:SetVerticalScroll(value) self.verticalScroll = value end
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
        c.load("Modules\\GuildSync.lua")
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
    local function count(c, text)
        local total = 0
        for _, line in ipairs(c.prints) do if line:find(text, 1, true) then total = total + 1 end end
        return total
    end

    return {
        advance = advance,
        client = client,
        count = count,
        delivered = delivered,
        last = last,
        printedSince = printedSince,
        secret = secret,
    }
end

return MockClient
