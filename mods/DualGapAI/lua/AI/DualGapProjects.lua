-- Big builds done by an engineer crew: experimentals, ECO's game ender, the
-- team anti-nuke, shields against artillery, the GROUND proxy base.
--
-- A project: { name, key (UnitIds key), site (or sites, one per item),
-- crewMax, count (nil = repeat forever), gap, priority, built, crew = {},
-- lead, unit }. Idle engineers are offered to projects first, lowest
-- priority number first (DualGapEngineers.GeneralTask -> Offer). One
-- engineer that can build it starts the structure; the rest repair it.
--
-- The planner (every 10 s) decides which projects exist:
--   team    one anti-nuke per group of three spawns (ECO > NAVAL > AIR >
--           GROUND builds it) as soon as an enemy nuke is scouted or the
--           builder has its first T3 power generator; a second one once
--           2+ enemy nukes are scouted. Priority 1: nothing starves it.
--   team    enemy T3/T4 artillery scouted -> T3 shields over each base
--   GROUND  after the first T2 factory: proxy base (T2 shields + T2 arty)
--   all     after the first T2 factory: T2 point defences on the
--           enemy-facing half circle around the base
--   ECO     strategic phase -> one random game ender, built over and over
--   AIR     >= Config.AirT4MinFighters T3 fighters -> air experimental
--   GROUND  own mid zone pushed, or enemy experimental scouted -> land T4
--   NAVAL   water pushed, or enemy experimental scouted -> naval T4
--
-- Artillery we own (T2 proxy artillery, T3 and T4 artillery) picks targets
-- by priority, see ArtilleryScore.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local BO = import('/mods/DualGapAI/lua/AI/DualGapBuildOrders.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local Alive = Utils.Alive

local CatEngineer = categories.ENGINEER - categories.COMMAND - categories.SUBCOMMANDER

local function OtherSide(side)
    if side == 'LEFT' then return 'RIGHT' end
    return 'LEFT'
end

---------------------------------------------------------------------------
-- Project bookkeeping
---------------------------------------------------------------------------
function Find(ctx, name)
    for _, p in ipairs(ctx.projects or {}) do
        if p.name == name then return p end
    end
    return nil
end

function Add(brain, ctx, spec)
    if Find(ctx, spec.name) then return Find(ctx, spec.name) end
    spec.id = spec.id or Utils.FactionId(brain, spec.key)
    if not spec.id or not __blueprints[spec.id] then return nil end
    spec.crew = {}
    spec.built = 0
    spec.crewMax = spec.crewMax or 6
    spec.priority = spec.priority or 5
    if spec.sites then spec.site = spec.sites[1] end
    -- Keep the list sorted by priority (stable: equal ones keep their order).
    local at = table.getn(ctx.projects) + 1
    for i, q in ipairs(ctx.projects) do
        if spec.priority < q.priority then at = i; break end
    end
    table.insert(ctx.projects, at, spec)
    Utils.Log(brain, 'project ' .. spec.name .. ' (' .. spec.id .. ')')
    return spec
end

local function Release(p)
    for _, u in ipairs(p.crew) do
        if Alive(u) then u.DualGapAssigned = nil end
    end
    p.crew = {}
end

local function Remove(ctx, p)
    Release(p)
    for i, q in ipairs(ctx.projects) do
        if q == p then table.remove(ctx.projects, i); return end
    end
end

local function CrewWanted(brain, p)
    if p.share then
        local total = Utils.Count(brain:GetListOfUnits(CatEngineer, false))
        return math.max(1, math.floor(total * p.share))
    end
    return p.crewMax
end

-- Offer an idle engineer to the projects. Returns true if it was taken.
function Offer(brain, ctx, u)
    for _, p in ipairs(ctx.projects or {}) do
        p.crew = Utils.FilterAlive(p.crew)
        if Utils.Count(p.crew) < CrewWanted(brain, p)
            and Utils.TechOf(u) >= (p.minCrewTech or 1) then
            u.DualGapAssigned = true
            table.insert(p.crew, u)
            return true
        end
    end
    return false
end

-- Let a unit outside the crew (the ACU) help a project this tick.
function HelpWith(brain, ctx, u, names)
    for _, name in ipairs(names) do
        local p = Find(ctx, name)
        if p then
            if Alive(p.unit) and p.unit:GetFractionComplete() < 1 then
                IssueRepair({ u }, p.unit)
                return true
            end
            if not Alive(p.lead) and u:CanBuild(p.id)
                and Utils.BuildNear(brain, u, p.id, p.site, 40, p.gap) then
                p.lead, p.startedAt = u, GetGameTimeSeconds()
                return true
            end
        end
    end
    return false
end

local function ProjectTick(brain, ctx, p)
    p.crew = Utils.FilterAlive(p.crew)
    local now = GetGameTimeSeconds()

    -- Track the structure / unit being built at the site.
    if not Alive(p.unit) and p.startedAt then
        for _, x in ipairs(brain:GetUnitsAroundPoint(categories[p.id], p.site, 60, 'Ally') or {}) do
            if Alive(x) and x:GetAIBrain() == brain and x:GetFractionComplete() < 1 then p.unit = x; break end
        end
    end

    if Alive(p.unit) and p.unit:GetFractionComplete() >= 1 then
        p.built = p.built + 1
        Utils.Log(brain, 'project ' .. p.name .. ' finished #' .. p.built)
        p.unit, p.lead, p.startedAt = nil, nil, nil
        if p.count and p.built >= p.count then Remove(ctx, p); return end
        if p.sites then p.site = p.sites[p.built + 1] or p.sites[table.getn(p.sites)] end
    end

    -- Lost the lead before anything appeared: start over.
    if p.startedAt and not Alive(p.unit) and (not Alive(p.lead) or p.lead:IsIdleState())
        and now - p.startedAt > 20 then
        p.lead, p.startedAt = nil, nil
    end

    if not p.startedAt then
        for _, u in ipairs(p.crew) do
            if u:CanBuild(p.id) and Utils.BuildNear(brain, u, p.id, p.site, 60, p.gap) then
                p.lead, p.startedAt = u, now
                break
            end
        end
        if not p.startedAt then return end
    end

    for _, u in ipairs(p.crew) do
        if u ~= p.lead and u:IsIdleState() then
            if Alive(p.unit) then IssueRepair({ u }, p.unit)
            elseif Alive(p.lead) then IssueGuard({ u }, p.lead) end
        end
    end
end

---------------------------------------------------------------------------
-- Sites
---------------------------------------------------------------------------
-- The map's 'Protected Experimental Construction' marker next to the base.
local function T4Site(ctx)
    if ctx.t4Site then return ctx.t4Site end
    local best, bestD
    for _, m in pairs(ScenarioUtils.GetMarkers() or {}) do
        if m.type == 'Protected Experimental Construction' and m.position then
            local d = Utils.Dist2D(m.position, ctx.startPos)
            if d <= 70 and (not bestD or d < bestD) then best, bestD = m.position, d end
        end
    end
    local dir = (ctx.side == 'LEFT') and -1 or 1
    ctx.t4Site = best or { ctx.startPos[1] + dir * 25, ctx.startPos[2], ctx.startPos[3] }
    return ctx.t4Site
end

local function NavalT4Site(brain, ctx, id)
    -- Ships need water; amphibious experimentals are built on land.
    local bp = __blueprints[id]
    local naval = bp and bp.CategoriesHash and bp.CategoriesHash.NAVAL
    if naval then
        local hint = Routes.GetPoint('NavalRally', ctx.side)
        return Utils.FindNearestWater(ctx.yardPos or hint, Config.DeepWaterDepth, 200) or hint
    end
    return T4Site(ctx)
end

---------------------------------------------------------------------------
-- Triggers
---------------------------------------------------------------------------
local CatT3Fighter = categories.AIR * categories.MOBILE * categories.ANTIAIR * categories.TECH3
    - categories.BOMBER - categories.GROUNDATTACK
local CatEnemyZone = categories.STRUCTURE * (categories.DEFENSE + categories.MASSEXTRACTION + categories.FACTORY)

-- Own units hold the mirrored zone and no known enemy structures remain.
local function Pushed(brain, ctx, point, ownCat)
    local army = brain:GetArmyIndex()
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatEnemyZone, point, Config.PushCheckRadius, 'Enemy') or {}) do
        if Intel.Known(e, army) then return false end
    end
    local own = 0
    for _, u in ipairs(brain:GetUnitsAroundPoint(ownCat, point, Config.PushCheckRadius, 'Ally') or {}) do
        if Alive(u) and u:GetAIBrain() == brain then own = own + 1 end
    end
    return own >= Config.PushOwnUnits
end

local function UpdatePushState(brain, ctx)
    local enemy = OtherSide(ctx.side)
    if ctx.role == 'GROUND' then
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        local was = ctx.midPushed
        ctx.midPushed = Pushed(brain, ctx, Routes.GetPoint(zone, enemy), categories.LAND * categories.MOBILE)
        if ctx.midPushed and not was then Utils.Log(brain, 'mid pushed') end
    elseif ctx.role == 'NAVAL' then
        local was = ctx.waterPushed
        ctx.waterPushed = Pushed(brain, ctx, Routes.GetPoint('NavalRally', enemy), categories.NAVAL * categories.MOBILE)
        if ctx.waterPushed and not was then Utils.Log(brain, 'water pushed') end
    end
end

-- Exposed for tests: should this role start its experimental?
function T4Trigger(role, fighters, midPushed, waterPushed, enemyT4)
    if role == 'AIR' then return fighters >= Config.AirT4MinFighters end
    if role == 'GROUND' then return midPushed or enemyT4 end
    if role == 'NAVAL' then return waterPushed or enemyT4 end
    return false
end

-- Exposed for tests: pick ECO's game ender from the keys the faction has.
function PickGameEnder(available, roll)
    local n = table.getn(available)
    if n == 0 then return nil end
    return available[roll(1, n)]
end

local function Roll(a, b)
    if Random then return Random(a, b) end
    return math.random(a, b)
end

local function HasT3Engineer(brain)
    return Utils.Count(brain:GetListOfUnits(CatEngineer * categories.TECH3, false)) > 0
end

---------------------------------------------------------------------------
-- Team anti-nuke: one SMD (range 90) per group of three spawns, placed at
-- the group's centre, which every base of the group is within reach of.
---------------------------------------------------------------------------
local RolePreference = { ECO = 1, NAVAL = 2, AIR = 3, GROUND = 4 }

function GroupOf(rank)
    if rank <= 3 then return 'TOP' end
    return 'BOTTOM'
end

local function GroupInfo(side, group)
    local members, cx, cz, n = {}, 0, 0, 0
    for name, s in pairs(RoleManager.GetSlots()) do
        if s.side == side and GroupOf(s.rank) == group then
            table.insert(members, { name = name, role = s.role })
            cx, cz, n = cx + s.pos[1], cz + s.pos[3], n + 1
        end
    end
    if n == 0 then return nil end
    return members, { cx / n, GetSurfaceHeight(cx / n, cz / n), cz / n }
end

-- Is this brain the group's anti-nuke builder (best-ranked living DualGap member)?
local function IsGroupBuilder(brain, members)
    local best, bestPref
    for _, m in ipairs(members) do
        for _, b in ipairs(ArmyBrains) do
            if b.Name == m.name and b.DualGap and not Utils.BrainDefeated(b) then
                local pref = RolePreference[m.role] or 9
                if not bestPref or pref < bestPref then best, bestPref = b, pref end
            end
        end
    end
    return best == brain
end

local CatPowerT3 = categories.ENERGYPRODUCTION * categories.TECH3 * categories.STRUCTURE

local function HasT3Power(brain)
    for _, u in ipairs(brain:GetListOfUnits(CatPowerT3, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then return true end
    end
    return false
end

-- Exposed for tests: does the group want an anti-nuke now, and how many?
function AntiNukeWanted(enemyNukes, hasT3Power)
    if enemyNukes >= 2 then return 2 end
    if enemyNukes > 0 or hasT3Power then return 1 end
    return 0
end

local function PlanAntiNuke(brain, ctx)
    local slot = RoleManager.GetSlots()[brain.Name]
    if not slot then return end
    local members, center = GroupInfo(ctx.side, GroupOf(slot.rank))
    if not members or not IsGroupBuilder(brain, members) then return end
    local nukes = table.getn(Intel.Enders(ctx.side, 'NUKE'))
    local want = AntiNukeWanted(nukes, HasT3Power(brain))
    if want == 0 or not HasT3Engineer(brain) then return end
    local have = Utils.CountAround(brain, categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE,
        center, 40, 'Ally')
    if have < want and not Find(ctx, 'AntiNuke') then
        local p = Add(brain, ctx, { name = 'AntiNuke', key = 'AntiNuke', site = center, crewMax = 4,
            count = want - have, minCrewTech = 2, priority = 1 })
        if p then
            local why = (nukes > 0) and 'enemy nuke scouted' or 'T3 power is up'
            Comms.Say(brain, ctx.side, 'antinuke:' .. GroupOf(slot.rank), 'Building anti-nuke here (' .. why .. ').',
                center, 'move')
        end
    end
end

local function PlanShields(brain, ctx)
    if ctx.role == 'GROUND' then return end
    local arty = table.getn(Intel.Enders(ctx.side, 'ARTY'))
    if arty == 0 or not HasT3Engineer(brain) or Find(ctx, 'BaseShield') then return end
    local have = Utils.CountAround(brain, categories.SHIELD * categories.STRUCTURE * (categories.TECH3 + categories.TECH2),
        ctx.startPos, 40, 'Ally')
    if have < 2 then
        Add(brain, ctx, { name = 'BaseShield', key = 'ShieldT3', site = ctx.startPos, crewMax = 3,
            count = 2 - have, minCrewTech = 2, gap = 1, priority = 2 })
    end
end

local function PlanProxy(brain, ctx)
    if ctx.role ~= 'GROUND' or not ctx.t2Time or ctx.proxyPlanned then return end
    ctx.proxyPlanned = true
    local name = (ctx.groundArc == 'GroundArcSouth') and 'ProxyLower' or 'ProxyUpper'
    local site = Routes.GetPoint(name, ctx.side)
    ctx.proxy = site
    Add(brain, ctx, { name = 'ProxyShield', key = 'ShieldT2', site = site, crewMax = 3, count = 2,
        minCrewTech = 2, gap = 0, priority = 3 })
    Add(brain, ctx, { name = 'ProxyArty', key = 'ArtilleryT2', site = site, crewMax = 3, count = 3,
        minCrewTech = 2, gap = 0, priority = 3 })
end

-- Exposed for tests: n points on the half circle of radius r around center
-- that faces the enemy (dir = +1: enemy to the +x side, -1: to the -x side).
function DefenseRing(center, r, n, dir)
    local out = {}
    for i = 1, n do
        -- Spread over -70..+70 degrees around the enemy direction.
        local a = (-70 + 140 * (i - 0.5) / n) * math.pi / 180
        table.insert(out, { center[1] + dir * math.cos(a) * r, center[2], center[3] + math.sin(a) * r })
    end
    return out
end

local function PlanBaseDefense(brain, ctx)
    if not ctx.t2Time or ctx.baseDefensePlanned then return end
    ctx.baseDefensePlanned = true
    local dir = (ctx.side == 'LEFT') and 1 or -1
    local sites = DefenseRing(ctx.startPos, Config.BaseDefenseRadius, Config.BaseDefenseCount, dir)
    for _, p in ipairs(sites) do p[2] = GetSurfaceHeight(p[1], p[3]) end
    Add(brain, ctx, { name = 'BaseDefense', key = 'PointDefenseT2', sites = sites, crewMax = 2,
        count = Config.BaseDefenseCount, minCrewTech = 2, gap = 1, priority = 4 })
end

local function PlanExperimentals(brain, ctx)
    local role = ctx.role
    if role == 'ECO' then
        if not ctx.strategic then return end
        if not ctx.enderKey then
            local available = {}
            for _, key in ipairs(BO.GameEnders) do
                if Utils.FactionId(brain, key) then table.insert(available, key) end
            end
            ctx.enderKey = PickGameEnder(available, Roll)
            Utils.Log(brain, 'game ender chosen: ' .. tostring(ctx.enderKey))
        end
        if ctx.enderKey and HasT3Engineer(brain) then
            local behind = T4Site(ctx)
            Add(brain, ctx, { name = 'GameEnder', key = ctx.enderKey, site = behind,
                share = Config.EcoStrategicShare, minCrewTech = 2, priority = 5 })
        end
        return
    end
    local key = BO.Experimental[role]
    if not key or Find(ctx, 'Experimental') or not HasT3Engineer(brain) then return end
    local fighters = Utils.Count(brain:GetListOfUnits(CatT3Fighter, false))
    if T4Trigger(role, fighters, ctx.midPushed, ctx.waterPushed, Intel.EnemyT4Seen(ctx.side)) then
        local id = Utils.FactionId(brain, key)
        local site = (role == 'NAVAL') and NavalT4Site(brain, ctx, id) or T4Site(ctx)
        Add(brain, ctx, { name = 'Experimental', key = key, site = site, crewMax = 8, minCrewTech = 2, priority = 5 })
    end
end

-- ECO strategic phase: needs T2 and a steady income (the engine reports
-- bogus income spikes at game start).
local function UpdateStrategic(brain, ctx)
    if ctx.role ~= 'ECO' or ctx.strategic or not ctx.t2Time then return end
    if brain:GetEconomyIncome('MASS') * 10 >= Config.EcoStrategicMassIncome then
        ctx.strategicSamples = (ctx.strategicSamples or 0) + 1
    else
        ctx.strategicSamples = 0
    end
    if ctx.strategicSamples >= 3 then
        ctx.strategic = true
        Utils.Log(brain, 'entering strategic phase')
    end
end

---------------------------------------------------------------------------
-- Silos and artillery we own: load missiles, fire at scouted targets.
--
-- Artillery priorities (ArtilleryScore), highest first:
--   100 enemy game enders: T3/T4 artillery, satellite centre and other
--       experimental structures, nuke launchers
--    80 enemy anti-nuke, but only while we own a nuke launcher (kill the
--       anti-nuke, then the nuke gets through)
--    60 enemy ACU, if it is in sight, not underwater and not under a shield
--    40 mexes, power, mass fabricators
--    20 factories
-- A target under N enemy shields that are up is worth score / (1 + 2N):
-- the guns hit something unshielded instead of pounding a shield for
-- nothing, and only go for shielded targets when nothing else is in range.
---------------------------------------------------------------------------
local CatOwnSilos = categories.STRUCTURE * (categories.NUKE + categories.ANTIMISSILE * categories.TECH3)
local CatOwnNukes = categories.STRUCTURE * categories.NUKE
local CatOwnArty = categories.STRUCTURE * categories.ARTILLERY * (categories.TECH2 + categories.TECH3 + categories.EXPERIMENTAL)
local CatEnders = categories.STRUCTURE * (categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
    + categories.EXPERIMENTAL + categories.NUKE)
local CatAntiNuke = categories.STRUCTURE * categories.ANTIMISSILE * categories.TECH3
local CatEco = categories.STRUCTURE * (categories.MASSEXTRACTION + categories.ENERGYPRODUCTION + categories.MASSFABRICATION)
local CatTargets = CatEnders + CatAntiNuke + categories.COMMAND + CatEco + categories.STRUCTURE * categories.FACTORY

-- Exposed for tests. kind: 'ENDER' | 'ANTINUKE' | 'ACU' | 'ECO' | 'FACTORY'.
function ArtilleryScore(kind, shields, haveNuke, underwater)
    local base = 0
    if kind == 'ENDER' then base = 100
    elseif kind == 'ANTINUKE' then base = haveNuke and 80 or 0
    elseif kind == 'ACU' then
        if underwater or shields > 0 then return 0 end
        base = 60
    elseif kind == 'ECO' then base = 40
    elseif kind == 'FACTORY' then base = 20 end
    return base / (1 + 2 * shields)
end

local function TargetKind(e)
    if EntityCategoryContains(CatEnders, e) then return 'ENDER' end
    if EntityCategoryContains(CatAntiNuke, e) then return 'ANTINUKE' end
    if EntityCategoryContains(categories.COMMAND, e) then return 'ACU' end
    if EntityCategoryContains(CatEco, e) then return 'ECO' end
    return 'FACTORY'
end

local function OwnsNuke(brain)
    for _, u in ipairs(brain:GetListOfUnits(CatOwnNukes, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then return true end
    end
    return false
end

-- Best target for artillery (shields matter) or a nuke (avoidAntiNuke:
-- skip anything an enemy anti-nuke covers; a nuke ignores shields).
local function BestTarget(brain, ctx, from, range, avoidAntiNuke)
    local army = brain:GetArmyIndex()
    local haveNuke = OwnsNuke(brain)
    local best, bestScore
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatTargets, from, range, 'Enemy') or {}) do
        if Intel.Known(e, army) then
            local p = e:GetPosition()
            local kind = TargetKind(e)
            local score
            if avoidAntiNuke then
                score = 0
                if not Intel.UnderEnemyAntiNuke(ctx.side, p) then
                    score = ArtilleryScore(kind, 0, false, Utils.IsUnderwater(e))
                    if kind == 'ANTINUKE' then score = 0 end
                end
            else
                score = ArtilleryScore(kind, Intel.ShieldsOver(ctx.side, p), haveNuke, Utils.IsUnderwater(e))
            end
            if score > 0 and (not bestScore or score > bestScore) then best, bestScore = e, score end
        end
    end
    return best, bestScore
end

local function WeaponsStep(brain, ctx)
    for _, s in ipairs(brain:GetListOfUnits(CatOwnSilos, false)) do
        if Alive(s) and s:GetFractionComplete() >= 1 and not s.DGAuto then
            s:SetAutoMode(true)
            s.DGAuto = true
        end
        if Alive(s) and EntityCategoryContains(categories.NUKE, s) and s.GetNukeSiloAmmoCount
            and s:GetNukeSiloAmmoCount() > 0 then
            local t = BestTarget(brain, ctx, s:GetPosition(), 4000, true)
            if t then
                Utils.Log(brain, 'nuke launched')
                IssueNuke({ s }, t:GetPosition())
            end
        end
    end
    -- Artillery re-picks every planner tick: a better target (an ACU walking
    -- into range, a shield going down) takes over from the current one.
    for _, a in ipairs(brain:GetListOfUnits(CatOwnArty, false)) do
        if Alive(a) and a:GetFractionComplete() >= 1 then
            local range = 4000
            local w = a:GetBlueprint().Weapon
            if w and w[1] and w[1].MaxRadius then range = w[1].MaxRadius end
            local t, score = BestTarget(brain, ctx, a:GetPosition(), range, false)
            local current = Alive(a.DGTarget) and a.DGTarget or nil
            if t and t ~= current and (not current or a:IsIdleState() or score > (a.DGScore or 0)) then
                IssueClearCommands({ a })
                IssueAttack({ a }, t)
                a.DGTarget, a.DGScore = t, score
            elseif not t and current then
                a.DGTarget, a.DGScore = nil, nil
            end
        end
    end
end

---------------------------------------------------------------------------
-- Shields climb their upgrade chain (Cybran's ED1 -> ED5 is the only way
-- to a heavy shield), one at a time, when the economy allows.
local function UpgradeShields(brain, ctx)
    if brain:GetEconomyStoredRatio('MASS') < 0.3 or brain:GetEconomyStoredRatio('ENERGY') < 0.6 then return end
    local cat = categories.SHIELD * categories.STRUCTURE
    for _, s in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(s) and s:IsUnitState('Upgrading') then return end
    end
    for _, s in ipairs(brain:GetListOfUnits(cat, false)) do
        local to = Alive(s) and s:GetFractionComplete() >= 1 and s:GetBlueprint().General.UpgradesTo
        if to and to ~= '' and s:IsIdleState() then
            IssueUpgrade({ s }, to)
            return
        end
    end
end

local function PlannerStep(brain, ctx)
    UpdateStrategic(brain, ctx)
    UpdatePushState(brain, ctx)
    PlanProxy(brain, ctx)
    PlanBaseDefense(brain, ctx)
    PlanAntiNuke(brain, ctx)
    PlanShields(brain, ctx)
    PlanExperimentals(brain, ctx)
    WeaponsStep(brain, ctx)
    UpgradeShields(brain, ctx)
end

local function ProjectsStep(brain, ctx)
    -- Iterate a copy: finished projects remove themselves.
    local list = {}
    for _, p in ipairs(ctx.projects) do table.insert(list, p) end
    for _, p in ipairs(list) do ProjectTick(brain, ctx, p) end
end

function Start(brain, ctx)
    ctx.projects = {}
    ForkThread(Utils.RunLoop, 'Planner', brain, ctx, 10, PlannerStep)
    ForkThread(Utils.RunLoop, 'Projects', brain, ctx, 3, ProjectsStep)
end
