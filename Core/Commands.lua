local addonName, ns = ...

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
