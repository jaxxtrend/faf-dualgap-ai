-- Upgrades (mex / factories), ACU RAS, and ECO's late strategic projects.
-- Done with direct engine orders instead of upgrade PlatoonFormBuilders so it
-- doesn't depend on platoon template names that vary between FAF versions.

local Config = import('/lua/AI/DualGapConfig.lua')
local Utils = import('/lua/AI/DualGapUtils.lua')

local Alive = Utils.Alive

local CatMex = categories.MASSEXTRACTION * categories.STRUCTURE
local CatEngineer = categories.ENGINEER - categories.COMMAND - categories.SUBCOMMANDER

local function UpgradeTarget(u)
    local to = u:GetBlueprint().General.UpgradesTo
    if to and to ~= '' then return to end
    return nil
end

local function ActiveUpgrades(brain)
    local n = 0
    for _, u in ipairs(brain:GetListOfUnits(CatMex + categories.FACTORY, false)) do
        if Alive(u) and u:IsUnitState('Upgrading') then n = n + 1 end
    end
    return n
end

local function MassIncome(brain)
    return brain:GetEconomyIncome('MASS') * 10
end

local function CanAfford(brain)
    return brain:GetEconomyStoredRatio('ENERGY') > 0.4
        and (brain:GetEconomyStoredRatio('MASS') > 0.15 or brain:GetEconomyTrend('MASS') > 0)
end

-- Upgrade the closest-to-base unit of `cat` that has an upgrade path.
local function UpgradeOne(brain, ctx, cat)
    local best, bestD
    for _, u in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 and u:IsIdleState()
            and not u:IsUnitState('Upgrading') and UpgradeTarget(u) then
            local d = Utils.Dist2D(u:GetPosition(), ctx.startPos)
            if not bestD or d < bestD then best, bestD = u, d end
        end
    end
    if best then
        IssueUpgrade({ best }, UpgradeTarget(best))
        return true
    end
    return false
end

-- Per role: which factory type gets upgraded, and when (seconds) to T2 / T3.
local FactoryPlan = {
    GROUND = { cat = categories.FACTORY * categories.LAND, t2 = 360, t3 = 900 },
    NAVAL  = { cat = categories.FACTORY * categories.NAVAL, t2 = 420, t3 = 900 },
    AIR    = { cat = categories.FACTORY * categories.AIR, t2 = 360, t3 = 840 },
    ECO    = { cat = categories.FACTORY * categories.LAND, t2 = 300, t3 = 720 },
}

local function UpgradeStep(brain, ctx)
    if not CanAfford(brain) then return end
    local cap = Config.MaxConcurrentUpgrades
    if ctx.role == 'ECO' then cap = cap + 2 end
    if ActiveUpgrades(brain) >= cap then return end

    local t = GetGameTimeSeconds()
    local plan = FactoryPlan[ctx.role] or FactoryPlan.GROUND
    -- At most one factory of each role-type is upgraded per tier window.
    if t > plan.t3 then
        if UpgradeOne(brain, ctx, plan.cat * categories.TECH2) then return end
    end
    if t > plan.t2 then
        local t2Plus = Utils.Count(brain:GetListOfUnits(plan.cat * (categories.TECH2 + categories.TECH3), false))
        if t2Plus < 2 and UpgradeOne(brain, ctx, plan.cat * categories.TECH1) then return end
    end

    -- Mexes: T1 first, then T2. ECO starts immediately; others after 4 min.
    if ctx.role == 'ECO' or t > 240 then
        if not UpgradeOne(brain, ctx, CatMex * categories.TECH1) then
            UpgradeOne(brain, ctx, CatMex * categories.TECH2)
        end
    end
end

---------------------------------------------------------------------------
-- ACU Resource Allocation System (ECO only)
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

local function RASStep(brain, ctx)
    if ctx.rasDone then return end
    local acu = Utils.Commander(brain)
    if not acu or not Utils.IsIdle(acu) then return end
    if GetGameTimeSeconds() < 90 or brain:GetEconomyStoredRatio('ENERGY') < 0.3 then return end

    local enh = acu:GetBlueprint().Enhancements or {}
    for _, name in ipairs(RASChain) do
        local def = enh[name]
        if def and not HasEnh(acu, name) then
            local pre = def.Prerequisite
            local pick = name
            if pre and not HasEnh(acu, pre) then pick = pre end
            Utils.Log(brain, 'ACU enhancement ' .. pick)
            IssueScript({ acu }, { TaskName = 'EnhanceTask', Enhancement = pick })
            return
        end
    end
    ctx.rasDone = true
end

---------------------------------------------------------------------------
-- ECO strategic phase: >= Config.EcoStrategicMassIncome mass/s, then ~80% of
-- engineers build T3 artillery / nuke / faction experimental in rotation.
---------------------------------------------------------------------------
local StrategicRotation = { 'StratArtyT3', 'NukeSilo', 'StrategicT4' }

local function DetachFromManager(brain, u)
    local bm = brain.BuilderManagers and brain.BuilderManagers.MAIN
    local em = bm and bm.EngineerManager
    if em and em.RemoveUnit then pcall(em.RemoveUnit, em, u) end
end

local function StrategicStep(brain, ctx)
    if MassIncome(brain) < Config.EcoStrategicMassIncome and not ctx.strategic then return end
    local s = ctx.strategic
    if not s then
        s = { project = 0, crew = {} }
        ctx.strategic = s
        Utils.Log(brain, 'entering strategic phase')
    end
    s.crew = Utils.FilterAlive(s.crew)

    -- Recruit up to the configured share of all engineers.
    local all = brain:GetListOfUnits(CatEngineer, false)
    local want = math.floor(Utils.Count(all) * Config.EcoStrategicShare)
    for _, u in ipairs(all) do
        if Utils.Count(s.crew) >= want then break end
        if Alive(u) and not u.DualGapAssigned and u:GetFractionComplete() >= 1 and u:IsIdleState() then
            u.DualGapAssigned = true
            DetachFromManager(brain, u)
            table.insert(s.crew, u)
        end
    end
    if Utils.Count(s.crew) == 0 then return end

    -- Lead engineer: alive and still building the current project?
    if not (Alive(s.lead) and not s.lead:IsIdleState()) then
        s.lead = nil
        -- Next project the crew can actually build.
        for _ = 1, table.getn(StrategicRotation) do
            s.project = s.project + 1
            if s.project > table.getn(StrategicRotation) then s.project = 1 end
            local id = Utils.FactionId(brain, StrategicRotation[s.project])
            for _, u in ipairs(s.crew) do
                if id and u:CanBuild(id) then
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

    -- Everyone else assists the lead.
    if s.lead then
        for _, u in ipairs(s.crew) do
            if u ~= s.lead and u:IsIdleState() then IssueGuard({ u }, s.lead) end
        end
    end
end

---------------------------------------------------------------------------
function Start(brain, ctx)
    ForkThread(Utils.RunLoop, 'Upgrades', brain, ctx, 10, UpgradeStep)
    if ctx.role == 'ECO' then
        ForkThread(Utils.RunLoop, 'RAS', brain, ctx, 5, RASStep)
        ForkThread(Utils.RunLoop, 'Strategic', brain, ctx, 5, StrategicStep)
    end
end
