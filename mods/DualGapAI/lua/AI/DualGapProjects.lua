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
--   team    one anti-nuke per group of three spawns (started by the member
--           with the most resources, the others assist) as soon as an enemy
--           nuke is scouted or the group has T3 power; a second one once
--           2+ enemy nukes are scouted. Priority 1: nothing starves it.
--   all     enemy Yolona Oss scouted -> Config.YolonaAntiNukes anti-nukes
--           at every base (engineers also assist them, DualGapEngineers)
--   all     a radar at every base (T1 -> T2 -> Omni with tech), a forward
--           radar behind the GROUND mid point, a sonar at the NAVAL yard;
--           lost ones are rebuilt
--   all     torpedo launchers on the water by the base, if there is water
--   GROUND  the defence moves with the front: a forward line at the enemy
--           mid point once the mid is pushed, then a siege camp (shields,
--           T2 artillery, AA) near the enemy base
--   NAVAL   torpedo launchers at the enemy naval rally once water is pushed
--   all     shields over the base core: two T2 shields at T2, a ring of
--           heavy shields at T3, a bigger ring once enemy T3/T4 artillery
--           is scouted (Config.BaseShields); lost ones are rebuilt
--   GROUND  after the first T2 factory: proxy base (T2 shields + T2 arty)
--   GROUND / NAVAL after the first T2 factory: forward factories near the
--           front (Config.ForwardFactories)
--   AIR     anti-air around every base of its group: one T1 AA from the
--           start, three T2 flak at T2, a full ring of T3 SAMs at T3
--           (Config.BaseAA); lost ones are rebuilt. Its heir takes over.
--   all     team down in players -> a ring of T2 point defences
--   ECO     strategic phase -> a random game ender plan built step by step
--           (BuildOrders.EnderPlans: usually one nuke first, then artillery)
--   AIR     >= Config.AirT4MinFighters T3 fighters -> air experimental
--   GROUND  own mid zone pushed, or enemy experimental scouted -> land T4
--   NAVAL   water pushed, or enemy experimental scouted -> naval T4
--
-- Artillery we own (T2 proxy artillery, T3 and T4 artillery) and Novax
-- satellites pick targets by priority, see ArtilleryScore.

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

local OtherSide = Utils.OtherSide

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
    local retry = ctx.projectRetry and ctx.projectRetry[spec.name]
    if retry and GetGameTimeSeconds() < retry then return nil end
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
        if Alive(u) then
            u.DualGapAssigned = nil
            -- A crew member guarding the lead or repairing would never go idle.
            if u ~= p.lead or not Alive(p.unit) then IssueClearCommands({ u }) end
        end
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
    if p.throttle and p.throttle(brain) then return 1 end
    if p.share then
        local total = Utils.Count(brain:GetListOfUnits(CatEngineer, false))
        return math.max(1, math.floor(total * p.share))
    end
    return p.crewMax
end

-- Offer an idle engineer to the projects. Returns true if it was taken.
-- maxPriority: only projects at least this urgent (nil = all). Projects
-- below the top priority share at most Config.ProjectCrewShare of the
-- engineers, so mexes, power and factories always have hands.
function Offer(brain, ctx, u, maxPriority)
    local held = 0
    for _, p in ipairs(ctx.projects or {}) do
        p.crew = Utils.FilterAlive(p.crew)
        if p.priority > 1 then held = held + Utils.Count(p.crew) end
    end
    local total = Utils.Count(brain:GetListOfUnits(CatEngineer, false))
    for _, p in ipairs(ctx.projects or {}) do
        local capped = p.priority > 1 and held >= math.max(1, math.floor(total * Config.ProjectCrewShare))
        if (not maxPriority or p.priority <= maxPriority) and not capped
            and Utils.Count(p.crew) < CrewWanted(brain, p)
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

function SiteKey(pos)
    return math.floor(pos[1]) .. ':' .. math.floor(pos[3])
end

-- Anchors for a game ender: own game enders and T3 generators near the base.
local CatEnderAnchor = categories.STRUCTURE * (categories.NUKE + categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
    + categories.EXPERIMENTAL)
-- p.adjacent = true: anywhere in the base; a number: within that of the
-- project's site (a shield of the ring still covers its part of the base,
-- but stands against a generator or factory there).
local CatShieldAnchor = categories.STRUCTURE * (categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3)
    + categories.FACTORY + categories.NUKE + categories.ARTILLERY * categories.TECH3 + categories.GATE)
local function AdjacentAnchors(brain, ctx, p)
    local out = {}
    local near = type(p.adjacent) == 'number' and p.adjacent
    local cats = near and { CatShieldAnchor }
        or { CatEnderAnchor, categories.ENERGYPRODUCTION * categories.TECH3 * categories.STRUCTURE }
    for _, cat in ipairs(cats) do
        for _, u in ipairs(brain:GetListOfUnits(cat, false)) do
            if Alive(u) and u:GetFractionComplete() >= 1 then
                local d = near and Utils.Dist2D(u:GetPosition(), p.site) or Utils.Dist2D(u:GetPosition(), ctx.startPos)
                if d < (near or 100) then table.insert(out, u) end
            end
        end
    end
    return out
end

local function ProjectTick(brain, ctx, p)
    p.crew = Utils.FilterAlive(p.crew)
    local now = GetGameTimeSeconds()
    -- More hands than wanted (a throttled experimental): the extra ones go
    -- back to work instead of standing in the crew.
    local extra = table.getn(p.crew) - CrewWanted(brain, p)
    if extra > 0 then
        local keep = {}
        for i = table.getn(p.crew), 1, -1 do
            local u = p.crew[i]
            if extra > 0 and u ~= p.lead then
                extra = extra - 1
                u.DualGapAssigned = nil
                IssueClearCommands({ u })
            else
                table.insert(keep, 1, u)
            end
        end
        p.crew = keep
    end

    -- Track the structure / unit being built at the site.
    if not Alive(p.unit) and p.startedAt then
        for _, x in ipairs(brain:GetUnitsAroundPoint(categories[p.id], p.site, 60, 'Ally') or {}) do
            if Alive(x) and x:GetAIBrain() == brain and x:GetFractionComplete() < 1 then p.unit = x; break end
        end
    end

    if Alive(p.unit) and p.unit:GetFractionComplete() >= 1 then
        p.built = p.built + 1
        if p.name == 'GameEnder' then
            ctx.enderBuilt = ctx.enderBuilt or {}
            ctx.enderBuilt[p.key] = (ctx.enderBuilt[p.key] or 0) + 1
        end
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

    -- Realistic building: wait (crew assists other builds meanwhile) while
    -- too much is under construction; the top priority always may start.
    if not p.startedAt and p.priority > 1 and not Utils.CanStartBuild(brain, p.id) then
        for _, u in ipairs(p.crew) do
            if u:IsIdleState() then
                for _, x in ipairs(brain:GetListOfUnits(categories.STRUCTURE, false)) do
                    if Alive(x) and x:GetFractionComplete() < 1 then IssueRepair({ u }, x); break end
                end
            end
        end
        return
    end

    if not p.startedAt then
        local tried = false
        -- Game enders go against the power block or another game ender, as
        -- in a player's base (their power then wraps around them).
        local adj = p.adjacent and Utils.AdjacentSpot(brain, p.id, AdjacentAnchors(brain, ctx, p))
        for _, u in ipairs(p.crew) do
            if u:CanBuild(p.id) then
                tried = true
                if adj then
                    IssueBuildMobile({ u }, adj, p.id, {})
                    p.lead, p.startedAt = u, now
                    break
                end
                if Utils.BuildNear(brain, u, p.id, p.site, p.maxRadius or 60, p.gap) then
                    p.lead, p.startedAt = u, now
                    break
                end
            end
        end
        -- A builder tried and found no spot: give up this site (multi-site
        -- projects move on, the planner won't offer it again).
        if not p.startedAt and tried and not p.sites then
            p.failed = (p.failed or 0) + 1
            if p.failed >= 3 then
                ctx.projectRetry = ctx.projectRetry or {}
                ctx.projectRetry[p.name] = now + Config.ProjectRetrySeconds
                Utils.Log(brain, 'project ' .. p.name .. ' dropped: no spot for it')
                Remove(ctx, p)
                return
            end
        end
        if not p.startedAt and tried and p.sites then
            p.failed = (p.failed or 0) + 1
            if p.failed >= 3 then
                p.failed = 0
                ctx.badSites = ctx.badSites or {}
                ctx.badSites[SiteKey(p.site)] = true
                table.remove(p.sites, p.built + 1)
                -- p.sites still lists the points already built, so it is the new upper bound.
                p.count = math.min(p.count or 0, table.getn(p.sites))
                if p.built >= p.count then Remove(ctx, p); return end
                p.site = p.sites[p.built + 1]
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
-- Land experimentals go up in front of the base, toward the choke: built
-- behind it, a Fatboy or Monkeylord can't squeeze through the base blocks.
local function LandT4Site(ctx)
    if not ctx.choke then return nil end
    local d = Utils.Dist2D(ctx.startPos, ctx.choke)
    if d < 1 then return nil end
    local k = math.min(1, Config.LandT4Ahead / d)
    local x = ctx.startPos[1] + (ctx.choke[1] - ctx.startPos[1]) * k
    local z = ctx.startPos[3] + (ctx.choke[3] - ctx.startPos[3]) * k
    return { x, GetSurfaceHeight(x, z), z }
end

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
    if Utils.HasDuty(ctx, 'GROUND') then
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        local was = ctx.midPushed
        ctx.midPushed = Pushed(brain, ctx, Routes.GetPoint(zone, enemy), categories.LAND * categories.MOBILE)
        if ctx.midPushed and not was then Utils.Log(brain, 'mid pushed') end
    end
    if Utils.HasDuty(ctx, 'NAVAL') then
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

-- Living DualGap brains of a group.
local function GroupBrains(members)
    local out = {}
    for _, m in ipairs(members) do
        for _, b in ipairs(ArmyBrains) do
            if b.Name == m.name and b.DualGap and not Utils.BrainDefeated(b) then
                table.insert(out, { brain = b, role = m.role })
            end
        end
    end
    return out
end

-- Exposed for tests: the member to start the group's anti-nuke - the one
-- with the most resources right now (mass stored + half a minute of
-- income); ties go to the role order ECO, NAVAL, AIR, GROUND.
-- list: { {name, stored, income (per second), role, ready (T3 engineer)} }
function PickAntiNukeBuilder(list)
    local best, bestScore, bestPref
    for _, m in ipairs(list) do
        if m.ready then
            local score = m.stored + 30 * m.income
            local pref = RolePreference[m.role] or 9
            if not bestScore or score > bestScore or (score == bestScore and pref < bestPref) then
                best, bestScore, bestPref = m.name, score, pref
            end
        end
    end
    return best
end

-- Is this brain the group's anti-nuke builder? The pick holds for
-- Config.AntiNukePickSeconds, so two members don't both start one.
local groupBuilder = {}
local function IsGroupBuilder(brain, members, key)
    local now = GetGameTimeSeconds()
    local rec = groupBuilder[key]
    local living = GroupBrains(members)
    if rec and now - rec.at < Config.AntiNukePickSeconds then
        for _, m in ipairs(living) do
            if m.brain.Name == rec.name then return rec.name == brain.Name end
        end
    end
    local list = {}
    for _, m in ipairs(living) do
        local b = m.brain
        table.insert(list, { name = b.Name, role = m.role, stored = b:GetEconomyStored('MASS'),
            income = b:GetEconomyIncome('MASS') * 10,
            ready = Utils.Count(b:GetListOfUnits(CatEngineer * categories.TECH3, false)) > 0 })
    end
    local name = PickAntiNukeBuilder(list)
    if not name then return false end
    groupBuilder[key] = { name = name, at = now }
    return name == brain.Name
end

-- The centre of this brain's group of three (where the shared anti-nuke stands).
function GroupCenter(brain, side)
    local slot = RoleManager.GetSlots()[brain.Name]
    if not slot then return nil end
    local _, center = GroupInfo(side, GroupOf(slot.rank))
    return center
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
    if not members then return end
    local nukes = table.getn(Intel.Enders(ctx.side, 'NUKE')) + table.getn(Intel.Enders(ctx.side, 'YOLONA'))
    -- T3 power anywhere in the group counts.
    local t3 = false
    for _, m in ipairs(GroupBrains(members)) do if HasT3Power(m.brain) then t3 = true end end
    local want = AntiNukeWanted(nukes, t3)
    if want == 0 then return end
    local have = Utils.CountAround(brain, categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE,
        center, 40, 'Ally')
    if have >= want or Find(ctx, 'AntiNuke') then return end
    -- One being built already: the others assist it (engineers' task).
    for _, s in ipairs(brain:GetUnitsAroundPoint(categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE,
        center, 40, 'Ally') or {}) do
        if Alive(s) and s:GetFractionComplete() < 1 then return end
    end
    if not HasT3Engineer(brain) or not IsGroupBuilder(brain, members, ctx.side .. GroupOf(slot.rank)) then return end
    local p = Add(brain, ctx, { name = 'AntiNuke', key = 'AntiNuke', site = center, crewMax = 4,
        count = want - have, minCrewTech = 2, priority = 1 })
    if p then
        local why = (nukes > 0) and 'enemy nuke scouted' or 'T3 power is up'
        Comms.Say(brain, ctx.side, 'antinuke:' .. GroupOf(slot.rank), 'Building anti-nuke here (' .. why .. ').',
            center, 'move')
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

-- Exposed for tests: n points evenly on the circle of radius r around
-- center, the first one toward the enemy (dir = +1: enemy to the +x side).
function Ring(center, r, n, dir)
    local out = {}
    for i = 1, n do
        local a = 2 * math.pi * (i - 1) / n
        table.insert(out, { center[1] + dir * math.cos(a) * r, center[2], center[3] + math.sin(a) * r })
    end
    return out
end

local function TopFactoryTech(brain)
    local best = 1
    for _, f in ipairs(brain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false)) do
        if Alive(f) and f:GetFractionComplete() >= 1 and Utils.TechOf(f) > best then best = Utils.TechOf(f) end
    end
    return best
end

-- A ring of structures around the base: plan the points that have nothing
-- of `have` (category) within `near` yet. Used for the first build and for
-- rebuilds alike.
local function PlanRing(brain, ctx, name, key, have, spec, near, minCrewTech, priority, center, adjacent)
    if Find(ctx, name) then return end
    local dir = (ctx.side == 'LEFT') and 1 or -1
    ctx.badSites = ctx.badSites or {}
    local sites = {}
    for _, p in ipairs(Ring(center or ctx.startPos, spec.radius, spec.count, dir)) do
        p[2] = GetSurfaceHeight(p[1], p[3])
        if not ctx.badSites[SiteKey(p)] and Utils.CountAround(brain, have, p, near, 'Ally') == 0 then
            table.insert(sites, p)
        end
    end
    local n = table.getn(sites)
    if n > 0 then
        Add(brain, ctx, { name = name, key = key, sites = sites, count = n, crewMax = 2,
            minCrewTech = minCrewTech, gap = 1, maxRadius = 10, priority = priority, adjacent = adjacent })
    end
end

-- One structure at a point: plan it while nothing of `have` stands within
-- `near` of the point (first build and rebuilds).
local function PlanAt(brain, ctx, name, key, have, pos, near, priority)
    if Find(ctx, name) or not pos then return end
    ctx.badSites = ctx.badSites or {}
    if ctx.badSites[SiteKey(pos)] or Utils.CountAround(brain, have, pos, near, 'Ally') > 0 then return end
    Add(brain, ctx, { name = name, key = key, sites = { pos }, count = 1, crewMax = 1, gap = 1,
        maxRadius = 15, priority = priority })
end

local CatRadar = (categories.RADAR + categories.OMNI) * categories.STRUCTURE
local CatSonar = categories.SONAR * categories.STRUCTURE

local function PlanIntelStructures(brain, ctx)
    local dir = (ctx.side == 'LEFT') and 1 or -1
    PlanRing(brain, ctx, 'BaseRadar', 'RadarT1', CatRadar, { count = 1, radius = Config.BaseRadarRadius }, 15, 1, 4)
    if ctx.role == 'GROUND' and ctx.acuBODone and ctx.choke then
        local c = ctx.choke
        local x = c[1] - dir * Config.MidRadarBack
        PlanAt(brain, ctx, 'MidRadar', 'RadarT1', CatRadar, { x, GetSurfaceHeight(x, c[3]), c[3] }, 20, 4)
    end
    if ctx.role == 'NAVAL' and ctx.yardPos then
        PlanAt(brain, ctx, 'Sonar', 'SonarT1', CatSonar, ctx.yardPos, 40, 4)
    end
end

-- Exposed for tests: should this intel structure upgrade now?
-- kind 'RADAR' (T1 -> T2 at tech 2, T2 -> Omni at tech 3) or 'SONAR'
-- (T1 -> T2 at tech 2, no further).
function IntelUpgradeWanted(kind, ownTech, topTech)
    if kind == 'SONAR' then return ownTech == 1 and topTech >= 2 end
    return ownTech < topTech and ownTech < 3
end

-- One intel upgrade at a time, when the economy allows.
local function UpgradeIntel(brain, ctx)
    if brain:GetEconomyStoredRatio('MASS') < 0.2 or brain:GetEconomyStoredRatio('ENERGY') < 0.5 then return end
    local cat = CatRadar + CatSonar
    for _, s in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(s) and s:IsUnitState('Upgrading') then return end
    end
    local top = TopFactoryTech(brain)
    for _, s in ipairs(brain:GetListOfUnits(cat, false)) do
        local to = Alive(s) and s:GetFractionComplete() >= 1 and s:GetBlueprint().General.UpgradesTo
        local kind = EntityCategoryContains(CatSonar, s) and 'SONAR' or 'RADAR'
        if to and to ~= '' and __blueprints[to] and s:IsIdleState()
            and IntelUpgradeWanted(kind, Utils.TechOf(s), top) then
            IssueUpgrade({ s }, to)
            return
        end
    end
end

-- Exposed for tests: who keeps the group's base AA - the AIR player while
-- it is in the game (bot or human: a human builds it himself), after it the
-- ally that took over its mexes, and so on down the line.
function AAKeeperName(airName, alive, heir)
    local n = airName
    for i = 1, 6 do
        if not n then return nil end
        if alive(n) then return n end
        n = heir(n)
    end
    return nil
end

-- Exposed for tests: the bases whose AA ring the keeper builds - its own
-- first, then the other living bases of the group.
-- bases: { {name, pos} } of the group's living players, own: this player's name.
function AABases(isKeeper, own, bases)
    local out = {}
    if isKeeper then
        for _, b in ipairs(bases) do if b.name == own then table.insert(out, b) end end
        for _, b in ipairs(bases) do if b.name ~= own then table.insert(out, b) end end
    end
    return out
end

-- Exposed for tests: fortify? (own team has fewer players in the game)
function ShouldFortify(ownAlive, enemyAlive)
    return ownAlive < enemyAlive
end

-- A team down in players: a ring of T2 point defences around the base.
local function PlanFortify(brain, ctx)
    if TopFactoryTech(brain) < 2 then return end
    local me = brain:GetArmyIndex()
    local own, enemy = 0, 0
    for i, b in ipairs(ArmyBrains) do
        if not Utils.BrainDefeated(b) and not (ArmyIsCivilian and ArmyIsCivilian(i)) then
            if IsAlly(me, i) then own = own + 1 elseif IsEnemy(me, i) then enemy = enemy + 1 end
        end
    end
    if not ShouldFortify(own, enemy) then return end
    if not ctx.fortifySaid then
        ctx.fortifySaid = true
        Utils.Log(brain, 'team down in players (' .. own .. ' vs ' .. enemy .. '): fortifying the base')
    end
    PlanRing(brain, ctx, 'Fortify', 'PointDefenseT2', categories.STRUCTURE * categories.DIRECTFIRE * categories.TECH2,
        { count = Config.FortifyPD, radius = Config.FortifyRadius }, 8, 2, 3)
end

-- Anti-air rings per tech tier.
local function PlanBaseAA(brain, ctx)
    local tech = TopFactoryTech(brain)
    local slot = RoleManager.GetSlots()[brain.Name]
    if not slot then return end
    local members = GroupInfo(ctx.side, GroupOf(slot.rank))
    if not members then return end
    local airName
    for _, m in ipairs(members) do if m.role == 'AIR' then airName = m.name end end
    local Mex = import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua')
    local keeper = AAKeeperName(airName, Mex.InGame, Mex.Heir)
    if keeper ~= brain.Name then return end
    if ctx.role ~= 'AIR' and not ctx.aaKeeperSaid then
        ctx.aaKeeperSaid = true
        Comms.Say(brain, ctx.side, 'aakeeper:' .. brain.Name, 'Our AIR is gone, I take over the base anti-air.', ctx.startPos, 'move')
    end
    local bases = { { name = brain.Name, pos = ctx.startPos } }
    local slots = RoleManager.GetSlots()
    for _, m in ipairs(members) do
        if m.name ~= brain.Name and slots[m.name] and Mex.InGame(m.name) then
            table.insert(bases, { name = m.name, pos = slots[m.name].pos })
        end
    end
    for i, b in ipairs(AABases(true, brain.Name, bases)) do
        for t = 1, 3 do
            local spec = ((i > 1) and Config.BaseAAAlly or Config.BaseAA)[t]
            if spec and tech >= t then
                local name = 'BaseAA' .. t .. ((i > 1) and (':' .. b.name) or '')
                PlanRing(brain, ctx, name, 'AntiAirT' .. t,
                    categories.ANTIAIR * categories.STRUCTURE * categories['TECH' .. t], spec, 12, t, 4, b.pos)
            end
        end
    end
end

-- Exposed for tests: the shield rings a base wants at this tech.
function ShieldPlan(tech, enemyArty)
    local out = {}
    if tech >= 2 then table.insert(out, { tier = 2, spec = Config.BaseShields[2] }) end
    if tech >= 3 then
        table.insert(out, { tier = 3, spec = (enemyArty and Config.BaseShieldsVsArty) or Config.BaseShields[3] })
    end
    return out
end

-- Yolona Oss fires nukes one after another: every base needs a stack of
-- anti-nukes of its own (on top of the shared group one).
local function PlanYolonaDefense(brain, ctx)
    if table.getn(Intel.Enders(ctx.side, 'YOLONA')) == 0 or not HasT3Engineer(brain) then return end
    if Find(ctx, 'AntiNukeBase') then return end
    local have = Utils.CountAround(brain, categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE,
        ctx.startPos, 60, 'Ally')
    if have < Config.YolonaAntiNukes then
        local p = Add(brain, ctx, { name = 'AntiNukeBase', key = 'AntiNuke', site = ctx.startPos, crewMax = 8,
            count = Config.YolonaAntiNukes - have, minCrewTech = 2, gap = 1, priority = 1 })
        if p then
            Comms.Say(brain, ctx.side, 'yolona:' .. brain.Name, 'Enemy Yolona Oss! Stacking anti-nukes at my base.',
                ctx.startPos, 'alert')
        end
    end
end

-- A cluster of `want` structures of category `have` around `site`: plan
-- what is missing (first build and rebuilds).
local function PlanCluster(brain, ctx, name, key, have, site, want, near, gap, minTech)
    if not site or Find(ctx, name) then return end
    local n = Utils.CountAround(brain, have, site, near, 'Ally')
    if n < want then
        Add(brain, ctx, { name = name, key = key, site = site, count = want - n, crewMax = 3,
            minCrewTech = minTech or 2, gap = gap or 1, maxRadius = near, priority = 3 })
    end
end

local CatPDs = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE
local CatAAs = categories.STRUCTURE * categories.ANTIAIR
local CatShieldsOwn = categories.STRUCTURE * categories.SHIELD
local CatArtyT2 = categories.STRUCTURE * categories.ARTILLERY * categories.TECH2
local CatTorps = categories.STRUCTURE * categories.ANTINAVY

local function TorpedoKey(brain)
    if TopFactoryTech(brain) >= 2 then return 'TorpedoT2', 2 end
    return 'TorpedoT1', 1
end

-- Torpedo launchers on the water closest to the base.
local function PlanBaseTorpedoes(brain, ctx)
    if not ctx.t2Time then return end
    if ctx.baseWater == nil then
        ctx.baseWater = Utils.FindNearestWater(ctx.startPos, 2, Config.BaseTorpedoRange) or false
    end
    if not ctx.baseWater then return end
    local key, tech = TorpedoKey(brain)
    PlanCluster(brain, ctx, 'BaseTorpedo', key, CatTorps, ctx.baseWater, Config.BaseTorpedoes, 25, 1, tech)
end

-- Exposed for tests: the siege camp point, `dist` short of the enemy base
-- on the line from the enemy mid point.
function SiegePoint(from, base, dist)
    local dx, dz = from[1] - base[1], from[3] - base[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len <= dist then return { from[1], from[2], from[3] } end
    return { base[1] + dx / len * dist, base[2], base[3] + dz / len * dist }
end

-- The defence follows the front. Stage 1: forward line at the enemy mid
-- point; stage 2: siege camp near the enemy base.
local function PlanFrontline(brain, ctx)
    local now = GetGameTimeSeconds()
    if ctx.role == 'GROUND' and ctx.choke then
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        local enemyMid = Routes.GetPoint(zone, OtherSide(ctx.side))
        if not ctx.frontStage and ctx.midPushed then
            ctx.frontStage, ctx.frontSince, ctx.frontPoint = 1, now, enemyMid
            Utils.Log(brain, 'defence moves to the enemy mid point')
            Comms.Say(brain, ctx.side, 'front1:' .. brain.Name, 'Mid is ours, fortifying their mid point.', enemyMid, 'move')
        end
        if ctx.frontStage == 1 and ctx.enemyGroundBase and now - ctx.frontSince >= Config.SiegeDelay then
            local p = SiegePoint(enemyMid, ctx.enemyGroundBase, Config.SiegeDistance)
            p[2] = GetSurfaceHeight(p[1], p[3])
            ctx.frontStage, ctx.frontSince, ctx.frontPoint = 2, now, p
            Utils.Log(brain, 'siege camp at the enemy base')
            Comms.Say(brain, ctx.side, 'front2:' .. brain.Name, 'Setting up a siege of their base here.', p, 'attack')
        end
        if ctx.frontStage == 1 then
            local s = ctx.frontPoint
            PlanCluster(brain, ctx, 'Front1PD', 'PointDefenseT2', CatPDs, s, 3, 20, 0)
            PlanCluster(brain, ctx, 'Front1AA', 'AntiAirT2', CatAAs, s, 2, 20, 1)
            PlanCluster(brain, ctx, 'Front1Shield', 'ShieldT2', CatShieldsOwn, s, 1, 20, 1)
        elseif ctx.frontStage == 2 then
            local s = ctx.frontPoint
            PlanCluster(brain, ctx, 'SiegeShield', 'ShieldT2', CatShieldsOwn, s, 2, 25, 0)
            PlanCluster(brain, ctx, 'SiegeArty', 'ArtilleryT2', CatArtyT2, s, 4, 25, 0)
            PlanCluster(brain, ctx, 'SiegeAA', 'AntiAirT2', CatAAs, s, 2, 25, 1)
        end
    elseif ctx.role == 'NAVAL' and ctx.waterPushed then
        if not ctx.frontWater then
            ctx.frontWater = Utils.FindNearestWater(Routes.GetPoint('NavalRally', OtherSide(ctx.side)), 2, 60) or false
        end
        if ctx.frontWater then
            local key, tech = TorpedoKey(brain)
            PlanCluster(brain, ctx, 'FrontTorpedo', key, CatTorps, ctx.frontWater, 3, 25, 1, tech)
        end
    end
end

local function PlanBaseShields(brain, ctx)
    local arty = table.getn(Intel.Enders(ctx.side, 'ARTY')) > 0
    for _, s in ipairs(ShieldPlan(TopFactoryTech(brain), arty)) do
        -- T2 points count any shield (an upgraded one is still there),
        -- T3 points want a heavy one.
        -- Cybran builds its heavy shield as ED1 and upgrades it, so there
        -- any shield on the point counts (no endless new ED1s).
        local have = categories.SHIELD * categories.STRUCTURE
        if s.tier == 3 and brain:GetFactionIndex() ~= 3 then have = have * categories.TECH3 end
        if s.tier == 2 or HasT3Engineer(brain) then
            PlanRing(brain, ctx, 'BaseShield' .. s.tier, 'ShieldT' .. s.tier, have, s.spec, 8, 2, 2, nil, 14)
        end
    end
end

local CatT3Land = categories.LAND * categories.MOBILE * categories.TECH3 - categories.ENGINEER - categories.COMMAND
    - categories.SUBCOMMANDER
local CatT3Ships = categories.NAVAL * categories.MOBILE * categories.TECH3

-- Exposed for tests: enough T3 units for one more experimental?
function T4EscortReady(t3, exps)
    return t3 >= Config.T3PerT4 * math.max(1, exps)
end

-- Forward production sites: two points behind the GROUND mid point, or two
-- water points short of the NAVAL rally point.
local function ForwardSites(ctx)
    local dir = (ctx.side == 'LEFT') and 1 or -1
    local out = {}
    if ctx.role == 'GROUND' and ctx.choke then
        local x = ctx.choke[1] - dir * Config.ForwardLandBack
        for _, dz in ipairs({ -12, 12 }) do
            local z = ctx.choke[3] + dz
            table.insert(out, { x, GetSurfaceHeight(x, z), z })
        end
    elseif ctx.role == 'NAVAL' then
        local r = Routes.GetPoint('NavalRally', ctx.side)
        local x = r[1] - dir * Config.ForwardNavalBack
        for _, dz in ipairs({ -15, 15 }) do
            local w = Utils.FindNearestWater({ x, 0, r[3] + dz }, 2, 60)
            if w then table.insert(out, w) end
        end
    end
    return out
end

local function PlanForwardBase(brain, ctx)
    if not ctx.t2Time or Find(ctx, 'ForwardFactory') then return end
    local kind = (ctx.role == 'NAVAL') and 'Naval' or 'Land'
    local id = Utils.FactoryId(brain, kind, 1)
    if not id then return end
    ctx.forwardSites = ctx.forwardSites or ForwardSites(ctx)
    ctx.badSites = ctx.badSites or {}
    local sites = {}
    for i, p in ipairs(ctx.forwardSites) do
        if i <= Config.ForwardFactories and not ctx.badSites[SiteKey(p)]
            and Utils.CountAround(brain, Utils.FactoryCategory(kind), p, 15, 'Ally') == 0 then
            table.insert(sites, p)
        end
    end
    local n = table.getn(sites)
    if n > 0 then
        Add(brain, ctx, { name = 'ForwardFactory', id = id, key = 'Forward' .. kind, sites = sites, count = n,
            crewMax = 3, gap = 2, maxRadius = 20, priority = 3 })
    end
end

-- Exposed for tests: a game ender plan for the keys this faction has
-- (steps it can't build dropped; plans left empty skipped).
function PickEnderPlan(plans, available, roll)
    local have = {}
    for _, k in ipairs(available) do have[k] = true end
    local usable = {}
    for _, plan in ipairs(plans) do
        local steps = {}
        for _, st in ipairs(plan) do
            if have[st[1]] then table.insert(steps, { st[1], st[2] }) end
        end
        if table.getn(steps) > 0 then table.insert(usable, steps) end
    end
    local n = table.getn(usable)
    if n == 0 then return nil end
    return usable[roll(1, n)]
end

-- Exposed for tests: the step of the plan to build now (the first one not
-- yet complete), or nil when the plan is done. count(key) = how many exist.
function EnderStep(plan, count)
    for i, st in ipairs(plan or {}) do
        if count(st[1]) < st[2] then return i, st end
    end
    return nil
end

-- Exposed for tests: how far a plan step counts as done. Units (air T4s):
-- how many were built, dead or alive. Structures: the ones standing, so a
-- destroyed silo or artillery piece is put back up.
function EnderCount(key, alive, built, structure)
    if structure then return alive end
    return math.max(alive, built)
end

local function IsStructureKey(brain, key)
    local id = Utils.FactionId(brain, key)
    local bp = id and __blueprints[id]
    return bp ~= nil and bp.CategoriesHash.STRUCTURE == true
end

-- The game ender: ECO's job, or of whoever took it over from a defeated ECO.
local function PlanGameEnder(brain, ctx)
    if not ctx.strategic then return end
    if not ctx.enderPlan then
        local available = {}
        for _, key in ipairs(BO.GameEnders) do
            if Utils.FactionId(brain, key) then table.insert(available, key) end
        end
        ctx.enderPlan = PickEnderPlan(BO.EnderPlans, available, Roll) or {}
        local names = {}
        for _, st in ipairs(ctx.enderPlan) do table.insert(names, st[2] .. 'x ' .. st[1]) end
        Utils.Log(brain, 'game ender plan: ' .. table.concat(names, ', '))
    end
    -- Nukes keep getting stopped: T3 artillery to knock out the anti-nukes.
    if ctx.wantAntiSMDArty and not Find(ctx, 'AntiSMDArty') and HasT3Engineer(brain)
        and Utils.Count(brain:GetListOfUnits(categories.STRUCTURE * categories.ARTILLERY * categories.TECH3, false)) == 0 then
        Add(brain, ctx, { name = 'AntiSMDArty', key = 'StratArtyT3', site = T4Site(ctx), count = 1, crewMax = 6,
            minCrewTech = 2, priority = 2 })
    end
    -- A step is done once that many were BUILT: shot-down air T4s don't
    -- send the plan back to them over and over - it moves on to the nukes
    -- and artillery. Lost structures of finished steps are rebuilt.
    local function alive(key)
        local id = Utils.FactionId(brain, key)
        return id and Utils.Count(brain:GetListOfUnits(categories[id], false)) or 0
    end
    local function count(key)
        return EnderCount(key, alive(key), (ctx.enderBuilt or {})[key] or 0, IsStructureKey(brain, key))
    end
    local p = Find(ctx, 'GameEnder')
    if p and Alive(p.unit) then return end          -- one in progress: let it finish
    local i, st = EnderStep(ctx.enderPlan, count)
    if p and (not st or p.key ~= st[1]) then Remove(ctx, p); p = nil end
    if not st then
        if not ctx.enderDoneSaid then
            ctx.enderDoneSaid = true
            Utils.Log(brain, 'game ender plan complete')
        end
        return
    end
    if ctx.enderKey ~= st[1] then
        ctx.enderKey = st[1]
        Utils.Log(brain, 'game ender step ' .. i .. ': ' .. st[2] .. 'x ' .. st[1])
    end
    if HasT3Engineer(brain) and not p then
        -- Air T4s are units built from the gantry's site; structures go
        -- against the power block.
        local structure = __blueprints[Utils.FactionId(brain, st[1]) or ''] and
            __blueprints[Utils.FactionId(brain, st[1])].CategoriesHash.STRUCTURE
        Add(brain, ctx, { name = 'GameEnder', key = st[1], site = T4Site(ctx), count = st[2] - count(st[1]),
            share = Config.EcoStrategicShare, minCrewTech = 2, priority = 5, adjacent = structure })
    end
end

local function PlanExperimentals(brain, ctx)
    local role = ctx.role
    if Utils.HasDuty(ctx, 'ECO') then PlanGameEnder(brain, ctx) end
    if role == 'ECO' then return end
    local key = BO.Experimental[role]
    if not key or Find(ctx, 'Experimental') or not HasT3Engineer(brain) then return end
    local fighters = Utils.Count(brain:GetListOfUnits(CatT3Fighter, false))
    if T4Trigger(role, fighters, ctx.midPushed, ctx.waterPushed, Intel.EnemyT4Seen(ctx.side)) then
        local id = Utils.FactionId(brain, key)
        local site = (role == 'NAVAL') and NavalT4Site(brain, ctx, id)
            or (role == 'GROUND' and LandT4Site(ctx)) or T4Site(ctx)
        local cat = (role == 'NAVAL') and CatT3Ships or (role == 'GROUND' and CatT3Land or nil)
        Add(brain, ctx, { name = 'Experimental', key = key, site = site, crewMax = 8, minCrewTech = 2, priority = 5,
            -- Not enough T3 army to go with the T4s yet: one engineer only
            -- (unless mass is piling up - then it is better spent on the T4).
            throttle = cat and function(b)
                if Utils.MassBanked(b) then return false end
                local exps = Utils.Count(b:GetListOfUnits(categories.EXPERIMENTAL * categories.MOBILE, false))
                return not T4EscortReady(Utils.Count(b:GetListOfUnits(cat, false)), exps)
            end })
    end
end

-- ECO strategic phase: needs T2 and a steady income (the engine reports
-- bogus income spikes at game start).
local function UpdateStrategic(brain, ctx)
    if not Utils.HasDuty(ctx, 'ECO') or ctx.strategic or not ctx.t2Time then return end
    -- (A player that took over ECO's role gets there the same way.)
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
--   100 enemy game enders: T3/T4 artillery, nuke launchers and every
--       experimental structure (Mavor, Scathis, Salvation, Yolona Oss,
--       Paragon, Novax satellite centre)
--    80 enemy anti-nuke, but only while we own a nuke launcher (kill the
--       anti-nuke, then the nuke gets through)
--    60 enemy ACU, if it is in sight, not underwater and not under a shield
--    45 T3 mexes, 40 T3 power / fabricators
--    40 / 35 T1-T2 mexes / power - only for the T2 proxy artillery; long
--       range guns (T3/T4 artillery, satellites) don't waste shells on them
--    20 factories
-- A target under N enemy shields that are up is worth score / (1 + 2N):
-- the guns hit something unshielded instead of pounding a shield for
-- nothing, and only go for shielded targets when nothing else is in range.
---------------------------------------------------------------------------
local CatOwnSilos = categories.STRUCTURE * (categories.NUKE + categories.ANTIMISSILE * categories.TECH3)
local CatOwnNukes = categories.STRUCTURE * categories.NUKE
local CatOwnArty = categories.STRUCTURE * categories.ARTILLERY * (categories.TECH2 + categories.TECH3 + categories.EXPERIMENTAL)
local CatOwnSatellite = categories.SATELLITE * categories.MOBILE
local CatEnders = categories.STRUCTURE * (categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
    + categories.EXPERIMENTAL + categories.NUKE)
local CatAntiNuke = categories.STRUCTURE * categories.ANTIMISSILE * categories.TECH3
local CatEco = categories.STRUCTURE * (categories.MASSEXTRACTION + categories.ENERGYPRODUCTION + categories.MASSFABRICATION)
local CatTargets = CatEnders + CatAntiNuke + categories.COMMAND + CatEco + categories.STRUCTURE * categories.FACTORY

-- Exposed for tests. kind: 'ENDER' | 'ANTINUKE' | 'ACU' | 'MEX3' | 'ECO3' |
-- 'MEX' | 'ECO' | 'FACTORY'. longRange: T3/T4 artillery and satellites.
function ArtilleryScore(kind, shields, haveNuke, underwater, longRange)
    local base = 0
    if kind == 'ENDER' then base = 100
    elseif kind == 'ANTINUKE' then base = haveNuke and 80 or 0
    elseif kind == 'ACU' then
        if underwater or shields > 0 then return 0 end
        base = 60
    elseif kind == 'MEX3' then base = 45
    elseif kind == 'ECO3' then base = 40
    elseif kind == 'MEX' then base = longRange and 2 or 40
    elseif kind == 'ECO' then base = longRange and 2 or 35
    elseif kind == 'FACTORY' then base = 20 end
    return base / (1 + 2 * shields)
end

local function TargetKind(e)
    if EntityCategoryContains(CatEnders, e) then return 'ENDER' end
    if EntityCategoryContains(CatAntiNuke, e) then return 'ANTINUKE' end
    if EntityCategoryContains(categories.COMMAND, e) then return 'ACU' end
    if EntityCategoryContains(CatEco, e) then
        local t3 = EntityCategoryContains(categories.TECH3 + categories.EXPERIMENTAL, e)
        if EntityCategoryContains(categories.MASSEXTRACTION, e) then return t3 and 'MEX3' or 'MEX' end
        return t3 and 'ECO3' or 'ECO'
    end
    return 'FACTORY'
end

local function OwnsNuke(brain)
    for _, u in ipairs(brain:GetListOfUnits(CatOwnNukes, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then return true end
    end
    return false
end

-- Best artillery target in range (shields matter).
-- Enemy ECO start positions (their base is the heart of the economy).
local function EnemyEcoBases(ctx)
    -- Whoever holds the enemy ECO role now (its heir once the ECO is out).
    return import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua').DutyPositions(OtherSide(ctx.side), 'ECO')
end

local function NearAny(pos, list, radius)
    for _, p in ipairs(list) do
        if Utils.Dist2D(pos, p) <= radius then return true end
    end
    return false
end

local function BestTarget(brain, ctx, from, range, longRange)
    local army = brain:GetArmyIndex()
    local haveNuke = OwnsNuke(brain)
    -- ECO's long-range guns go for the enemy ECO first.
    local ecoBases = (longRange and Utils.HasDuty(ctx, 'ECO')) and EnemyEcoBases(ctx) or {}
    local best, bestScore
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatTargets, from, range, 'Enemy') or {}) do
        if Intel.Known(e, army) then
            local p = e:GetPosition()
            local score = ArtilleryScore(TargetKind(e), Intel.ShieldsOver(ctx.side, p), haveNuke,
                Utils.IsUnderwater(e), longRange)
            if score > 0 and NearAny(p, ecoBases, 120) then score = score * Config.EcoVsEcoBonus end
            if score > 0 and (not bestScore or score > bestScore) then best, bestScore = e, score end
        end
    end
    return best, bestScore
end

-- Mass of known enemy units within 30 of pos (what a nuke would hit).
local function ValueAround(brain, pos)
    local army = brain:GetArmyIndex()
    local v = 0
    for _, e in ipairs(brain:GetUnitsAroundPoint(categories.ALLUNITS - categories.WALL, pos, 30, 'Enemy') or {}) do
        if Intel.Known(e, army) then
            local eco = e:GetBlueprint().Economy
            v = v + ((eco and eco.BuildCostMass) or 0) * e:GetFractionComplete()
        end
    end
    return v
end

-- Exposed for tests: worth of a nuke target point.
function NukeTargetScore(value, nearEnemyEco, ender, acu)
    local score = value
    if nearEnemyEco then score = score * 2 end
    if ender then score = score + 20000 end
    if acu then score = score + 30000 end
    return score
end

-- Exposed for tests: keep hitting the focus point? (shots fired so far,
-- mass there when we started and now)
-- Exposed for tests: missiles to fire together at a point covered by
-- `covering` known anti-nukes, with `silos` finished silos.
function NukeSalvoNeed(covering, silos)
    return math.max(1, math.min(silos, covering + 1))
end

function NukeKeepFocus(shots, value0, valueNow)
    if shots >= Config.NukeShotsPerTarget then return false, 'held' end
    if valueNow < value0 / 3 then return false, 'destroyed' end
    return true
end

local function PickNukeTarget(brain, ctx, from)
    local army = brain:GetArmyIndex()
    local ecoBases = EnemyEcoBases(ctx)
    local now = GetGameTimeSeconds()
    ctx.nukeBlocked = ctx.nukeBlocked or {}
    local best, bestScore, bestValue
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatTargets, from, 4000, 'Enemy') or {}) do
        if Intel.Known(e, army) and not Utils.IsUnderwater(e) then
            local p = e:GetPosition()
            local blocked = false
            for _, b in ipairs(ctx.nukeBlocked) do
                if now - b.at < Config.NukeBlockedSeconds and Utils.Dist2D(b.pos, p) < Config.NukeRadius * 2 then
                    blocked = true
                end
            end
            if not blocked then
                local kind = TargetKind(e)
                local value = ValueAround(brain, p)
                local ender, acu = kind == 'ENDER', kind == 'ACU'
                if ender or acu or value >= Config.NukeMinValue then
                    local score = NukeTargetScore(value, NearAny(p, ecoBases, 90), ender, acu)
                    if not bestScore or score > bestScore then
                        best, bestScore, bestValue = { p[1], p[2], p[3] }, score, value
                    end
                end
            end
        end
    end
    return best, bestValue
end

-- No scouted target worth a missile: the start position of a living enemy
-- player (ECO first) with no known anti-nuke over it.
function BlindNukeTarget(brain, ctx)
    local enemy = OtherSide(ctx.side)
    local Mex = import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua')
    local list = {}
    for _, p in ipairs(Mex.DutyPositions(enemy, 'ECO')) do table.insert(list, p) end
    for name, sl in pairs(RoleManager.GetSlots()) do
        if sl.side == enemy and Mex.Holder(name) == name then table.insert(list, sl.pos) end
    end
    for _, p in ipairs(list) do
        if Intel.AntiNukesCovering(ctx.side, p) == 0 then return { p[1], p[2], p[3] } end
    end
    return nil
end

-- Nukes: one focus point, hit again and again (see Config.NukeShotsPerTarget).
-- All loaded missiles fire together, timed to land at the same moment.
local function NukeStep(brain, ctx)
    local loaded = {}
    for _, s in ipairs(brain:GetListOfUnits(CatOwnNukes, false)) do
        if Alive(s) and s:GetFractionComplete() >= 1 and not s.DGNukeBusy
            and s.GetNukeSiloAmmoCount and s:GetNukeSiloAmmoCount() > 0 then
            table.insert(loaded, s)
        end
    end
    local n = table.getn(loaded)
    if n == 0 then return end

    local f = ctx.nukeFocus
    if f then
        local keep, why = NukeKeepFocus(f.shots, f.value0, ValueAround(brain, f.pos))
        if not keep then
            if why == 'held' then
                Utils.Log(brain, 'nuke target held after ' .. f.shots .. ' missiles: switching, artillery for their anti-nuke')
                ctx.nukeBlocked = ctx.nukeBlocked or {}
                table.insert(ctx.nukeBlocked, { pos = f.pos, at = GetGameTimeSeconds() })
                ctx.wantAntiSMDArty = true
            else
                Utils.Log(brain, 'nuke target destroyed')
            end
            f = nil
        end
    end
    if not f then
        local pos, value = PickNukeTarget(brain, ctx, loaded[1]:GetPosition())
        if not pos then
            pos = BlindNukeTarget(brain, ctx)
            value = pos and Config.NukeMinValue or nil
            if pos then Utils.Log(brain, 'nuke: nothing scouted worth it, a missile into an enemy base without anti-nuke') end
        end
        if not pos then
            ctx.nukeFocus = nil
            if not ctx.nukeIdleSaid or GetGameTimeSeconds() - ctx.nukeIdleSaid > 120 then
                ctx.nukeIdleSaid = GetGameTimeSeconds()
                Utils.Log(brain, 'nuke loaded (' .. n .. '), no target: every enemy base is covered or unknown')
            end
            return
        end
        f = { pos = pos, value0 = value, shots = 0 }
        Utils.Log(brain, 'nuke focus: ' .. math.floor(value) .. ' mass at ' .. math.floor(pos[1]) .. ',' .. math.floor(pos[3]))
        Comms.Say(brain, ctx.side, 'nuke:' .. brain.Name, 'Nuking their core here, again and again!', pos, 'attack')
    end
    ctx.nukeFocus = f

    local target = f.pos
    -- Saturate the anti-nukes: missiles land together, one more than the
    -- known anti-nukes covering the point.
    local silos = 0
    for _, s in ipairs(brain:GetListOfUnits(CatOwnNukes, false)) do
        if Alive(s) and s:GetFractionComplete() >= 1 then silos = silos + 1 end
    end
    local need = NukeSalvoNeed(Intel.AntiNukesCovering(ctx.side, target), silos)
    if n < need then
        f.waitSince = f.waitSince or GetGameTimeSeconds()
        if GetGameTimeSeconds() - f.waitSince < Config.NukeWaitMax then return end
    end
    f.waitSince = nil
    -- Longest flight first, so all missiles arrive together (speed ~40/s).
    local shots = {}
    for i = 1, n do
        table.insert(shots, { unit = loaded[i], flight = Utils.Dist2D(loaded[i]:GetPosition(), target) / 40 })
    end
    table.sort(shots, function(a, b) return a.flight > b.flight end)
    f.shots = f.shots + n
    Utils.Log(brain, 'nuke salvo of ' .. n .. ' (' .. f.shots .. '/' .. Config.NukeShotsPerTarget .. ' at this point)')
    for _, sh in ipairs(shots) do sh.unit.DGNukeBusy = true end
    ForkThread(function()
        local last = shots[1].flight
        for _, sh in ipairs(shots) do
            if last - sh.flight > 0 then WaitSeconds(last - sh.flight) end
            last = sh.flight
            if Alive(sh.unit) then IssueNuke({ sh.unit }, target) end
        end
        -- The missile leaves a few seconds after the order: keep the silos
        -- out of the next salvo until then.
        WaitSeconds(10)
        for _, sh in ipairs(shots) do sh.unit.DGNukeBusy = nil end
    end)
end

local function WeaponsStep(brain, ctx)
    for _, s in ipairs(brain:GetListOfUnits(CatOwnSilos, false)) do
        if Alive(s) and s:GetFractionComplete() >= 1 and not s.DGAuto then
            s:SetAutoMode(true)
            s.DGAuto = true
        end
    end
    -- Energy short: nuke silos that already hold a missile stop loading
    -- the next one (anti-nukes keep loading).
    local e = brain:GetEconomyStoredRatio('ENERGY')
    for _, s in ipairs(brain:GetListOfUnits(CatOwnNukes, false)) do
        if Alive(s) and s:GetFractionComplete() >= 1 and s.SetPaused then
            local ammo = s.GetNukeSiloAmmoCount and s:GetNukeSiloAmmoCount() or 0
            if not s.DGPaused and e < Config.SiloPauseEnergy and ammo > 0 then
                s:SetPaused(true)
                s.DGPaused = true
            elseif s.DGPaused and (e > Config.SiloResumeEnergy or ammo == 0) then
                s:SetPaused(false)
                s.DGPaused = nil
            end
        end
    end
    NukeStep(brain, ctx)
    -- Artillery re-picks every planner tick: a better target (an ACU walking
    -- into range, a shield going down) takes over from the current one.
    -- Novax satellites fly anywhere, so their range is the whole map; they
    -- are untargetable, so enemy AA doesn't matter to them.
    local shooters = {}
    for _, a in ipairs(brain:GetListOfUnits(CatOwnArty, false)) do table.insert(shooters, a) end
    for _, a in ipairs(brain:GetListOfUnits(CatOwnSatellite, false)) do
        a.DualGapAssigned = true
        table.insert(shooters, a)
    end
    for _, a in ipairs(shooters) do
        if Alive(a) and a:GetFractionComplete() >= 1 then
            local sat = EntityCategoryContains(CatOwnSatellite, a)
            local longRange = sat or EntityCategoryContains(categories.TECH3 + categories.EXPERIMENTAL, a)
            local range = 4000
            local w = a:GetBlueprint().Weapon
            if not sat and w and w[1] and w[1].MaxRadius then range = w[1].MaxRadius end
            -- Novax satellites go for the enemy ECO's commander first (with
            -- the team's air T4 operation), when it is seen, on land and
            -- not under a shield.
            local ecoACU = sat and EnemyEcoACU(brain, ctx)
            if ecoACU then
                if a.DGTarget ~= ecoACU then
                    a.DGTarget = ecoACU
                    IssueClearCommands({ a })
                    IssueAttack({ a }, ecoACU)
                end
            else
                AimShooter(brain, ctx, a, range, longRange)
            end
        end
    end
end

-- The enemy ECO's commander, if seen, on land and unshielded.
function EnemyEcoACU(brain, ctx)
    local army = brain:GetArmyIndex()
    for _, base in ipairs(EnemyEcoBases(ctx)) do
        for _, e in ipairs(brain:GetUnitsAroundPoint(categories.COMMAND, base, 200, 'Enemy') or {}) do
            local p = e:GetPosition()
            if Intel.Known(e, army) and not Utils.IsUnderwater(e) and Intel.ShieldsOver(ctx.side, p) == 0 then return e end
        end
    end
    return nil
end

-- Known enemy army (land / naval units) in range of a gun.
local CatArmyTargets = categories.MOBILE * (categories.LAND + categories.NAVAL) - categories.COMMAND - categories.ENGINEER

local function ArmyInRange(brain, pos, range)
    local army = brain:GetArmyIndex()
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatArmyTargets, pos, range, 'Enemy') or {}) do
        if Intel.Known(e, army) then return true end
    end
    return false
end

-- One gun: a priority target gets an explicit order (ground fire on a
-- structure's spot, so a remembered-but-unseen structure is still hit; a
-- unit order on a visible ACU). Short-range artillery facing an enemy army
-- with nothing better than eco / factories to shoot is left to its own
-- automatic targeting - an explicit order on a mex would make it ignore the
-- army walking up to it.
function AimShooter(brain, ctx, a, range, longRange)
    local t, score = BestTarget(brain, ctx, a:GetPosition(), range, longRange)
    local current = Alive(a.DGTarget) and a.DGTarget or nil
    if not longRange and (not t or score < 60) and ArmyInRange(brain, a:GetPosition(), range) then
        if current or not a:IsIdleState() then IssueClearCommands({ a }) end
        a.DGTarget, a.DGScore = nil, nil
        return
    end
    if t and t ~= current and (not current or a:IsIdleState() or score > (a.DGScore or 0)) then
        IssueClearCommands({ a })
        if EntityCategoryContains(categories.STRUCTURE, t) then
            local p = t:GetPosition()
            IssueAttack({ a }, { p[1], p[2], p[3] })
        else
            IssueAttack({ a }, t)
        end
        a.DGTarget, a.DGScore = t, score
    elseif current and (not t or a:IsIdleState()) then
        -- Target gone from sight or reach: free the gun, pick again next tick.
        IssueClearCommands({ a })
        a.DGTarget, a.DGScore = nil, nil
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
    PlanForwardBase(brain, ctx)
    PlanFrontline(brain, ctx)
    PlanBaseTorpedoes(brain, ctx)
    PlanBaseAA(brain, ctx)
    PlanFortify(brain, ctx)
    PlanIntelStructures(brain, ctx)
    PlanAntiNuke(brain, ctx)
    PlanYolonaDefense(brain, ctx)
    PlanBaseShields(brain, ctx)
    PlanExperimentals(brain, ctx)
    WeaponsStep(brain, ctx)
    UpgradeShields(brain, ctx)
    UpgradeIntel(brain, ctx)
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
