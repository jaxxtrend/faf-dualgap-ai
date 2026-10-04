-- ACU lifecycle: overcharge, role-specific tasks, retreat / submerge.
--
-- DualGapEngineers runs the ACU's opening build order (ctx.acuBODone). After
-- that this module drives the GROUND / NAVAL ACU; AIR / ECO ACUs stay home as
-- base builders. Orders are only given when the ACU is idle or in danger.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')

local Alive = Utils.Alive

local CatEnemyTargets = categories.MOBILE - categories.AIR - categories.INSIGNIFICANTUNIT
local CatStratArty = categories.STRUCTURE * categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
local CatPD = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE
local CatShield = categories.STRUCTURE * categories.SHIELD
local CatWall = categories.WALL
-- Yards only: carriers and the Tempest are FACTORY too, and an ACU
-- "helping" one would follow it into battle.
local CatNavalFactory = categories.FACTORY * categories.NAVAL * categories.STRUCTURE
local CatTorpedo = categories.STRUCTURE * categories.DEFENSE * categories.ANTINAVY

local function Offset(p, dx, dz)
    return { p[1] + dx, GetSurfaceHeight(p[1] + dx, p[3] + dz), p[3] + dz }
end

local function Projects()
    return import('/mods/DualGapAI/lua/AI/DualGapProjects.lua')
end

-- Order an ACU enhancement once (and its prerequisite first). Returns true
-- if an order was given this tick.
function TryEnhance(brain, acu, name)
    local enh = acu:GetBlueprint().Enhancements or {}
    local def = enh[name]
    if not def or (acu.HasEnhancement and acu:HasEnhancement(name)) then return false end
    if brain:GetEconomyStoredRatio('ENERGY') < 0.5 or brain:GetEconomyStoredRatio('MASS') < 0.1 then return false end
    local pick = name
    if def.Prerequisite and acu.HasEnhancement and not acu:HasEnhancement(def.Prerequisite) then
        pick = def.Prerequisite
    end
    Utils.Log(brain, 'ACU enhancement ' .. pick)
    IssueScript({ acu }, { TaskName = 'EnhanceTask', Enhancement = pick })
    return true
end

local function HealthRatio(u)
    return u:GetHealth() / u:GetMaxHealth()
end

---------------------------------------------------------------------------
-- Overcharge (all roles)
---------------------------------------------------------------------------
local function OverchargeStep(brain, ctx)
    local acu = Utils.Commander(brain)
    -- Never cancel a retreat order to shoot.
    if not acu or ctx.acuState == 'SUBMERGED' then return end
    if brain:GetEconomyStoredRatio('ENERGY') <= Config.OverchargeEnergyRatio then return end
    local pos = acu:GetPosition()
    local enemies = brain:GetUnitsAroundPoint(CatEnemyTargets, pos, Config.OverchargeRange, 'Enemy')
    local target, bestHp
    for _, e in ipairs(enemies or {}) do
        if Alive(e) and not e:IsUnitState('BeingBuilt') then
            -- Prefer the toughest target OC can still hurt badly.
            local hp = e:GetHealth()
            if not bestHp or hp > bestHp then target, bestHp = e, hp end
        end
    end
    if target then
        IssueClearCommands({ acu })
        IssueOverCharge({ acu }, target)
    end
end

---------------------------------------------------------------------------
-- Safety. GROUND / NAVAL ACUs hide at maximum depth in the rear at the end of
-- the T2 phase (ctx.t2EndTime), on low HP, against enemy strategic artillery,
-- when many bombers are around, or when a known enemy land experimental
-- comes close (land T4s can't hurt an ACU underwater). If the air threat is
-- mostly torpedo bombers, water is the dangerous place: stay on land and
-- build in base. Underwater, only warships are a danger: a strong enough
-- known fleet close by makes the ACU move to another deep spot (or home).
-- AIR / ECO ACUs never leave the base and only fall back to the start.
---------------------------------------------------------------------------
local CatEnemyAir = categories.AIR * categories.MOBILE - categories.SCOUT
local CatTorpAir = CatEnemyAir * categories.ANTINAVY
local CatBomberAir = CatEnemyAir * (categories.BOMBER + categories.GROUNDATTACK) - categories.ANTINAVY

local CatEnemyLandT4 = categories.LAND * categories.MOBILE * categories.EXPERIMENTAL
local CatEnemyWarship = categories.NAVAL * categories.MOBILE

-- Known enemy strength near pos: T1 = 1, T2 = 3, T3 = 8, T4 = 20.
function KnownStrength(brain, cat, pos, radius)
    local army = brain:GetArmyIndex()
    local s = 0
    for _, e in ipairs(brain:GetUnitsAroundPoint(cat, pos, radius, 'Enemy') or {}) do
        if Intel.Known(e, army) then
            if EntityCategoryContains(categories.EXPERIMENTAL, e) then s = s + 20
            else s = s + ({ 1, 3, 8 })[Utils.TechOf(e)] end
        end
    end
    return s
end

-- Hiding spots of each side's ACUs, so they spread out under water.
local hideSpots = { LEFT = {}, RIGHT = {} }

function HideSpots(side)
    local out = {}
    for name, pos in pairs(hideSpots[side] or {}) do table.insert(out, { name = name, pos = pos }) end
    return out
end

local function SetHideSpot(brain, ctx, pos)
    hideSpots[ctx.side] = hideSpots[ctx.side] or {}
    hideSpots[ctx.side][brain.Name] = pos
end

local function OtherHideSpots(brain, ctx)
    local out = {}
    for name, pos in pairs(hideSpots[ctx.side] or {}) do
        if name ~= brain.Name then table.insert(out, pos) end
    end
    return out
end

-- Exposed for tests: how far apart hidden ACUs keep. Spread out only
-- while an enemy nuke is in the air and no loaded own anti-nuke covers
-- them; else close is fine (just not the same spot).
function HideSpacing(nukeInFlight, loadedAntiNuke)
    if nukeInFlight and not loadedAntiNuke then return Config.HideSpacing end
    return Config.HideSpacingNear
end

local CatOwnSMD = categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE
-- An allied anti-nuke within reach of pos with a missile loaded.
local function LoadedAntiNuke(brain, pos)
    for _, s in ipairs(brain:GetUnitsAroundPoint(CatOwnSMD, pos, 90, 'Ally') or {}) do
        if Alive(s) and s:GetFractionComplete() >= 1 and s.GetTacticalSiloAmmoCount
            and s:GetTacticalSiloAmmoCount() > 0 then return true end
    end
    return false
end

local function NukeDanger(brain, ctx, pos)
    return Intel.EnemyNukeInFlight(brain:GetArmyIndex()), LoadedAntiNuke(brain, pos or ctx.startPos)
end

-- The deepest water of the own base's basin, spaced from the allies'
-- hiding spots (HideSpacing) and away from `fleet` (a known enemy fleet).
-- Never out of the own basin: nil if there is no such spot.
local function PickHideSpot(brain, ctx, fleet)
    local avoid = OtherHideSpots(brain, ctx)
    local spacing = HideSpacing(NukeDanger(brain, ctx))
    local r = Config.HideBasinRadius
    return Utils.DeepestWaterNear(ctx.startPos, r, avoid, spacing, fleet, Config.HideFleetDistance)
        or (spacing > Config.HideSpacingNear
            and Utils.DeepestWaterNear(ctx.startPos, r, avoid, Config.HideSpacingNear, fleet, Config.HideFleetDistance))
        or nil
end

-- Only what this army can see (or has seen, for structures): no peeking
-- into the fog.
local function KnownCount(brain, cat, pos, radius)
    local army = brain:GetArmyIndex()
    local n = 0
    for _, e in ipairs(brain:GetUnitsAroundPoint(cat, pos, radius, 'Enemy') or {}) do
        if Intel.Known(e, army) then n = n + 1 end
    end
    return n
end

local function EnemyStratArtyPresent(brain, pos)
    return KnownCount(brain, CatStratArty, pos, Config.StratArtyScanRadius) > 0
end

-- Returns torpedo bombers, bombers/gunships, all other aircraft near pos
-- (the ones seen or on radar).
function AirThreat(brain, pos)
    local r = Config.AirThreatRadius
    local torp = KnownCount(brain, CatTorpAir, pos, r)
    local bombers = KnownCount(brain, CatBomberAir, pos, r)
    local all = KnownCount(brain, CatEnemyAir, pos, r)
    return torp, bombers, all - torp
end

-- Pure decision, exposed for tests. Returns 'DEEP', 'LAND' or nil.
-- landT4: a known enemy land experimental is close.
function SafetyDecision(hp, lateT2, stratArty, torp, bombers, otherAir, landT4)
    local torpHeavy = torp >= Config.TorpThreat and otherAir < Config.FewAir
    local airHeavy = bombers >= Config.BomberThreat
    if airHeavy then return 'DEEP' end
    local wantsWater = hp < Config.ACURetreatHealth or lateT2 or stratArty or landT4
    if wantsWater and torpHeavy then return 'LAND' end
    if wantsWater then return 'DEEP' end
    return nil
end

-- Exposed for tests: how well a spot is defended against an air T4
-- (T3 anti-air near it counts double, being under a shield a lot).
function RefugeScore(aaT3, aaOther, shielded)
    return 2 * aaT3 + aaOther + (shielded and 6 or 0)
end

local CatOwnAA = categories.STRUCTURE * categories.ANTIAIR
local CatOwnShield = categories.STRUCTURE * categories.SHIELD
local CatAirT4 = categories.AIR * categories.MOBILE * categories.EXPERIMENTAL - categories.SATELLITE

-- The best-defended spot of the base: next to an own AA site or shield
-- within 90 of the start, scored by the AA and shields around it.
local function RefugeSpot(brain, ctx)
    local best, bestScore
    for _, u in ipairs(brain:GetUnitsAroundPoint(CatOwnAA + CatOwnShield, ctx.startPos, 90, 'Ally') or {}) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local p = u:GetPosition()
            local t3 = Utils.CountAround(brain, CatOwnAA * categories.TECH3, p, 35, 'Ally')
            local other = Utils.CountAround(brain, CatOwnAA, p, 35, 'Ally') - t3
            local shielded = Utils.CountAround(brain, CatOwnShield, p, 15, 'Ally') > 0
            local score = RefugeScore(t3, other, shielded)
            if not bestScore or score > bestScore then best, bestScore = p, score end
        end
    end
    return best
end

-- AIR / ECO ACU: an enemy air experimental coming -> under the guns.
-- Returns true while the ACU is taking refuge (the engineers leave it be).
function RefugeStep(brain, ctx, acu, pos)
    local now = GetGameTimeSeconds()
    if KnownCount(brain, CatAirT4, pos, Config.RefugeRadius) > 0 then
        ctx.refugeUntil = now + Config.RefugeSeconds
        if not ctx.refugeSpot then
            ctx.refugeSpot = RefugeSpot(brain, ctx) or ctx.startPos
            Utils.Log(brain, 'ACU takes refuge under the base AA: enemy air experimental coming')
            Comms.Say(brain, ctx.side, 'refuge:' .. brain.Name, 'Enemy air T4 coming at my base, need fighters here!',
                pos, 'alert')
        end
        if Utils.Dist2D(pos, ctx.refugeSpot) > 6 then
            IssueClearCommands({ acu })
            IssueMove({ acu }, ctx.refugeSpot)
        end
        return true
    end
    if ctx.refugeUntil and now < ctx.refugeUntil then return true end
    ctx.refugeUntil, ctx.refugeSpot = nil, nil
    return false
end

local function SafetyStep(brain, ctx)
    local acu = Utils.Commander(brain)
    if not acu then return end
    local pos = acu:GetPosition()
    local hp = HealthRatio(acu)
    local role = ctx.role

    if role == 'GROUND' or role == 'NAVAL' then
        local lateT2 = ctx.t2EndTime ~= nil and GetGameTimeSeconds() >= ctx.t2EndTime
        local torp, bombers, otherAir = AirThreat(brain, pos)
        local landT4 = KnownStrength(brain, CatEnemyLandT4, pos, Config.T4DangerRadius) > 0
        local want = SafetyDecision(hp, lateT2, EnemyStratArtyPresent(brain, pos), torp, bombers, otherAir, landT4)
        -- Stayed on land for torpedo bombers: keep to it a while, the count
        -- around flickers (no diving under them two seconds later); only a
        -- bomber swarm overrides it.
        local now = GetGameTimeSeconds()
        if want == 'DEEP' and ctx.acuState == 'LANDBUILD' and ctx.landUntil and now < ctx.landUntil
            and bombers < Config.BomberThreat then
            want = nil
        end

        if want == 'DEEP' and ctx.acuState ~= 'SUBMERGED' then
            local water = PickHideSpot(brain, ctx)
            if water then
                Utils.Log(brain, string.format('ACU to max depth (hp=%.2f lateT2=%s bombers=%d)',
                    hp, tostring(lateT2), bombers))
                IssueClearCommands({ acu })
                IssueMove({ acu }, water)
                ctx.acuState = 'SUBMERGED'
                ctx.submergePos = water
                SetHideSpot(brain, ctx, water)
            end
        elseif want == 'LAND' and ctx.acuState ~= 'LANDBUILD' then
            Utils.Log(brain, 'ACU stays on land: torpedo bombers (' .. torp .. '), little other air')
            IssueClearCommands({ acu })
            IssueMove({ acu }, ctx.startPos)
            ctx.acuState = 'LANDBUILD'      -- DualGapEngineers uses it as a base builder
            ctx.landUntil = GetGameTimeSeconds() + Config.LandHoldSeconds
        elseif want == nil and (ctx.acuState == 'SUBMERGED' or ctx.acuState == 'LANDBUILD') and hp > 0.8
            and not (ctx.landUntil and now < ctx.landUntil) then
            -- Threat gone (only possible before the T2 phase ends): back to work.
            ctx.acuState = (role == 'GROUND') and 'MARCH' or 'NAVAL'
            SetHideSpot(brain, ctx, nil)
        end
    else
        if RefugeStep(brain, ctx, acu, pos) then return end
        if hp < Config.ACURetreatHealth and Utils.Dist2D(pos, ctx.startPos) > 20 then
            IssueClearCommands({ acu })
            IssueMove({ acu }, ctx.startPos)
        end
    end
end

---------------------------------------------------------------------------
-- GROUND: march along the arc to the choke, fortify, hold.
---------------------------------------------------------------------------
local function FortifyPlan(brain, ctx)
    local choke = ctx.choke
    local dir = (ctx.side == 'LEFT') and 1 or -1
    local pd = Utils.FactionId(brain, 'PointDefenseT2')
    local acu = Utils.Commander(brain)
    if not (acu and pd and acu:CanBuild(pd)) then pd = Utils.FactionId(brain, 'PointDefenseT1') end
    local plan = {
        { id = pd, cat = CatPD, want = 3, spots = { Offset(choke, dir * 4, -8), Offset(choke, dir * 4, 0), Offset(choke, dir * 4, 8) } },
        { id = Utils.FactionId(brain, 'ShieldT2'), cat = CatShield, want = 1, spots = { Offset(choke, -dir * 3, 0) } },
        { id = Utils.FactionId(brain, 'Wall'), cat = CatWall, want = 9, spots = {} },
    }
    -- A short wall in front of each point defence only: the gaps between
    -- them stay open so our own waves can walk through.
    for _, pdz in ipairs({ -8, 0, 8 }) do
        for _, dz in ipairs({ -1, 0, 1 }) do
            table.insert(plan[3].spots, Offset(choke, dir * 7, pdz + dz))
        end
    end
    return plan
end

local function GroundACUStep(brain, ctx)
    local acu = Utils.Commander(brain)
    if not acu or not ctx.acuBODone then return end
    if ctx.acuState == 'SUBMERGED' or ctx.acuState == 'LANDBUILD' then return end
    if not Utils.IsIdle(acu) then return end

    local pos = acu:GetPosition()
    if ctx.acuState == 'OPENING' then ctx.acuState = 'MARCH' end
    if ctx.acuState == 'JOINNAVAL' then
        JoinNavalStep(brain, ctx, acu)
        return
    end

    if ctx.acuState == 'MARCH' then
        if Utils.Dist2D(pos, ctx.choke) < 12 then
            ctx.acuState = 'FORTIFY'
        else
            -- Walk the arc only up to the choke (drop waypoints past it).
            local route = Routes.GetRoute(ctx.groundArc, ctx.side)
            local trimmed = {}
            for _, wp in ipairs(route) do
                table.insert(trimmed, wp)
                if Utils.Dist2D(wp, ctx.choke) < 60 then break end
            end
            table.insert(trimmed, ctx.choke)
            Routes.ExecuteQueuedMovement({ acu }, trimmed, false)
            return
        end
    end

    if ctx.acuState == 'FORTIFY' then
        for _, item in ipairs(FortifyPlan(brain, ctx)) do
            if item.id and acu:CanBuild(item.id) then
                local have = Utils.CountAround(brain, item.cat, ctx.choke, 25, 'Ally')
                if have < item.want then
                    local spot = item.spots[have + 1] or item.spots[1]
                    if Utils.BuildNear(brain, acu, item.id, spot, 10, 0) then return end
                end
            end
        end
        ctx.acuState = 'HOLD'
    end

    if ctx.acuState == 'HOLD' then
        -- Mid pushed to the enemy bases: go help the navy.
        if ctx.midPushed then
            Utils.Log(brain, 'ACU leaves the mid to join the navy')
            ctx.acuState = 'JOINNAVAL'
            return
        end
        -- T2: engineering upgrade, then help build the proxy base.
        if ctx.t2Time and TryEnhance(brain, acu, 'AdvancedEngineering') then return end
        if Projects().HelpWith(brain, ctx, acu, { 'ProxyShield', 'ProxyArty' }) then return end
        if Utils.Dist2D(pos, ctx.choke) > 15 then
            IssueMove({ acu }, ctx.choke)
        else
            -- Re-check the fortifications now and then (rebuild losses).
            ctx.holdTicks = (ctx.holdTicks or 0) + 1
            if ctx.holdTicks >= 15 then
                ctx.holdTicks = 0
                ctx.acuState = 'FORTIFY'
            end
        end
    end
end

---------------------------------------------------------------------------
-- Naval help: assist the best (own or allied) naval factory or a naval
-- experimental under construction within `radius` of `around`. Used by the
-- GROUND ACU that joined the navy and by any ACU hiding underwater.
---------------------------------------------------------------------------
function HelpNavy(brain, ctx, acu, around, radius)
    local best, bestTech
    for _, u in ipairs(brain:GetUnitsAroundPoint(categories.EXPERIMENTAL + CatNavalFactory, around, radius, 'Ally') or {}) do
        if Alive(u) then
            if EntityCategoryContains(categories.EXPERIMENTAL, u) and u:GetFractionComplete() < 1 then
                IssueRepair({ acu }, u)
                return true
            end
            if EntityCategoryContains(CatNavalFactory, u) and u:GetFractionComplete() >= 1 then
                local tech = Utils.TechOf(u)
                if not bestTech or tech > bestTech then best, bestTech = u, tech end
            end
        end
    end
    if best then
        IssueGuard({ acu }, best)
        return true
    end
    return false
end

function JoinNavalStep(brain, ctx, acu)
    local spot = ctx.joinNavalPos
    if not spot then
        spot = Utils.FindNearestWater(Routes.GetPoint('NavalYardHint', ctx.side), 1.5, 200)
            or Routes.GetPoint('NavalRally', ctx.side)
        ctx.joinNavalPos = spot
    end
    if Utils.Dist2D(acu:GetPosition(), spot) > 40 then
        IssueMove({ acu }, spot)
        return
    end
    if HelpNavy(brain, ctx, acu, spot, 200) then return end
    -- No naval factory around: build our own.
    Utils.BuildNear(brain, acu, Utils.FactionId(brain, 'NavalFactoryT1'), spot, 40)
end

-- Centre of the known enemy warships near pos.
local function FleetCentre(brain, pos, radius)
    local army = brain:GetArmyIndex()
    local x, z, n = 0, 0, 0
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatEnemyWarship, pos, radius, 'Enemy') or {}) do
        if Intel.Known(e, army) then
            local p = e:GetPosition()
            x, z, n = x + p[1], z + p[3], n + 1
        end
    end
    if n == 0 then return nil end
    return { x / n, 0, z / n }
end

-- Guard the hiding spot: torpedo launchers in the water around it, T3 SAMs
-- on the nearest shore. Returns true if a build order was given.
local CatTorpedoDef = categories.STRUCTURE * categories.ANTINAVY
local CatSAM = categories.STRUCTURE * categories.ANTIAIR * categories.TECH3

local function GuardHidingSpot(brain, ctx, acu, home)
    if brain:GetEconomyStoredRatio('MASS') < 0.1 then return false end
    if Utils.CountAround(brain, CatTorpedoDef, home, 30, 'Ally') < Config.HideTorpedoes then
        local id = Utils.FactionId(brain, 'TorpedoT2')
        if not (id and acu:CanBuild(id)) then id = Utils.FactionId(brain, 'TorpedoT1') end
        if Utils.BuildNear(brain, acu, id, home, 25, 1) then return true end
    end
    if Utils.CountAround(brain, CatSAM, home, 50, 'Ally') < Config.HideSAMs then
        local id = Utils.FactionId(brain, 'AntiAirT3')
        -- SAMs stand on land: the spiral search finds the nearest shore.
        if id and acu:CanBuild(id) and Utils.BuildNear(brain, acu, id, home, 45, 1) then return true end
    end
    return false
end

function SubmergedStep(brain, ctx)
    local acu = Utils.Commander(brain)
    if not acu or ctx.acuState ~= 'SUBMERGED' then return end
    local pos = acu:GetPosition()

    -- Warships are the only real danger underwater. After a move the ACU
    -- keeps to its new spot a while (no re-deciding every few seconds).
    local now = GetGameTimeSeconds()
    if ctx.evadeUntil and now < ctx.evadeUntil then return end
    if KnownStrength(brain, CatEnemyWarship, pos, Config.NavalDangerRadius) >= Config.NavalDangerStrength then
        ctx.evadeUntil = now + Config.EvadeCooldown
        local fleet = FleetCentre(brain, pos, Config.NavalDangerRadius)
        local spot = fleet and PickHideSpot(brain, ctx, fleet)
        IssueClearCommands({ acu })
        if spot then
            Utils.Log(brain, 'ACU moves away from an enemy fleet to another deep spot')
            IssueMove({ acu }, spot)
            ctx.submergePos = spot
            SetHideSpot(brain, ctx, spot)
        else
            Utils.Log(brain, 'ACU leaves the water: enemy fleet close and no other deep spot')
            IssueMove({ acu }, ctx.startPos)
            ctx.acuState = 'LANDBUILD'
            SetHideSpot(brain, ctx, nil)
        end
        Comms.Say(brain, ctx.side, 'acufleet:' .. brain.Name, 'Enemy navy at my hidden ACU, moving it!', pos, 'alert')
        return
    end

    -- An enemy nuke shows up with no anti-nuke over us: spread out from
    -- the other hidden ACUs (one missile must not catch two).
    local inFlight, loaded = NukeDanger(brain, ctx, ctx.submergePos)
    if ctx.submergePos and HideSpacing(inFlight, loaded) > Config.HideSpacingNear then
        local crowded = false
        for _, o in ipairs(OtherHideSpots(brain, ctx)) do
            if Utils.Dist2D(o, ctx.submergePos) < Config.HideSpacing then crowded = true; break end
        end
        local spot = crowded and PickHideSpot(brain, ctx)
        if spot and Utils.Dist2D(spot, ctx.submergePos) > 10 then
            ctx.evadeUntil = now + Config.EvadeCooldown
            Utils.Log(brain, 'ACU spreads out from the other hidden ACUs: enemy nuke launched, no loaded anti-nuke')
            IssueClearCommands({ acu })
            IssueMove({ acu }, spot)
            ctx.submergePos = spot
            SetHideSpot(brain, ctx, spot)
            return
        end
    end

    if not Utils.IsIdle(acu) then return end
    local home = ctx.submergePos or pos
    -- Stay near the hiding spot: only work within reach of it.
    if Utils.Dist2D(pos, home) > 160 then return end
    if GuardHidingSpot(brain, ctx, acu, home) then return end
    HelpNavy(brain, ctx, acu, home, 150)
end

---------------------------------------------------------------------------
-- NAVAL: coastal yard first, then factory loops / torpedo launchers.
---------------------------------------------------------------------------
local NavalLateStart = 600

local function NavalACUStep(brain, ctx)
    local acu = Utils.Commander(brain)
    if not acu or not ctx.acuBODone then return end
    if ctx.acuState == 'SUBMERGED' or ctx.acuState == 'LANDBUILD' then return end
    local t = GetGameTimeSeconds()

    if not ctx.yardPos then
        local hint = Routes.GetPoint('NavalYardHint', ctx.side)
        ctx.yardPos = Utils.FindNearestWater(hint, 1.5, 150) or Utils.FindNearestWater(ctx.startPos, 1.5, 250)
        if not ctx.yardPos then
            WARN('DualGap: no coastal water found for NAVAL yard; behaving as GROUND')
            ctx.role = 'GROUND'
            return
        end
    end

    local navalFactories = brain:GetListOfUnits(CatNavalFactory, false)
    if Utils.Count(navalFactories) == 0 then
        if Utils.IsIdle(acu) then
            Utils.BuildNear(brain, acu, Utils.FactionId(brain, 'NavalFactoryT1'), ctx.yardPos, 30)
        end
        return
    end

    ctx.acuState = 'NAVAL'

    -- Re-plan every step when idle; when assisting, only interrupt for real work.
    local busyAssisting = (ctx.acuTask == 'ASSIST') and not Utils.IsIdle(acu)
    local work
    if t < NavalLateStart then
        work = nil                       -- early: just loop the first yard
    elseif Utils.Count(navalFactories) < 3 then
        work = { id = Utils.FactionId(brain, 'NavalFactoryT1'), pos = ctx.yardPos }
    else
        local torps = Utils.CountAround(brain, CatTorpedo, ctx.yardPos, 40, 'Ally')
        if torps < 4 then
            local id = Utils.FactionId(brain, 'TorpedoT2')
            if not acu:CanBuild(id) then id = Utils.FactionId(brain, 'TorpedoT1') end
            work = { id = id, pos = Utils.FindNearestWater(Offset(ctx.yardPos, 0, (torps - 2) * 10), 1, 40) }
        end
    end

    if work and work.pos then
        if Utils.IsIdle(acu) or busyAssisting then
            IssueClearCommands({ acu })
            if Utils.BuildNear(brain, acu, work.id, work.pos, 25) then
                ctx.acuTask = 'BUILD'
                return
            end
        end
    end

    if Utils.IsIdle(acu) then
        -- Assist the most advanced naval factory.
        local best, bestTech
        for _, f in ipairs(navalFactories) do
            if Alive(f) and f:GetFractionComplete() >= 1 then
                local tech = EntityCategoryContains(categories.TECH3, f) and 3
                    or (EntityCategoryContains(categories.TECH2, f) and 2 or 1)
                if not bestTech or tech > bestTech then best, bestTech = f, tech end
            end
        end
        if best then
            IssueGuard({ acu }, best)
            ctx.acuTask = 'ASSIST'
        end
    end
end

---------------------------------------------------------------------------
function Start(brain, ctx)
    ctx.acuState = 'OPENING'
    Intel.WatchNukeLaunches()
    -- Each GROUND player holds its own zone: upper slot (rank 2) the upper
    -- mid mex group via the north arc, lower slot (rank 3) the lower one.
    local slot = RoleManager.GetSlots()[brain.Name]
    if slot and slot.role == 'GROUND' and slot.rank == 3 then
        ctx.choke = Routes.GetPoint('ChokeLower', ctx.side)
        ctx.groundArc = 'GroundArcSouth'
    elseif slot and slot.role == 'GROUND' then
        ctx.choke = Routes.GetPoint('ChokeUpper', ctx.side)
        ctx.groundArc = 'GroundArcNorth'
    else
        ctx.choke = Routes.GetPoint('Choke', ctx.side)
        ctx.groundArc = 'GroundArcNorth'
    end
    ForkThread(Utils.RunLoop, 'Overcharge', brain, ctx, 1, OverchargeStep)
    ForkThread(Utils.RunLoop, 'ACUSafety', brain, ctx, 2, SafetyStep)
    ForkThread(Utils.RunLoop, 'ACUUnderwater', brain, ctx, 3, SubmergedStep)
    if ctx.role == 'GROUND' then
        ForkThread(Utils.RunLoop, 'GroundACU', brain, ctx, 2, GroundACUStep)
    elseif ctx.role == 'NAVAL' then
        ForkThread(Utils.RunLoop, 'NavalACU', brain, ctx, 2, function(b, c)
            -- NAVAL may demote itself to GROUND if the map has no coast nearby.
            if c.role == 'GROUND' then GroundACUStep(b, c) else NavalACUStep(b, c) end
        end)
    end
    -- AIR and ECO ACUs are base builders (DualGapEngineers), ECO also does RAS.
end
