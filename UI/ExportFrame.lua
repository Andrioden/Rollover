local addonName, ns = ...

local frame

function ns.ShowExportFrame(text)
    if not frame then
        frame = ns.CreateTextDialog("RolloverExportFrame", ns.L.EXPORT_TITLE)
        -- Copy-only: typing restores the exported text.
        frame.edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(frame.text)
                self:HighlightText()
            end
        end)
    end
    frame.text = text
    frame.edit:SetText(text)
    frame.scroll:SetVerticalScroll(0)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end