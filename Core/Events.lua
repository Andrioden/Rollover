local addonName, ns = ...

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        self:UnregisterEvent(event)
        ns.InitDB()
        self:RegisterEvent("GUILD_ROSTER_UPDATE")
    elseif event == "GUILD_ROSTER_UPDATE" then
        if ns.RefreshRoster then
            ns.RefreshRoster()
        end
    end
end)

-- Uncomment to reopen the window after /reload to speed up debugging.
-- local f = CreateFrame("Frame")
-- f:RegisterEvent("PLAYER_ENTERING_WORLD")
-- f:SetScript("OnEvent", function(self, event, isLogin, isReload)
--     self:UnregisterEvent(event)
--     if isReload then
--         ns.ToggleMainFrame()
--     end
-- end)
