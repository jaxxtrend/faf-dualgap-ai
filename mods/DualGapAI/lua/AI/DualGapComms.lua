-- Team chat and map pings, the way human players call out what they see:
-- "nuke spotted", "enemy T4", "attacking upper mid", "under attack".
--
-- Pings go through FAF's own AI helper (sorianutilities.AISendPing ->
-- simping.SpawnPing), chat through SyncAIChat to the 'allies' group, so
-- allied humans see them as ordinary pings and team chat lines.
-- Every alert has a key; the same key is repeated at most once per
-- Config.PingCooldown seconds per team.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

local lastSent = {}

local function Fresh(side, key)
    local now = GetGameTimeSeconds()
    local k = tostring(side) .. ':' .. key
    if lastSent[k] and now - lastSent[k] < Config.PingCooldown then return false end
    lastSent[k] = now
    return true
end

-- pingType: 'alert' | 'attack' | 'move' (nil = chat only).
function Say(brain, side, key, text, pos, pingType)
    if not brain or Utils.BrainDefeated(brain) or not Fresh(side, key) then return false end
    if pos and pingType then
        local ok, err = pcall(function()
            import('/lua/ai/sorianutilities.lua').AISendPing({ pos[1], pos[2], pos[3] }, pingType, brain:GetArmyIndex())
        end)
        if not ok then WARN('DualGap ping: ' .. tostring(err)) end
    end
    if text then
        local ok, err = pcall(function()
            import('/lua/simsyncutils.lua').SyncAIChat({ group = 'allies', text = text, sender = brain.Nickname })
        end)
        if not ok then WARN('DualGap chat: ' .. tostring(err)) end
    end
    Utils.Log(brain, 'callout: ' .. tostring(text or key))
    return true
end

-- Short name of a unit for chat ("Mavor", "Monkeylord").
function UnitName(unit)
    local bp = unit:GetBlueprint()
    local name = bp.General and bp.General.UnitName
    if name and name ~= '' then
        -- Strip localisation tags like '<LOC uel0401_name>Fatboy'.
        local clean = string.gsub(name, '<[^>]*>', '')
        if clean ~= '' then return clean end
    end
    return (bp.Description and string.gsub(bp.Description, '<[^>]*>', '')) or tostring(bp.BlueprintId)
end
