local addonName, ns = ...

ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"

function ns.Print(msg)
    print("|cff33ccffRollover:|r " .. msg)
end

SLASH_ROLLOVER1 = "/rollover"
SlashCmdList.ROLLOVER = function(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        ns.ToggleMainFrame()
        return
    end

    local command = msg:lower()
    if command == "debug" then
        ns.ToggleDebugFrame()
        return
    elseif command == "debug roll" then
        ns.DebugRoll()
        return
    end

    -- Midnight-style links use color names like |cnIQ1:, so don't assume hex colors.
    local link = msg:match("|c[^|]*|Hitem:.-|h%[.-%]|h|r") or msg:match("|Hitem:.-|h%[.-%]|h")
    if link then
        ns.ShowRollFrame(link)
    else
        ns.Print("Usage: /rollover [item-link]")
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        self:UnregisterEvent(event)
        ns.InitDB()
        self:RegisterEvent("PLAYER_LOGIN")
        self:RegisterEvent("GUILD_ROSTER_UPDATE")
    elseif event == "PLAYER_LOGIN" then
        ns.RequestGuildRoster()
    elseif event == "GUILD_ROSTER_UPDATE" then
        if ns.TryImportGuildRoster() and ns.RefreshRoster then
            ns.RefreshRoster()
        end
    end
end)

-- Uncomment to reopen the window after /reload to speed up debugging.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(self, event, isLogin, isReload)
    self:UnregisterEvent(event)
    if isReload then
        ns.ToggleMainFrame()
    end
end)