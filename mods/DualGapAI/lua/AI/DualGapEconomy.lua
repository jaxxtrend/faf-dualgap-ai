-- Mex upgrades, ACU RAS (ECO) and ECO's late strategic projects.
-- Factory upgrades live in DualGapFactories.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')

local Alive = Utils.Alive

local CatMex = categories.MASSEXTRACTION * categories.STRUCTURE
local CatEngineer = categories.ENGINEER - categories.COMMAND - categories.SUBCOMMANDER

local function UpgradeTarget(u)
    local to = u:GetBlueprint().General.UpgradesTo
    if to and to ~= '' then return to end
    return nil
end

local function MassIncome(brain)
    return brain:GetEconomyIncome('MASS') * 10
end

---------------------------------------------------------------------------
-- Mex upgrades. Nothing happens until the ACU reaches its UpgradeMexes step.
-- Then own mexes go to ctx.mexUpgradeTech strictly one at a time (closest to
-- base first). Once all are there, T2 -> T3 runs in parallel (capped).
---------------------------------------------------------------------------
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

local function UpgradeStep(brain, ctx)
    if not ctx.mexUpgradesAllowed then return end
    local belowTarget, upgrading = MexStats(brain, ctx)

    if table.getn(belowTarget) > 0 then
        if upgrading == 0 then
            local u = Closest(belowTarget, ctx.startPos)
            IssueUpgrade({ u }, UpgradeTarget(u))
        end
        return
    end

    -- Sequential phase finished: T2 -> T3 once the T2 phase clock is running.
    if not ctx.t2Time or brain:GetEconomyStoredRatio('ENERGY') < 0.5 then return end
    local cap = Config.MaxConcurrentUpgrades
    if ctx.role == 'ECO' then cap = cap + 2 end
    if upgrading >= cap then return end
    local t2 = {}
    for _, u in ipairs(brain:GetListOfUnits(CatMex * categories.TECH2, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 and not u:IsUnitState('Upgrading') and UpgradeTarget(u) then
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
-- ECO strategic phase: >= Config.EcoStrategicMassIncome mass/s, then up to
-- Config.EcoStrategicShare of the engineers build T3 artillery / nuke /
-- faction experimental in rotation. Idle engineers are offered to the crew
-- by DualGapEngineers through TryRecruit.
---------------------------------------------------------------------------
local StrategicRotation = { 'StratArtyT3', 'NukeSilo', 'StrategicT4' }

function TryRecruit(brain, ctx, u)
    local s = ctx.strategic
    if not s then return false end
    s.crew = Utils.FilterAlive(s.crew)
    local total = Utils.Count(brain:GetListOfUnits(CatEngineer, false))
    if Utils.Count(s.crew) >= math.floor(total * Config.EcoStrategicShare) then return false end
    u.DualGapAssigned = true
    table.insert(s.crew, u)
    return true
end

local function StrategicStep(brain, ctx)
    if not ctx.strategic then
        if MassIncome(brain) < Config.EcoStrategicMassIncome then return end
        ctx.strategic = { project = 0, crew = {} }
        Utils.Log(brain, 'entering strategic phase')
    end
    local s = ctx.strategic
    s.crew = Utils.FilterAlive(s.crew)
    if Utils.Count(s.crew) == 0 then return end

    if not (Alive(s.lead) and not s.lead:IsIdleState()) then
        s.lead = nil
        for _ = 1, table.getn(StrategicRotation) do
            s.project = s.project + 1
            if s.project > table.getn(StrategicRotation) then s.project = 1 end
            local id = Utils.FactionId(brain, StrategicRotation[s.project])
            for _, u in ipairs(s.crew) do
                if id and u:CanBuild(id) then
                    -- Behind the base, away from the enemy.
                    local dir = (ctx.side == 'LEFT') and -1 or 1
                    local site = { ctx.startPos[1] + dir * 25, ctx.startPos[2], ctx.startPos[3] }
                    if Utils.BuildNear(brain, u, id, site, 60) then
                        s.lead = u
                        Utils.Log(brain, 'strategic project ' .. id)
                    end
                    break
                end
            end
            if s.lead then break end
        end
    end

    if s.lead then
        for _, u in ipairs(s.crew) do
            if u ~= s.lead and u:IsIdleState() then IssueGuard({ u }, s.lead) end
        end
    end
end

---------------------------------------------------------------------------
function Start(brain, ctx)
    ForkThread(Utils.RunLoop, 'MexUpgrades', brain, ctx, 5, UpgradeStep)
    if ctx.role == 'ECO' then
        ForkThread(Utils.RunLoop, 'Strategic', brain, ctx, 5, StrategicStep)
    end
end
