-- Mex upgrades and ACU RAS (ECO).
-- Factory upgrades live in DualGapFactories.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

local Alive = Utils.Alive

local CatMex = categories.MASSEXTRACTION * categories.STRUCTURE

local function UpgradeTarget(u)
    local to = u:GetBlueprint().General.UpgradesTo
    if to and to ~= '' then return to end
    return nil
end

---------------------------------------------------------------------------
-- Mex upgrades. Nothing happens until the ACU reaches its UpgradeMexes step.
-- Then own mexes go to ctx.mexUpgradeTech strictly one at a time (closest to
-- base first). Once all are there, T2 -> T3 runs in parallel (capped), but
-- only for mexes with all their mass storages built (StorageSpots empty):
-- adjacent storages raise a mex's output, so they come first.
---------------------------------------------------------------------------

-- Free buildable storage spots touching the mex (up to four, one per side).
-- Spots taken by anything else count as done.
function StorageSpots(brain, mex)
    local id = Utils.FactionId(brain, 'MassStorage')
    if not id then return {} end
    local p = mex:GetPosition()
    local off = (Utils.SizeOfBp(mex:GetBlueprint()) + Utils.FootprintOf(id)) / 2
    local out = {}
    for _, d in ipairs({ { off, 0 }, { -off, 0 }, { 0, off }, { 0, -off } }) do
        local s = { p[1] + d[1], 0, p[3] + d[2] }
        s[2] = GetSurfaceHeight(s[1], s[3])
        if brain:CanBuildStructureAt(id, s) then table.insert(out, s) end
    end
    return out
end
local function MexStats(brain, ctx)
    local belowTarget, upgrading = {}, 0
    for _, u in ipairs(brain:GetListOfUnits(CatMex, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            if u:IsUnitState('Upgrading') then
                upgrading = upgrading + 1
            elseif Utils.TechOf(u) < (ctx.mexUpgradeTech or 2) and UpgradeTarget(u) then
                table.insert(belowTarget, u)
            end
        end
    end
    return belowTarget, upgrading
end

local function Closest(list, pos)
    local best, bestD
    for _, u in ipairs(list) do
        local d = Utils.Dist2D(u:GetPosition(), pos)
        if not bestD or d < bestD then best, bestD = u, d end
    end
    return best
end

-- Exposed for tests: may T2 -> T3 mex upgrades run? baseBelowT2: base
-- mexes still below T2.
function T3PhaseOpen(baseBelowT2, t2Started)
    return t2Started and baseBelowT2 == 0
end

local function UpgradeStep(brain, ctx)
    if not ctx.mexUpgradesAllowed then return end
    local belowTarget, upgrading = MexStats(brain, ctx)

    if table.getn(belowTarget) > 0 then
        -- No new upgrade into an empty energy store (it stalls everything);
        -- one at a time, two with mass piling up.
        local most = Utils.MassBanked(brain) and 2 or 1
        if upgrading < most and brain:GetEconomyStoredRatio('ENERGY') >= 0.2 then
            local u = Closest(belowTarget, ctx.startPos)
            IssueUpgrade({ u }, UpgradeTarget(u))
            upgrading = upgrading + 1
        end
    end

    -- T2 -> T3 once the T2 phase clock is running and every base mex is T2
    -- (as a player does it: the base mexes go T2, get their storages, then
    -- T3). Mexes out of the base - contested ones at the mid, rebuilt as T1
    -- again and again - don't hold it back.
    local baseBelow = 0
    for _, u in ipairs(belowTarget) do
        if Utils.Dist2D(u:GetPosition(), ctx.startPos) <= Config.BaseRadius then baseBelow = baseBelow + 1 end
    end
    if not T3PhaseOpen(baseBelow, ctx.t2Time ~= nil) then return end
    if brain:GetEconomyStoredRatio('ENERGY') < 0.5 then return end
    local cap = Config.MaxConcurrentUpgrades
    if ctx.role == 'ECO' then cap = cap + 2 end
    if upgrading >= cap then return end
    local t2 = {}
    for _, u in ipairs(brain:GetListOfUnits(CatMex * categories.TECH2, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 and not u:IsUnitState('Upgrading') and UpgradeTarget(u)
            and table.getn(StorageSpots(brain, u)) == 0 then
            table.insert(t2, u)
        end
    end
    local u = Closest(t2, ctx.startPos)
    if u then IssueUpgrade({ u }, UpgradeTarget(u)) end
end

---------------------------------------------------------------------------
-- ACU Resource Allocation System (ECO). Called by DualGapEngineers when the
-- ECO ACU is idle in base-builder mode; returns true if it gave an order.
---------------------------------------------------------------------------
local RASChain = { 'ResourceAllocation', 'ResourceAllocationAdvanced' }

local function HasEnh(acu, name)
    if acu.HasEnhancement then return acu:HasEnhancement(name) end
    local list = SimUnitEnhancements and SimUnitEnhancements[acu.EntityId]
    if list then
        for _, v in pairs(list) do if v == name then return true end end
    end
    return false
end

function TryRAS(brain, ctx, acu)
    if ctx.rasDone then return false end
    if brain:GetEconomyStoredRatio('ENERGY') < 0.3 then return false end

    local enh = acu:GetBlueprint().Enhancements or {}
    -- An upgrade replaces its prerequisite in the same slot, so walk the chain
    -- from the top: once a later step is installed, earlier ones are done too.
    for i = table.getn(RASChain), 1, -1 do
        if enh[RASChain[i]] and HasEnh(acu, RASChain[i]) then
            if i == table.getn(RASChain) or not enh[RASChain[i + 1]] then
                ctx.rasDone = true
                return false
            end
            break
        end
    end
    for _, name in ipairs(RASChain) do
        local def = enh[name]
        if def and not HasEnh(acu, name) then
            local pre = def.Prerequisite
            local pick = name
            if pre and not HasEnh(acu, pre) then pick = pre end
            Utils.Log(brain, 'ACU enhancement ' .. pick)
            IssueScript({ acu }, { TaskName = 'EnhanceTask', Enhancement = pick })
            return true
        end
    end
    ctx.rasDone = true
    return false
end

---------------------------------------------------------------------------
-- ECO's strategic phase and game ender live in DualGapProjects.
function Start(brain, ctx)
    ForkThread(Utils.RunLoop, 'MexUpgrades', brain, ctx, 5, UpgradeStep)
end
