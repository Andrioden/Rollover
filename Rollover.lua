local addonName, ns = ...

ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"

SLASH_ROLLOVER1 = "/rollover"
SlashCmdList.ROLLOVER = function()
    ns.ToggleMainFrame()
end

-- Uncomment to reopen the window after /reload to speed up debugging.
-- local f = CreateFrame("Frame")
-- f:RegisterEvent("PLAYER_ENTERING_WORLD")
-- f:SetScript("OnEvent", function(self, event, isLogin, isReload)
--     self:UnregisterEvent(event)
--     if isReload then
--         ns.ToggleMainFrame()
--     end
-- end)