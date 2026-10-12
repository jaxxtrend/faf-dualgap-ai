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
local lastTeamPing = {}
local lastTeamChat = {}

-- Some calls get old fast when repeated every minute.
local LongCooldown = { wall = 240, fleet = 120, wave = 120, distress = 120 }

-- Only these put a marker on the map (something the team must look at):
-- an enemy game ender / experimental / Yolona spotted, a base or the wall
-- under attack, a hidden ACU found or in danger, an air T4 at a base.
-- Everything else (plans, orders, "moving out") is a team chat line only.
local PingKeys = { ender = true, t4 = true, yolona = true, distress = true, wall = true,
    subacu = true, acufleet = true, refuge = true, lostacu = true }

-- Exposed for tests: the key's prefix ('distress:ARMY_3' -> 'distress').
function KeyPrefix(key)
    return (string.gsub(key, ':.*$', ''))
end

local function Fresh(side, key)
    local now = GetGameTimeSeconds()
    local k = tostring(side) .. ':' .. key
    local cooldown = LongCooldown[KeyPrefix(key)] or Config.PingCooldown
    if lastSent[k] and now - lastSent[k] < cooldown then return false end
    lastSent[k] = now
    return true
end

-- Exposed for tests: may a team send this now? A map ping at most every
-- Config.TeamPingGap seconds per team (the important ones every
-- TeamAlertGap), a plain chat line every Config.TeamChatGap.
function TeamGapOk(lastAt, now, isPing, important)
    if not lastAt then return true end
    local gap = isPing and (important and Config.TeamAlertGap or Config.TeamPingGap) or Config.TeamChatGap
    return now - lastAt >= gap
end

-- pingType: 'alert' | 'attack' | 'move' (nil = chat only).
function Say(brain, side, key, text, pos, pingType)
    if not brain or Utils.BrainDefeated(brain) then return false end
    local now = GetGameTimeSeconds()
    local prefix = KeyPrefix(key)
    local important = PingKeys[prefix] == true
    -- Map markers only for what matters; the rest is chat.
    if not important then pos, pingType = nil, nil end
    local isPing = pos ~= nil and pingType ~= nil
    local s = tostring(side)
    local last = isPing and lastTeamPing[s] or lastTeamChat[s]
    if not TeamGapOk(last, now, isPing, important) then return false end
    if not Fresh(side, key) then return false end
    if isPing then lastTeamPing[s] = now else lastTeamChat[s] = now end
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

-- Exposed for tests: "8 Brick, 2 Monkeylord, 3 others" from a list of
-- names, the most numerous first (at most `top` kinds).
function DescribeNames(names, top)
    local count, order = {}, {}
    for _, n in ipairs(names) do
        if not count[n] then count[n] = 0; table.insert(order, n) end
        count[n] = count[n] + 1
    end
    table.sort(order, function(a, b) return count[a] > count[b] end)
    local parts, rest = {}, 0
    for i, n in ipairs(order) do
        if i <= top then table.insert(parts, count[n] .. ' ' .. n) else rest = rest + count[n] end
    end
    if rest > 0 then table.insert(parts, rest .. ' others') end
    return table.concat(parts, ', ')
end

-- What a group of (seen) enemy units is, for a callout.
function Describe(units)
    local names = {}
    for _, u in ipairs(units) do
        if not u.Dead then table.insert(names, UnitName(u)) end
    end
    return DescribeNames(names, 3)
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
