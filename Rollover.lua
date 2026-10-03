local addonName, ns = ...

ns.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"

SLASH_ROLLOVER1 = "/rollover"
SlashCmdList.ROLLOVER = function()
    ns.ToggleMainFrame()
end