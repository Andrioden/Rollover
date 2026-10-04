local addonName, ns = ...

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        self:UnregisterEvent(event)
        ns.InitDB()
        ns.InitGuildSync()
        self:RegisterEvent("CHAT_MSG_ADDON")
        self:RegisterEvent("PLAYER_GUILD_UPDATE")
        self:RegisterEvent("GUILD_ROSTER_UPDATE")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
    elseif event == "CHAT_MSG_ADDON" then
        ns.OnSyncMessage(...)
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.OnPlayerEnteringWorld(...)
    elseif event == "GUILD_ROSTER_UPDATE" then
        ns.OnGuildRosterUpdate()
        ns.RefreshRoster()
    elseif event == "PLAYER_GUILD_UPDATE" then
        ns.OnSyncContextChanged()
        ns.RefreshRoster()
    end
end)
