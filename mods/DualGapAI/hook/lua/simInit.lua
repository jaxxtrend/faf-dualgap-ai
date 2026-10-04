-- DualGap AI: start the match recorder (DualGapStats) in every game that
-- has the mod enabled, with or without DualGap bots, so human players'
-- builds and movement are logged too. Appended to FAF's /lua/simInit.lua.
local DualGapOldBeginSession = BeginSession
function BeginSession()
    DualGapOldBeginSession()
    ForkThread(function()
        WaitSeconds(2)
        local ok, err = pcall(function()
            import('/mods/DualGapAI/lua/AI/DualGapStats.lua').StartRecorder()
        end)
        if not ok then WARN('DualGap recorder: ' .. tostring(err)) end
    end)
end
