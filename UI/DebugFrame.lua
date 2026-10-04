local addonName, ns = ...

local frame
local log = {}
local MAX_LINES = 200

function ns.Debug(msg)
    log[#log + 1] = date("%H:%M:%S") .. " " .. msg
    if #log > MAX_LINES then
        table.remove(log, 1)
    end
end

function ns.ToggleDebugFrame()
    if not frame then
        frame = ns.CreateTextDialog("RolloverDebugFrame", "Rollover | Debug log (Ctrl+C to copy)")
        frame:SetScript("OnShow", function()
            -- Escape pipes so link/color codes show as plain text.
            local text = table.concat(log, "\n"):gsub("|", "||")
            frame.edit:SetText(text ~= "" and text or "(no debug messages yet)")
            frame.edit:SetFocus()
            frame.edit:HighlightText()
        end)
    end
    frame:SetShown(not frame:IsShown())
end
