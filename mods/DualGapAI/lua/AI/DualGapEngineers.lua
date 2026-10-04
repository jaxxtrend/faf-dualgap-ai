-- ACU opening and all engineer work.
--
-- The stock EngineerManager gets no engineer builders, so it never orders
-- an engineer around; this module owns the ACU (during its opening, and
-- afterwards whenever the ACU is in "base builder" mode) and every engineer.
--
--   ACU opening   BuildOrders.ACU, strictly in order
--   T1 eng 1..10  BuildOrders.T1Engineers roles (reclaim / hydro crew)
--   everyone else GeneralTask: projects -> own mexes -> power -> rebuild
--                 what the base lost -> mass storages around T2+ mexes ->
--                 mass fabricators -> role factories -> reclaim (base, then
--                 the own half of the mid) -> assist
--
-- Grid: power goes next to air factories first (adjacency cuts their energy
-- cost), then next to mass fabricators, then next to any factory; mass
-- fabricators go next to T3 power.
--
-- Like a human player, a bot only has a few new structures going up at a
-- time (Utils.CanStartBuild / Config.MaxConcurrentBuilds): when the slots
-- are full, engineers assist what is already being built instead of
-- starting more. Mexes and storages are exempt, and so is power while
-- energy is running out.
--
-- Enemy Yolona Oss known: idle engineers assist own anti-nukes so they
-- build interceptor missiles faster (Config.SMDAmmoWanted).

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local MexOwn = import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local Alive = Utils.Alive

local CatEngineer = categories.ENGINEER - categories.COMMAND - categories.SUBCOMMANDER
local CatPowerT1 = categories.ENERGYPRODUCTION * categories.TECH1 * categories.STRUCTURE - categories.HYDROCARBON
local CatHydro = categories.HYDROCARBON * categories.STRUCTURE
local CatStorage = categories.ENERGYSTORAGE * categories.STRUCTURE
local CatMex = categories.MASSEXTRACTION * categories.STRUCTURE
local CatMassFab = categories.MASSFABRICATION * categories.STRUCTURE
local CatPowerT3 = categories.ENERGYPRODUCTION * categories.TECH3 * categories.STRUCTURE

local function Economy()
    return import('/mods/DualGapAI/lua/AI/DualGapEconomy.lua')
end

local function Projects()
    return import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
end

---------------------------------------------------------------------------
-- Placement helpers
---------------------------------------------------------------------------
local FootprintOf = Utils.FootprintOf

-- Spots whose footprint touches the building at `center` (edge adjacency).
local function AdjacentSpots(center, centerSize, size)
    local spots = {}
    local off = (centerSize + size) / 2
    local span = (centerSize - size) / 2
    if span < 0 then span = 0 end
    local t = -span
    while t <= span + 0.01 do
        table.insert(spots, { center[1] + off, 0, center[3] + t })
        table.insert(spots, { center[1] - off, 0, center[3] + t })
        table.insert(spots, { center[1] + t, 0, center[3] + off })
        table.insert(spots, { center[1] + t, 0, center[3] - off })
        t = t + size
    end
    return spots
end

local function FarFromAll(p, chosen, minD)
    for _, c in ipairs(chosen) do
        if Utils.Dist2D(p, c) < minD then return false end
    end
    return true
end

-- Up to n buildable spots for id: adjacent to `anchor` unit first, then a
-- spiral around `fallback` (none when fallback is nil). `chosen` holds spots
-- already queued this tick.
local function PickSpots(brain, id, n, anchor, fallback, chosen)
    local out = {}
    chosen = chosen or {}
    local size = FootprintOf(id)
    if anchor and Alive(anchor) then
        local ap = anchor:GetPosition()
        local isFactory = EntityCategoryContains(categories.FACTORY, anchor)
        for _, p in ipairs(AdjacentSpots(ap, Utils.SizeOfBp(anchor:GetBlueprint()), size)) do
            if table.getn(out) >= n then break end
            p[2] = GetSurfaceHeight(p[1], p[3])
            -- Never on a land / naval factory's exit side (+z), units roll
            -- out there; aircraft just fly off, so an air factory gets
            -- power on every side (as players do).
            local blocksExit = isFactory and not EntityCategoryContains(categories.AIR, anchor) and p[3] > ap[3] + 0.5
            -- Gap 0: touching the anchor is the point, but other factories'
            -- exit lanes still stay free.
            if not blocksExit and FarFromAll(p, chosen, size) and not Utils.Reserved(id, p) and brain:CanBuildStructureAt(id, p)
                and Utils.HasClearance(brain, id, p, 0) then
                table.insert(out, p); table.insert(chosen, p)
            end
        end
    end
    if not fallback then return out end
    local r = size
    while table.getn(out) < n and r <= 70 do
        for i = 0, 11 do
            if table.getn(out) >= n then break end
            local a = (i / 12) * 2 * math.pi
            local p = { fallback[1] + math.cos(a) * r, 0, fallback[3] + math.sin(a) * r }
            p[2] = GetSurfaceHeight(p[1], p[3])
            if FarFromAll(p, chosen, size + 2) and not Utils.Reserved(id, p) and brain:CanBuildStructureAt(id, p)
                and Utils.HasClearance(brain, id, p, 2) then
                table.insert(out, p); table.insert(chosen, p)
            end
        end
        r = r + size
    end
    return out
end

local function TowardEnemy(ctx)
    return (ctx.side == 'LEFT') and 1 or -1
end

local function BaseSite(ctx, forward)
    local p = ctx.startPos
    return { p[1] + TowardEnemy(ctx) * forward, p[2], p[3] }
end

local function MainFactory(brain, ctx)
    if Alive(ctx.mainFactory) then return ctx.mainFactory end
    return nil
end

local function FirstUnfinished(brain, cat, near, radius)
    for _, u in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(u) and u:GetFractionComplete() < 1
            and (not near or Utils.Dist2D(u:GetPosition(), near) <= radius) then
            return u
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- ACU opening
---------------------------------------------------------------------------
local function HydroMarker(ctx)
    if ctx.hydroPos ~= nil then return ctx.hydroPos end
    local best, bestD
    for _, m in pairs(ScenarioUtils.GetMarkers() or {}) do
        if m.type == 'Hydrocarbon' and m.position then
            local d = Utils.Dist2D(m.position, ctx.startPos)
            if d <= Config.BaseRadius * 1.5 and (not bestD or d < bestD) then best, bestD = m.position, d end
        end
    end
    ctx.hydroPos = best or false
    return ctx.hydroPos
end

-- Exposed for tests: where the first factory goes when the base has a
-- hydrocarbon spot - touching it (players build the factory against the
-- hydro: the plant feeds it, and the factory gets the adjacency bonus).
-- Of the spots around the hydro, the one nearest the start; buildable(p)
-- filters them.
function HydroFactorySpot(hydro, start, hydroSize, factorySize, buildable)
    local off = (hydroSize + factorySize) / 2
    local best, bestD
    for _, d in ipairs({ { off, 0 }, { -off, 0 }, { 0, off }, { 0, -off } }) do
        local p = { hydro[1] + d[1], hydro[2], hydro[3] + d[2] }
        local dd = Utils.Dist2D(p, start)
        if buildable(p) and (not bestD or dd < bestD) then best, bestD = p, dd end
    end
    return best
end

local ACUSteps = {}

ACUSteps.Factory = function(brain, ctx, acu, step)
    local kind = BO.StartFactory[ctx.role] or 'Land'
    local cat = Utils.FactoryCategory(kind)
    for _, f in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(f) and f:GetFractionComplete() >= 1 then
            ctx.mainFactory = f
            return true
        end
    end
    if not Utils.IsIdle(acu) then return false end
    local unfinished = FirstUnfinished(brain, cat)
    if unfinished then
        IssueRepair({ acu }, unfinished)
        return false
    end
    local id = Utils.FactoryId(brain, kind, 1)
    local hydro = HydroMarker(ctx)
    if hydro and kind ~= 'Naval' and Utils.Dist2D(hydro, ctx.startPos) <= Config.HydroFactoryRadius then
        local hid = Utils.FactionId(brain, 'HydroT1')
        local spot = HydroFactorySpot(hydro, ctx.startPos, Utils.SizeOfBp(__blueprints[hid]), Utils.SizeOfBp(__blueprints[id]),
            function(p)
                p[2] = GetSurfaceHeight(p[1], p[3])
                return brain:CanBuildStructureAt(id, p)
            end)
        if spot then
            IssueBuildMobile({ acu }, spot, id, {})
            Utils.Log(brain, 'first factory against the hydrocarbon plant')
            return false
        end
    end
    Utils.BuildNear(brain, acu, id, BaseSite(ctx, 12), 40)
    return false
end

local function BaseMexCount(brain)
    local n = 0
    for _, m in ipairs(MexOwn.Owned(brain.Name, 'BASE')) do
        if MexOwn.ExtractorAt(brain, m.pos) then n = n + 1 end
    end
    return n
end

ACUSteps.Mex = function(brain, ctx, acu, step)
    local target = step.cumulative
    local have = BaseMexCount(brain)
    if have >= target then return true end
    -- Collect free own base markers, nearest first.
    local free = {}
    for _, m in ipairs(MexOwn.Owned(brain.Name, 'BASE')) do
        if MexOwn.IsFree(brain, m.pos) then table.insert(free, m) end
    end
    if table.getn(free) == 0 then return true end   -- nothing left to take
    if not Utils.IsIdle(acu) then return false end
    local from = acu:GetPosition()
    local id = Utils.FactionId(brain, 'MassExtractorT1')
    local need = target - have
    -- Greedy nearest-neighbour chain so the ACU walks a short path.
    local used = {}
    for _ = 1, math.min(need, table.getn(free)) do
        local best, bestD
        for i, m in ipairs(free) do
            if not used[i] then
                local d = Utils.Dist2D(from, m.pos)
                if not bestD or d < bestD then best, bestD = i, d end
            end
        end
        used[best] = true
        IssueBuildMobile({ acu }, free[best].pos, id, {})
        from = free[best].pos
    end
    return false
end

ACUSteps.Power = function(brain, ctx, acu, step)
    local have = Utils.Count(brain:GetListOfUnits(CatPowerT1, false))
    if have >= step.cumulative then return true end
    if not Utils.IsIdle(acu) then return false end
    local id = Utils.FactionId(brain, 'PowerT1')
    local spots = PickSpots(brain, id, step.cumulative - have, MainFactory(brain, ctx), ctx.startPos)
    for _, p in ipairs(spots) do IssueBuildMobile({ acu }, p, id, {}) end
    return table.getn(spots) == 0
end

ACUSteps.UpgradeMexes = function(brain, ctx, acu, step)
    ctx.mexUpgradeTech = step.tech or 2
    ctx.mexUpgradesAllowed = true
    if BO.UpgradeMexesNoAssist[ctx.role] then return true end
    local pending, upgrading = false, nil
    for _, m in ipairs(MexOwn.Owned(brain.Name, 'BASE')) do
        local e = MexOwn.ExtractorAt(brain, m.pos)
        if e and Utils.TechOf(e) < ctx.mexUpgradeTech then
            pending = true
            if e:IsUnitState('Upgrading') then upgrading = e end
        end
    end
    if not pending then return true end
    if upgrading and Utils.IsIdle(acu) then IssueGuard({ acu }, upgrading) end
    return false
end

-- Cumulative targets so steps are idempotent (re-issued after interruptions).
local function PrepareSteps()
    local mex, power = 0, 0
    for _, step in ipairs(BO.ACU) do
        if step[1] == 'Mex' then mex = mex + (step.count or 1); step.cumulative = mex end
        if step[1] == 'Power' then power = power + (step.count or 1); step.cumulative = power end
    end
end

-- Global (like EngineersStep) so the opening simulation test can tick it.
function ACUOpeningStep(brain, ctx)
    if ctx.acuBODone then return end
    local acu = Utils.Commander(brain)
    if not acu or ctx.acuState == 'SUBMERGED' then return end
    local step = BO.ACU[ctx.acuStep]
    if not step then
        ctx.acuBODone = true
        Utils.Log(brain, 'ACU opening done at ' .. math.floor(GetGameTimeSeconds()) .. 's')
        return
    end
    local handler = ACUSteps[step[1]]
    if not handler then
        WARN('DualGap: unknown ACU step ' .. tostring(step[1]))
        ctx.acuStep = ctx.acuStep + 1
        return
    end
    if handler(brain, ctx, acu, step) then
        ctx.acuStep = ctx.acuStep + 1
    end
end

---------------------------------------------------------------------------
-- Reclaim: pick the richest unclaimed 24x24 cell near the base and queue
-- reclaim orders on its props (trees, rocks, wrecks), nearest first.
---------------------------------------------------------------------------
local CellSize = 24

local function PropValue(e)
    local left = e.ReclaimLeft or 1
    return ((e.MaxMassReclaim or 0) + (e.MaxEnergyReclaim or 0) / 10) * left
end

-- Known enemy army near pos (engineers don't walk into a fight to reclaim).
local CatEnemyArmy = categories.MOBILE * (categories.LAND + categories.NAVAL) * categories.DIRECTFIRE

local function Unsafe(brain, pos)
    local army = brain:GetArmyIndex()
    local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatEnemyArmy, pos, Config.MidReclaimSafeRadius, 'Enemy') or {}) do
        if Intel.Known(e, army) then return true end
    end
    return false
end

-- Reclaim zones: the base, then both mid defensive points of the own side
-- (wrecks pile up there after every fight).
local function ReclaimZones(ctx)
    local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
    local zones = { { center = ctx.startPos, r = Config.ReclaimRadius, min = Config.ReclaimMinValue } }
    for _, name in ipairs({ 'ChokeUpper', 'ChokeLower' }) do
        table.insert(zones, { center = Routes.GetPoint(name, ctx.side), r = Config.MidReclaimRadius,
            min = Config.MidReclaimMinValue, mid = true })
    end
    return zones
end

local function ReclaimTask(brain, ctx, u)
    local cells = {}
    for _, z in ipairs(ReclaimZones(ctx)) do
        local c, r = z.center, z.r
        for _, e in ipairs(GetReclaimablesInRect(Rect(c[1] - r, c[3] - r, c[1] + r, c[3] + r)) or {}) do
            if e.IsProp and not e.Dead then
                local v = PropValue(e)
                if v > 0.2 then
                    local p = e:GetPosition()
                    local key = math.floor(p[1] / CellSize) .. ':' .. math.floor(p[3] / CellSize)
                    local cell = cells[key]
                    if not cell then
                        cell = { value = 0, props = {}, min = z.min, mid = z.mid, pos = p }
                        cells[key] = cell
                    end
                    cell.value = cell.value + v
                    table.insert(cell.props, e)
                end
            end
        end
    end
    local now = GetGameTimeSeconds()
    ctx.reclaimClaims = ctx.reclaimClaims or {}
    -- Richest unclaimed cell (worth less the further it is); if all are
    -- claimed, share the richest one. Mid cells must be safe.
    local from0 = u:GetPosition()
    local bestKey, best, bestScore, sharedKey, shared
    for key, cell in pairs(cells) do
        if cell.value >= cell.min and not (cell.mid and Unsafe(brain, cell.pos)) then
            local score = cell.value / (1 + Utils.Dist2D(from0, cell.pos) / 200)
            local claim = ctx.reclaimClaims[key]
            local claimed = claim and claim.expires > now and claim.unit ~= u and Alive(claim.unit)
            if not claimed and (not bestScore or score > bestScore) then bestKey, best, bestScore = key, cell, score end
            if not shared or cell.value > shared.value then sharedKey, shared = key, cell end
        end
    end
    if not best then bestKey, best = sharedKey, shared end
    if not best then return false end
    ctx.reclaimClaims[bestKey] = { unit = u, expires = now + 90 }

    local from = u:GetPosition()
    local left = best.props
    local issued = 0
    while table.getn(left) > 0 and issued < 20 do
        local bi, bd
        for i, e in ipairs(left) do
            local d = Utils.Dist2D(from, e:GetPosition())
            if not bd or d < bd then bi, bd = i, d end
        end
        local e = table.remove(left, bi)
        IssueReclaim({ u }, e)
        from = e:GetPosition()
        issued = issued + 1
    end
    return issued > 0
end

---------------------------------------------------------------------------
-- Hydro crew: build the hydro, then energy storages next to it, then assist
---------------------------------------------------------------------------

local function OwnHydro(brain, ctx)
    local pos = HydroMarker(ctx)
    if not pos then return nil end
    for _, u in ipairs(brain:GetUnitsAroundPoint(CatHydro, pos, 3, 'Ally') or {}) do
        if Alive(u) and u:GetAIBrain() == brain then return u end
    end
    return nil
end

local function HydroTask(brain, ctx, u)
    local pos = HydroMarker(ctx)
    if not pos then u.DGRole = 'AssistACU'; return end
    local hydro = OwnHydro(brain, ctx)
    if hydro and hydro:GetFractionComplete() >= 1 then
        u.DGRole = 'Storage'
        return
    end
    if not u:IsIdleState() then return end
    if hydro then
        IssueRepair({ u }, hydro)
    elseif brain:CanBuildStructureAt(Utils.FactionId(brain, 'HydroT1'), pos) then
        IssueBuildMobile({ u }, pos, Utils.FactionId(brain, 'HydroT1'), {})
    else
        u.DGRole = 'AssistACU'   -- marker taken by someone else
    end
end

local function StorageTask(brain, ctx, u)
    local hydro = OwnHydro(brain, ctx)
    if not hydro then u.DGRole = 'AssistACU'; return end
    if not u:IsIdleState() then return end
    local hp = hydro:GetPosition()
    local unfinished = FirstUnfinished(brain, CatStorage, hp, 12)
    if unfinished then IssueRepair({ u }, unfinished); return end
    local have = Utils.Count(brain:GetUnitsAroundPoint(CatStorage, hp, 12, 'Ally'))
    if have >= BO.HydroStorages then u.DGRole = 'AssistACU'; return end
    local id = Utils.FactionId(brain, 'EnergyStorage')
    local spot = PickSpots(brain, id, 1, hydro, hp)[1]
    if spot then IssueBuildMobile({ u }, spot, id, {}) else u.DGRole = 'AssistACU' end
end

local function AssistACUTask(brain, ctx, u)
    local acu = Utils.Commander(brain)
    -- The ACU's opening is over or it left the base: become a general engineer.
    if ctx.acuBODone or not acu or Utils.Dist2D(acu:GetPosition(), ctx.startPos) > 60 then
        u.DGRole = nil
        IssueClearCommands({ u })
        return
    end
    if not u:IsIdleState() then return end
    -- Don't follow the ACU into the water.
    if acu and ctx.acuState ~= 'SUBMERGED' then
        IssueGuard({ u }, acu)
    else
        u.DGRole = nil
    end
end

---------------------------------------------------------------------------
-- General tasks
---------------------------------------------------------------------------
local function EnergyLow(brain)
    local ratio = brain:GetEconomyStoredRatio('ENERGY')
    if ratio < 0.25 or (ratio < 0.6 and brain:GetEconomyTrend('ENERGY') < 0) then return true end
    -- Spending more than the income, even with full storage.
    return brain:GetEconomyIncome('ENERGY') < brain:GetEconomyRequested('ENERGY') * 1.05
end

local function EnergyStalled(brain)
    return brain:GetEconomyStoredRatio('ENERGY') < Config.EnergyStall
end

-- A T2 / T3 engineer not tied to a project (it can build better power).
local function FreeHigherEngineer(brain)
    for _, e in ipairs(brain:GetListOfUnits(CatEngineer * (categories.TECH2 + categories.TECH3), false)) do
        if Alive(e) and e:GetFractionComplete() >= 1 and not e.DualGapAssigned then return true end
    end
    return false
end

local function BestPowerId(brain, u)
    for _, key in ipairs({ 'PowerT3', 'PowerT2', 'PowerT1' }) do
        local id = Utils.FactionId(brain, key)
        if id and u:CanBuild(id) then
            -- Players stop T1 generators once T2 power is in reach: T1
            -- engineers leave power to a free T2 / T3 engineer - but if all
            -- of those are busy on projects, T1 power it is (no stall).
            if key == 'PowerT1' and not EnergyStalled(brain) and FreeHigherEngineer(brain) then
                return nil
            end
            return id
        end
    end
    return nil
end

local function PowerUnderConstruction(brain)
    local n = 0
    for _, e in ipairs(brain:GetListOfUnits(categories.ENERGYPRODUCTION * categories.STRUCTURE, false)) do
        if Alive(e) and e:GetFractionComplete() < 1 then n = n + 1 end
    end
    return n
end

local function TryMex(brain, ctx, u, baseOnly)
    ctx.mexClaims = ctx.mexClaims or {}
    local now = GetGameTimeSeconds()
    local exclude = {}
    for m, c in pairs(ctx.mexClaims) do
        if c.expires > now and c.unit ~= u and Alive(c.unit) then exclude[m] = true end
    end
    -- The ACU's opening builds all base mexes itself; engineers keep off them.
    if not ctx.acuBODone and u ~= Utils.Commander(brain) then
        for _, bm in ipairs(MexOwn.Owned(brain.Name, 'BASE')) do exclude[bm] = true end
    end
    local maxD = baseOnly and Config.BaseRadius or nil
    local m = MexOwn.NearestFree(brain, baseOnly and ctx.startPos or u:GetPosition(), nil, maxD, exclude)
    if not m then return false end
    ctx.mexClaims[m] = { unit = u, expires = now + 90 }
    IssueBuildMobile({ u }, m.pos, Utils.FactionId(brain, 'MassExtractorT1'), {})
    return true
end

-- Grid anchors for a power generator, best first: air factories (their
-- production costs a lot of energy), mass fabricators, then the rest of
-- the factories.
local CatStrategic = categories.STRUCTURE * (categories.NUKE + categories.GATE
    + categories.ANTIMISSILE * categories.TECH3 + categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
    + categories.EXPERIMENTAL)

-- Exposed for tests: anchor groups for a generator of tech `tech`, best
-- first, as names. T1 power only goes against factories (the ring around
-- the first factory); T2/T3 power goes against what draws the most energy
-- - game enders, anti-nukes, gates - then factories, shields, T3 mass
-- fabricators, then the power block itself. Never against the mex blocks.
function PowerAnchorOrder(tech)
    if tech <= 1 then return { 'airFactory', 'factory' } end
    return { 'strategic', 'airFactory', 'factory', 'shield', 'fabT3', 'power' }
end

local AnchorCats = {
    airFactory = categories.FACTORY * categories.AIR * categories.STRUCTURE,
    factory = categories.FACTORY * categories.STRUCTURE - categories.AIR,
    strategic = CatStrategic,
    shield = categories.SHIELD * categories.STRUCTURE,
    fabT3 = CatMassFab * categories.TECH3,
    power = categories.ENERGYPRODUCTION * categories.STRUCTURE * (categories.TECH2 + categories.TECH3) + categories.HYDROCARBON * categories.STRUCTURE,
}

local function PowerAnchors(brain, tech)
    local out = {}
    local cats = {}
    for _, name in ipairs(PowerAnchorOrder(tech or 3)) do table.insert(cats, AnchorCats[name]) end
    for _, cat in ipairs(cats) do
        for _, f in ipairs(brain:GetListOfUnits(cat, false)) do
            if Alive(f) and f:GetFractionComplete() >= 1 then table.insert(out, f) end
        end
    end
    return out
end

-- First free spot touching one of the anchors, or nil.
local function GridSpot(brain, id, anchors)
    for _, a in ipairs(anchors) do
        local spot = PickSpots(brain, id, 1, a, nil)[1]
        if spot then return spot end
    end
    return nil
end

local function TryPower(brain, ctx, u)
    local building = PowerUnderConstruction(brain)
    if not EnergyLow(brain) or building >= 3 or (building >= 2 and not EnergyStalled(brain)) then return false end
    local id = BestPowerId(brain, u)
    if not id then return false end
    -- Power may skip the queue only when energy is nearly gone.
    if brain:GetEconomyStoredRatio('ENERGY') > 0.1 and not Utils.CanStartBuild(brain, id) then return false end
    local c = (__blueprints[id] and __blueprints[id].CategoriesHash) or {}
    local tech = (c.TECH3 and 3) or (c.TECH2 and 2) or 1
    local spot = GridSpot(brain, id, PowerAnchors(brain, tech))
        or PickSpots(brain, id, 1, nil, BaseSite(ctx, -12))[1]
    if not spot then return false end
    IssueBuildMobile({ u }, spot, id, {})
    return true
end

-- Four mass storages around every own T2+ mex (they raise its output);
-- the mex waits for them before its T3 upgrade (DualGapEconomy).
local function TryMexStorage(brain, ctx, u)
    if brain:GetEconomyStoredRatio('MASS') < 0.05 and brain:GetEconomyTrend('MASS') <= 0 then return false end
    local id = Utils.FactionId(brain, 'MassStorage')
    if not id or not u:CanBuild(id) then return false end
    ctx.storageClaims = ctx.storageClaims or {}
    local now = GetGameTimeSeconds()
    local from = u:GetPosition()
    local best, bestD
    for _, m in ipairs(brain:GetListOfUnits(CatMex * (categories.TECH2 + categories.TECH3), false)) do
        if Alive(m) and m:GetFractionComplete() >= 1 then
            local d = Utils.Dist2D(from, m:GetPosition())
            if d <= 250 and (not bestD or d < bestD) then
                for _, s in ipairs(Economy().StorageSpots(brain, m)) do
                    local key = math.floor(s[1]) .. ':' .. math.floor(s[3])
                    local c = ctx.storageClaims[key]
                    if not (c and c.expires > now and c.unit ~= u and Alive(c.unit)) then
                        best, bestD = { spot = s, key = key }, d
                        break
                    end
                end
            end
        end
    end
    if not best then return false end
    ctx.storageClaims[best.key] = { unit = u, expires = now + 60 }
    IssueBuildMobile({ u }, best.spot, id, {})
    return true
end

---------------------------------------------------------------------------
-- Base upkeep: every structure we own near the start is remembered by its
-- spot; when one is destroyed, an engineer rebuilds it there. Mexes,
-- factories, anti-air, shields, anti-nuke, artillery, nukes, radars /
-- sonars and experimentals have their own planners and are left to them.
---------------------------------------------------------------------------
local CatRebuildSkip = categories.MASSEXTRACTION + categories.FACTORY + categories.WALL + categories.ANTIAIR
    + categories.SHIELD + categories.ANTIMISSILE + categories.ARTILLERY + categories.NUKE + categories.EXPERIMENTAL
    + categories.RADAR + categories.SONAR + categories.OMNI

local function SpotKey(pos)
    return math.floor(pos[1]) .. ':' .. math.floor(pos[3])
end

-- Exposed for tests: the first id down the upgrade chain (UpgradesFrom)
-- that canBuild accepts, e.g. a lost T3 shield is rebuilt as its T2 base.
function BuildableRoot(id, canBuild, bps)
    local guard = 0
    while id and id ~= '' and id ~= 'none' and guard < 8 do
        if canBuild(id) then return id end
        local bp = bps[id]
        id = bp and bp.General and bp.General.UpgradesFrom
        guard = guard + 1
    end
    return nil
end

local function UpkeepScan(brain, ctx)
    ctx.layout = ctx.layout or {}
    for _, u in ipairs(brain:GetListOfUnits(categories.STRUCTURE - CatRebuildSkip, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local p = u:GetPosition()
            if Utils.Dist2D(p, ctx.startPos) <= Config.UpkeepRadius then
                ctx.layout[SpotKey(p)] = { id = u:GetBlueprint().BlueprintId, pos = { p[1], p[2], p[3] }, unit = u }
            end
        end
    end
end

local function TryRebuild(brain, ctx, u)
    if not ctx.layout or brain:GetEconomyStoredRatio('MASS') < 0.05 then return false end
    ctx.rebuildClaims = ctx.rebuildClaims or {}
    local now = GetGameTimeSeconds()
    local from = u:GetPosition()
    local canBuild = function(x) return u:CanBuild(x) end
    local best, bestD, bestId, bestKey
    for key, r in pairs(ctx.layout) do
        if not Alive(r.unit) then
            local c = ctx.rebuildClaims[key]
            if not (c and c.expires > now and c.unit ~= u and Alive(c.unit)) then
                local id = BuildableRoot(r.id, canBuild, __blueprints)
                if id and not Utils.CanStartBuild(brain, id) then
                    id = nil        -- slots full: rebuild later
                elseif id and brain:CanBuildStructureAt(id, r.pos) then
                    if not Unsafe(brain, r.pos) then
                        local d = Utils.Dist2D(from, r.pos)
                        if not bestD or d < bestD then best, bestD, bestId, bestKey = r, d, id, key end
                    end
                elseif id then
                    -- The spot is taken: forget it once something of ours stands there.
                    for _, x in ipairs(brain:GetUnitsAroundPoint(categories.STRUCTURE, r.pos, 2, 'Ally') or {}) do
                        if Alive(x) and x:GetAIBrain() == brain then ctx.layout[key] = nil; break end
                    end
                end
            end
        end
    end
    if not best then return false end
    ctx.rebuildClaims[bestKey] = { unit = u, expires = now + 60 }
    Utils.Log(brain, 'rebuilding ' .. bestId)
    IssueBuildMobile({ u }, best.pos, bestId, {})
    return true
end

-- Yolona Oss: speed up interceptor missiles by assisting own anti-nukes.
local CatSMD = categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE

-- The group's anti-nuke going up at the group centre (whoever started it):
-- help build it, up to Config.AntiNukeHelpers engineers on it.
local function TryAssistGroupSMD(brain, ctx, u)
    local center = Projects().GroupCenter(brain, ctx.side)
    if not center then return false end
    for _, s in ipairs(brain:GetUnitsAroundPoint(CatSMD, center, 40, 'Ally') or {}) do
        if Alive(s) and s:GetFractionComplete() < 1 then
            s.DGBuildHelpers = Utils.FilterAlive(s.DGBuildHelpers or {})
            if table.getn(s.DGBuildHelpers) < Config.AntiNukeHelpers then
                table.insert(s.DGBuildHelpers, u)
                IssueRepair({ u }, s)
                return true
            end
        end
    end
    return false
end

local function TryAssistSMD(brain, ctx, u)
    local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
    if table.getn(Intel.Enders(ctx.side, 'YOLONA')) == 0 then return false end
    for _, s in ipairs(brain:GetListOfUnits(CatSMD, false)) do
        if Alive(s) and s:GetFractionComplete() >= 1 and s.GetTacticalSiloAmmoCount
            and s:GetTacticalSiloAmmoCount() < Config.SMDAmmoWanted then
            local helpers = {}
            for _, h in ipairs(s.DGHelpers or {}) do
                if Alive(h) and not h:IsIdleState() then table.insert(helpers, h) end
            end
            s.DGHelpers = helpers
            if table.getn(helpers) < Config.SMDHelpers then
                table.insert(s.DGHelpers, u)
                IssueGuard({ u }, s)
                return true
            end
        end
    end
    return false
end

-- Exposed for tests: the corner spots of a mex's storage cross (the T2
-- mass fabricators of the player's mex block go there: each touches two
-- storages).
function MexCorners(mexPos, off)
    local out = {}
    for _, d in ipairs({ { off, off }, { -off, off }, { off, -off }, { -off, -off } }) do
        table.insert(out, { mexPos[1] + d[1], mexPos[2], mexPos[3] + d[2] })
    end
    return out
end

-- Mex blocks: once T3 power is up and energy is plentiful, T2 mass
-- fabricators fill the corners of every complete storage cross.
local function TryMexFab(brain, ctx, u)
    local id = Utils.FactionId(brain, 'MassFabT2')
    if not id or not u:CanBuild(id) then return false end
    if brain:GetEconomyStoredRatio('ENERGY') < Config.MexFabEnergyRatio
        or brain:GetEconomyTrend('ENERGY') * 10 < Config.MexFabEnergyTrend then return false end
    if Utils.Count(brain:GetListOfUnits(categories.ENERGYPRODUCTION * categories.TECH3 * categories.STRUCTURE, false)) == 0 then
        return false
    end
    if not Utils.CanStartBuild(brain, id) then return false end
    local off = (2 + Utils.FootprintOf(id)) / 2
    local from = u:GetPosition()
    local best, bestD
    for _, m in ipairs(brain:GetListOfUnits(CatMex * (categories.TECH2 + categories.TECH3), false)) do
        if Alive(m) and m:GetFractionComplete() >= 1 and table.getn(Economy().StorageSpots(brain, m)) == 0 then
            local d = Utils.Dist2D(from, m:GetPosition())
            if d <= 250 and (not bestD or d < bestD) then
                for _, c in ipairs(MexCorners(m:GetPosition(), off)) do
                    c[2] = GetSurfaceHeight(c[1], c[3])
                    if brain:CanBuildStructureAt(id, c) then best, bestD = c, d; break end
                end
            end
        end
    end
    if not best then return false end
    IssueBuildMobile({ u }, best, id, {})
    return true
end

-- Mass fabricators next to T3 power while energy overflows.
local function TryMassFab(brain, ctx, u)
    local id = Utils.FactionId(brain, 'MassFabT3')
    if not id or not u:CanBuild(id) then return false end
    if brain:GetEconomyStoredRatio('ENERGY') < 0.9 or brain:GetEconomyStoredRatio('MASS') > 0.5 then return false end
    if brain:GetEconomyTrend('ENERGY') * 10 < Config.MassFabEnergySurplus then return false end
    if FirstUnfinished(brain, CatMassFab) or not Utils.CanStartBuild(brain, id) then return false end
    local anchors = {}
    for _, g in ipairs(brain:GetListOfUnits(CatPowerT3, false)) do
        if Alive(g) and g:GetFractionComplete() >= 1 then table.insert(anchors, g) end
    end
    local spot = GridSpot(brain, id, anchors)
    if not spot then return false end
    IssueBuildMobile({ u }, spot, id, {})
    return true
end

-- Exposed for tests: may another production factory start? With stored
-- mass always; the first half of the role's factories even with none in
-- store (projects otherwise eat every mass point and the army never grows).
function FactoryAllowed(have, wanted, massRatio, energyRatio)
    if energyRatio < 0.5 then return false end
    return massRatio >= 0.1 or have < math.ceil(wanted / 2)
end

local function TryFactories(brain, ctx, u)
    if brain:GetEconomyStoredRatio('ENERGY') < 0.5 then return false end
    local wanted = {}
    -- Banked mass and energy: the production factories are not enough to
    -- spend the income, so a few more of them.
    local extra = Utils.MassBanked(brain) and Config.BankedExtraFactories or 0
    for k, v in pairs(BO.ExtraFactories[ctx.role] or {}) do wanted[k] = v + extra end
    -- Inherited roles bring their factories too.
    for role, _ in pairs(ctx.duties or {}) do
        for k, v in pairs(BO.ExtraFactories[role] or {}) do
            if not wanted[k] or wanted[k] < v then wanted[k] = v end
        end
    end
    -- The ground player helps the navy once its mid is pushed, or when the
    -- team hunts an ACU hiding under water.
    if ctx.role == 'GROUND' and (ctx.midPushed or import('/mods/DualGapAI/lua/AI/DualGapIntel.lua').HuntMode(ctx.side)) then
        wanted.Naval = BO.NavalHelpFactories
    end
    -- The start factory is always wanted back if it died.
    local startKind = BO.StartFactory[ctx.role]
    for kind, max in pairs(wanted) do
        local cat = Utils.FactoryCategory(kind)
        local have = Utils.Count(brain:GetListOfUnits(cat, false))
        if have < max and FactoryAllowed(have, max, brain:GetEconomyStoredRatio('MASS'), brain:GetEconomyStoredRatio('ENERGY')) then
            local unfinished = FirstUnfinished(brain, cat)
            if unfinished then
                IssueRepair({ u }, unfinished)
                return true
            end
            -- With an HQ of higher tech, build the support factory of that
            -- tech straight away (as players do), not a T1 to upgrade.
            local id = Utils.FactoryId(brain, kind, 1)
            local hqTech = 1
            for _, f in ipairs(brain:GetListOfUnits(cat - categories.SUPPORTFACTORY, false)) do
                if Alive(f) and f:GetFractionComplete() >= 1 then hqTech = math.max(hqTech, Utils.TechOf(f)) end
            end
            local t = math.min(hqTech, Utils.TechOf(u))
            local support = (t > 1) and Utils.SupportFactoryId(brain, kind, t)
            if support and __blueprints[support] and u:CanBuild(support) then id = support end
            if not Utils.CanStartBuild(brain, id) then return false end
            local site = BaseSite(ctx, 0)
            if kind == 'Naval' then
                site = ctx.yardPos or Utils.FindNearestWater(ctx.startPos, 1.5, 250)
            end
            -- Air factories make one block with the power, as in a player's
            -- base: against a T2/T3 generator next to the factories, else
            -- against another air factory (land / naval keep their exit lanes).
            local spot
            if kind == 'Air' then
                local anchors = {}
                for _, g in ipairs(brain:GetListOfUnits(categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3) * categories.STRUCTURE, false)) do
                    if Alive(g) and Utils.CountAround(brain, cat, g:GetPosition(), 12, 'Ally') > 0 then table.insert(anchors, g) end
                end
                for _, f in ipairs(brain:GetListOfUnits(cat, false)) do table.insert(anchors, f) end
                spot = Utils.AdjacentSpot(brain, id, anchors)
            end
            spot = spot or (site and PickSpots(brain, id, 1, nil, site)[1])
            if spot then IssueBuildMobile({ u }, spot, id, {}); return true end
        end
    end
    if startKind and Utils.Count(brain:GetListOfUnits(Utils.FactoryCategory(startKind), false)) == 0 then
        local id = Utils.FactoryId(brain, startKind, 1)
        local spot = PickSpots(brain, id, 1, nil, BaseSite(ctx, 12))[1]
        if spot then IssueBuildMobile({ u }, spot, id, {}); return true end
    end
    return false
end

-- A factory upgrade in the base (the HQ first): engineers assist it, the
-- way players speed up their tech. At most 6 helpers per upgrade.
local function TryAssistUpgrade(brain, ctx, u)
    -- Assisting multiplies the upgrade's energy drain: only with energy to spare.
    if brain:GetEconomyStoredRatio('ENERGY') < 0.4 or EnergyLow(brain) then return false end
    local best
    for _, f in ipairs(brain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false)) do
        if Alive(f) and f:IsUnitState('Upgrading') and Utils.Dist2D(f:GetPosition(), ctx.startPos) < 90 then
            f.DGHelpers = Utils.FilterAlive(f.DGHelpers or {})
            if table.getn(f.DGHelpers) < 6 then
                if not best or not EntityCategoryContains(categories.SUPPORTFACTORY, f) then best = f end
            end
        end
    end
    if not best then return false end
    table.insert(best.DGHelpers, u)
    IssueGuard({ u }, best)
    return true
end

local function TryAssist(brain, ctx, u)
    -- Finish what is being built before helping the factory.
    local building = FirstUnfinished(brain, categories.STRUCTURE - categories.MASSEXTRACTION, ctx.startPos, 80)
    if building then
        IssueRepair({ u }, building)
        return true
    end
    if TryAssistUpgrade(brain, ctx, u) then return true end
    local f = MainFactory(brain, ctx)
    if f and not f:IsIdleState() then
        IssueGuard({ u }, f)
        return true
    end
    -- Anything of ours still under construction in the base.
    local unfinished = FirstUnfinished(brain, categories.STRUCTURE, ctx.startPos, 60)
    if unfinished then
        IssueRepair({ u }, unfinished)
        return true
    end
    return false
end

-- baseOnly: the ACU in base-builder mode never wanders off.
-- Economy first, like a player: no energy -> power; then the anti-nuke,
-- own mexes, power, and only then the other projects.
local function GeneralTask(brain, ctx, u, baseOnly)
    if EnergyStalled(brain) and TryPower(brain, ctx, u) then return end
    if not baseOnly and Projects().Offer(brain, ctx, u, 1) then return end
    if not baseOnly and TryAssistGroupSMD(brain, ctx, u) then return end
    if not baseOnly and TryAssistSMD(brain, ctx, u) then return end
    if baseOnly and ctx.role == 'ECO' and Economy().TryRAS(brain, ctx, u) then return end
    if TryMex(brain, ctx, u, baseOnly) then return end
    if TryPower(brain, ctx, u) then return end
    -- Banked mass and energy: more factories and faster upgrades come first.
    if Utils.MassBanked(brain) and (TryFactories(brain, ctx, u) or TryAssistUpgrade(brain, ctx, u)) then return end
    if not baseOnly and Projects().Offer(brain, ctx, u) then return end
    if TryRebuild(brain, ctx, u) then return end
    if TryMexStorage(brain, ctx, u) then return end
    if TryMexFab(brain, ctx, u) then return end
    if TryMassFab(brain, ctx, u) then return end
    if TryFactories(brain, ctx, u) then return end
    if not baseOnly and ReclaimTask(brain, ctx, u) then return end
    TryAssist(brain, ctx, u)
end

---------------------------------------------------------------------------
local RoleTasks = {
    Reclaim = function(brain, ctx, u)
        -- Temporary: after a while (at once if energy runs dry) the
        -- reclaimer becomes a general engineer.
        if GetGameTimeSeconds() > (u.DGRoleUntil or 0) or EnergyStalled(brain) then
            u.DGRole = nil
            IssueClearCommands({ u })
            return
        end
        if u:IsIdleState() and not ReclaimTask(brain, ctx, u) then u.DGRole = nil end
    end,
    Hydro = HydroTask,
    HydroAssist = HydroTask,
    Storage = StorageTask,
    AssistACU = AssistACUTask,
}

function EngineersStep(brain, ctx)
    ctx.upkeepTick = (ctx.upkeepTick or 0) + 1
    if ctx.upkeepTick >= 5 then
        ctx.upkeepTick = 0
        UpkeepScan(brain, ctx)
    end
    for _, u in ipairs(brain:GetListOfUnits(CatEngineer, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 and not u.DualGapAssigned then
            if not u.DGSeen then
                u.DGSeen = true
                if Utils.TechOf(u) == 1 and ctx.t1Seen < table.getn(BO.T1Engineers) then
                    ctx.t1Seen = ctx.t1Seen + 1
                    u.DGRole = BO.T1Engineers[ctx.t1Seen]
                    u.DGRoleUntil = GetGameTimeSeconds() + Config.ReclaimRoleSeconds
                end
            end
            local task = u.DGRole and RoleTasks[u.DGRole]
            if task then
                task(brain, ctx, u)
            elseif u:IsIdleState() then
                GeneralTask(brain, ctx, u, false)
            end
        end
    end

    -- The ACU joins the base builders after its opening when its role keeps
    -- it home (AIR / ECO), or when it was sent home to build (LANDBUILD).
    local acu = Utils.Commander(brain)
    if acu and ctx.acuBODone and Utils.IsIdle(acu)
        and (ctx.role == 'AIR' or ctx.role == 'ECO' or ctx.acuState == 'LANDBUILD') then
        GeneralTask(brain, ctx, acu, true)
    end
end

function Start(brain, ctx)
    PrepareSteps()
    ctx.acuStep = 1
    ctx.t1Seen = 0
    ForkThread(Utils.RunLoop, 'ACUOpening', brain, ctx, 1, ACUOpeningStep)
    ForkThread(Utils.RunLoop, 'Engineers', brain, ctx, 2, EngineersStep)
end
