-- Factories: the first factory runs BuildOrders.Factory; every other factory
-- (and the first one once its list is done) builds from BuildOrders.Production.
-- The stock FactoryManager only holds a never-true builder, so it stays idle.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')

local Alive = Utils.Alive
local TechOf = Utils.TechOf

local CatAllFactories = categories.FACTORY * categories.STRUCTURE

local function EngineersOfTech(brain, tech)
    local cat = categories.ENGINEER * categories['TECH' .. tech] - categories.COMMAND - categories.SUBCOMMANDER
    return Utils.Count(brain:GetListOfUnits(cat, false))
end

local function CountId(brain, id)
    return Utils.Count(brain:GetListOfUnits(categories[id], false))
end

local function Ready(f)
    return Alive(f) and f:GetFractionComplete() >= 1 and not f:IsUnitState('Upgrading')
end

-- The start-kind factory with the highest tech (follows HQ upgrades, which
-- replace the unit).
local function FindMain(brain, ctx)
    local kind = BO.StartFactory[ctx.role] or 'Land'
    local best, bestTech
    for _, f in ipairs(brain:GetListOfUnits(Utils.FactoryCategory(kind), false)) do
        if Alive(f) and f:GetFractionComplete() >= 1 then
            local t = TechOf(f)
            -- Prefer HQs over support factories, and the current main on ties.
            if not EntityCategoryContains(categories.SUPPORTFACTORY, f) then t = t + 0.5 end
            if f == ctx.mainFactory then t = t + 0.25 end
            if not bestTech or t > bestTech then best, bestTech = f, t end
        end
    end
    ctx.mainFactory = best
    return best
end

local function Build(f, id)
    if id then IssueBuildFactory({ f }, id, 1) end
end

---------------------------------------------------------------------------
-- First factory build order
---------------------------------------------------------------------------
local FactorySteps = {}

FactorySteps.Engineer = function(brain, ctx, f, step)
    local tech = step.tech or 1
    if EngineersOfTech(brain, tech) >= step.count then return true end
    if f:IsIdleState() and TechOf(f) >= tech then
        Build(f, Utils.FactionId(brain, 'EngineerT' .. tech))
    end
    return false
end

FactorySteps.Upgrade = function(brain, ctx, f, step)
    ctx.factoryUpgradeTarget = ctx.factoryUpgradeTarget or (TechOf(f) + 1)
    if TechOf(f) >= ctx.factoryUpgradeTarget then
        ctx.factoryUpgradeTarget = nil
        return true
    end
    if f:IsIdleState() then
        local to = f:GetBlueprint().General.UpgradesTo
        if to and to ~= '' then
            IssueUpgrade({ f }, to)
        else
            ctx.factoryUpgradeTarget = nil
            return true
        end
    end
    return false
end

local ScoutKey = { Air = 'AirScout', Land = 'LandScout' }

-- Exposed for tests: scouts only from Config.ScoutStartSeconds on.
function ScoutsAllowed(now)
    return now >= Config.ScoutStartSeconds
end

FactorySteps.Scout = function(brain, ctx, f, step)
    local kind = Utils.FactoryKind(f)
    if step.factory and kind ~= step.factory then return true end
    if not ScoutKey[kind] then return true end
    if not ScoutsAllowed(GetGameTimeSeconds()) then return true end
    local id = Utils.FactionId(brain, ScoutKey[kind])
    if CountId(brain, id) >= step.count then return true end
    if f:IsIdleState() then Build(f, id) end
    return false
end

local function FactoryOpeningStep(brain, ctx, f)
    local step = BO.Factory[ctx.factoryStep]
    if not step then
        ctx.factoryBODone = true
        Utils.Log(brain, 'factory opening done at ' .. math.floor(GetGameTimeSeconds()) .. 's')
        return
    end
    local handler = FactorySteps[step[1]]
    if not handler or handler(brain, ctx, f, step) then
        ctx.factoryStep = ctx.factoryStep + 1
    end
end

---------------------------------------------------------------------------
-- Production after the opening
---------------------------------------------------------------------------
local function EntryTech(key)
    return tonumber(string.sub(key, 2, 2)) or 1
end

local function RefillEngineers(brain, ctx, f)
    local targets = BO.EngineerTargets[ctx.role]
    if not targets then return false end
    local extra = Utils.MassBanked(brain) and Config.BankedExtraEngineers or 0
    for tech = TechOf(f), 1, -1 do
        local want = targets[tech] and (targets[tech] + ((tech == 3) and extra or 0))
        if want and EngineersOfTech(brain, tech) < want then
            Build(f, Utils.FactionId(brain, 'EngineerT' .. tech))
            return true
        end
    end
    return false
end

-- Exposed for tests: which id a Keep entry builds on a factory of `tech`
-- (the `late` replacement on T3 when the factory can build it).
function KeepPick(entry, tech, idOf, canBuild)
    local id = idOf(entry[1])
    local lateId = entry.late and idOf(entry.late)
    if lateId and tech >= 3 and canBuild(lateId) then return lateId end
    if id and canBuild(id) then return id end
    return nil
end

local function KeepList(brain, ctx, list, f, kind)
    for _, k in ipairs(list or {}) do
        if k.kind == kind then
            local idOf = function(key) return Utils.FactionId(brain, key) end
            local have = 0
            if idOf(k[1]) then have = have + CountId(brain, idOf(k[1])) end
            if k.late and idOf(k.late) then have = have + CountId(brain, idOf(k.late)) end
            if have < (k.count or 1) then
                local id = KeepPick(k, TechOf(f), idOf, function(x) return f:CanBuild(x) end)
                if id then
                    Build(f, id)
                    return true
                end
            end
        end
    end
    return false
end

-- Scouts and other support units (BuildOrders.Keep), any factory tech;
-- plus the search units (BuildOrders.HuntKeep) while the enemy is lost.
local function KeepUnits(brain, ctx, f)
    local kind = Utils.FactoryKind(f)
    if ScoutsAllowed(GetGameTimeSeconds()) and KeepList(brain, ctx, BO.Keep[ctx.role], f, kind) then return true end
    if Intel.HuntMode(ctx.side) and KeepList(brain, ctx, BO.HuntKeep[ctx.role], f, kind) then return true end
    return false
end

-- Highest finished factory tech of the factory's kind.
local function KindTopTech(brain, f)
    local top = 1
    for _, x in ipairs(brain:GetListOfUnits(Utils.FactoryCategory(Utils.FactoryKind(f)), false)) do
        if Alive(x) and x:GetFractionComplete() >= 1 then top = math.max(top, TechOf(x)) end
    end
    return top
end

-- Exposed for tests: a factory behind the best one of its kind stops
-- making units (low-tech units only die) and waits for its upgrade.
function HoldForUpgrade(factoryTech, topTech, isMain)
    return not isMain and factoryTech < topTech
end

-- Global so tests can drive it.
function Produce(brain, ctx, f)
    if f == ctx.mainFactory and RefillEngineers(brain, ctx, f) then return end
    if HoldForUpgrade(TechOf(f), KindTopTech(brain, f), f == ctx.mainFactory) then return end
    if KeepUnits(brain, ctx, f) then return end
    local byKind = BO.Production[ctx.role]
    local list = byKind and byKind[Utils.FactoryKind(f)]
    if not list then return end
    local tech = TechOf(f)
    local capMul = Utils.MassBanked(brain) and Config.BankedCapMul or 1

    -- Highest tech level that still has an entry under its cap. T1 entries
    -- are only allowed on a T1 factory: no T1 spam after the upgrade.
    local open = {}
    local topTech = 0
    for _, entry in ipairs(list) do
        local key = entry[1]
        local et = EntryTech(key)
        local id = Utils.FactionId(brain, key)
        if id and et <= tech and (et > 1 or tech == 1)
            and (not entry.cap or CountId(brain, id) < entry.cap * capMul) then
            table.insert(open, { id = id, tech = et })
            if et > topTech then topTech = et end
        end
    end
    local pick = {}
    for _, o in ipairs(open) do
        if o.tech == topTech then table.insert(pick, o) end
    end
    local n = table.getn(pick)
    if n == 0 then return end
    f.DGNext = (f.DGNext or 0) + 1
    if f.DGNext > n then f.DGNext = 1 end
    Build(f, pick[f.DGNext].id)
end

---------------------------------------------------------------------------
-- Factory upgrades after the opening: support factories follow the HQ of
-- their kind; a kind without an HQ above T1 (e.g. naval yards when the start
-- factory is an air factory) gets one HQ upgrade.
---------------------------------------------------------------------------
local function UpgradeFactories(brain, ctx)
    if brain:GetEconomyStoredRatio('MASS') < 0.2 or brain:GetEconomyStoredRatio('ENERGY') < 0.5 then return end
    local running = 0
    for _, f in ipairs(brain:GetListOfUnits(CatAllFactories, false)) do
        if Alive(f) and f:IsUnitState('Upgrading') then running = running + 1 end
    end
    local most = Utils.MassBanked(brain) and Config.FactoryUpgradesAtOnceBanked or Config.FactoryUpgradesAtOnce
    if running >= most then return end
    for _, kind in ipairs({ 'Land', 'Air', 'Naval' }) do
        local list = {}
        local hqTech, hq = 0, nil
        for _, f in ipairs(brain:GetListOfUnits(Utils.FactoryCategory(kind), false)) do
            if Ready(f) then
                table.insert(list, f)
                if not EntityCategoryContains(categories.SUPPORTFACTORY, f) and TechOf(f) > hqTech then
                    hqTech, hq = TechOf(f), f
                end
            end
        end
        for _, f in ipairs(list) do
            if f ~= hq and f ~= ctx.mainFactory and TechOf(f) < hqTech and f:IsIdleState() then
                local id = Utils.SupportFactoryId(brain, kind, TechOf(f) + 1)
                if id and f:CanBuild(id) then
                    IssueUpgrade({ f }, id)
                    return
                end
            end
        end
        if hq and hq ~= ctx.mainFactory and hqTech < 3 and hq:IsIdleState()
            and GetGameTimeSeconds() > 300 then
            local to = hq:GetBlueprint().General.UpgradesTo
            if to and to ~= '' then
                IssueUpgrade({ hq }, to)
                return
            end
        end
    end
end

---------------------------------------------------------------------------
-- Global so the opening simulation test can tick it.
function FactoryStep(brain, ctx)
    local main = FindMain(brain, ctx)

    -- T2 phase clock: starts with this player's first T2 factory.
    if not ctx.t2Time then
        for _, f in ipairs(brain:GetListOfUnits(CatAllFactories * (categories.TECH2 + categories.TECH3), false)) do
            if Alive(f) and f:GetFractionComplete() >= 1 then
                ctx.t2Time = GetGameTimeSeconds()
                ctx.t2EndTime = ctx.t2Time + Config.T2PhaseLength
                Utils.Log(brain, 'T2 factory at ' .. math.floor(ctx.t2Time) .. 's, T2 phase ends at '
                    .. math.floor(ctx.t2EndTime) .. 's')
                break
            end
        end
    end

    if main and not ctx.factoryBODone and Ready(main) then
        FactoryOpeningStep(brain, ctx, main)
        -- An upgrade may have just replaced the main factory.
        main = FindMain(brain, ctx)
    end

    for _, f in ipairs(brain:GetListOfUnits(CatAllFactories, false)) do
        if Ready(f) and f:IsIdleState() and (f ~= main or ctx.factoryBODone) then
            Produce(brain, ctx, f)
        end
    end

    ctx.factoryUpgradeTick = (ctx.factoryUpgradeTick or 0) + 1
    if ctx.factoryBODone and ctx.factoryUpgradeTick >= 5 then
        ctx.factoryUpgradeTick = 0
        UpgradeFactories(brain, ctx)
    end
end

function Start(brain, ctx)
    ctx.factoryStep = 1
    ForkThread(Utils.RunLoop, 'Factories', brain, ctx, 1, FactoryStep)
end
