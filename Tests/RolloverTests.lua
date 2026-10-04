-- Run all suites: lua Tests\RolloverTests.lua <addon directory>
-- Each suite can also be run on its own, e.g. lua Tests\SyncTests.lua <addon directory>
local root = arg[1] or "."
local suites = { "DBTests", "ImportExportTests", "SyncClientTests", "SyncMasterTests", "SyncTests", "SyncAutoTests", "MainFrameTests", "EventsTests" }
for _, name in ipairs(suites) do
    dofile(root .. "\\Tests\\" .. name .. ".lua")
end
print("PASS: all " .. #suites .. " suites")
