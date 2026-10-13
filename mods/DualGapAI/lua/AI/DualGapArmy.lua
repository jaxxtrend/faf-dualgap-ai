-- Army control. Factory output gathers at rally points and leaves in
-- formation once there is enough of it; units owned by a wave carry
-- unit.DualGapAssigned so nothing re-tasks them.
--
--   Land   gather behind the own wall -> wave of Config.WaveSize[tech]
--          (an experimental counts Config.ExperimentalWaveWeight), or
--          earlier when the enemy comes at the wall -> formation attack-move
--          through the own zone to the enemy's -> hunt scouted targets
--   Arty   gathers behind the wall, follows the waves
--   Naval  gather at the naval rally point -> fleet of NavalFleetSize[tech]
--          -> basin -> enemy waters; falls back when a clearly stronger
--          scouted fleet is ahead
--   Air    fighters patrol ALONG the front (north-south); each patrol point
--          steps back while scouted enemy AA is near it. Known enemy
--          aircraft behind the front line are intercepted by the nearest
--          patrol fighters, who return to the patrol afterwards.
--          Bombers stage and strike scouted game enders first, then ships /
--          economy, always the target with the least AA around. Fighters go
--          first on the direct line and tie up the enemy fighters; the
--          bombers follow a few seconds later on a flank route. A strike
--          waits while the escort can't match the known enemy fighters.
--   Mass   AIR keeps its planes together until Config.AirMassSize, then
--          sends nearly everything at one strategic target (enemy game
--          ender, experimental, anti-nuke while we own a nuke, the heart of
--          the enemy economy): fighters clear the sky, bombers and
--          gunships right behind. The other AIR player joins.
--   T4 op  an own air experimental leads a team operation: it gathers, AIR
--          fighters and bombers guard it (flying at its pace), then it
--          goes for the enemy ECO's ACU and the bombers dive in on the
--          target once close (AirT4OpStep / JoinAirT4Op).
--   Ender  a scouted enemy game ender is everyone's target: AIR strikes it
--          as soon as it can, land waves leave earlier and take the less
--          defended mid lane to it, fleets sail to the water next to it.
--   Mid    NAVAL sends its first T2 destroyers (and a cruiser) to the water
--          below the mid to help GROUND from the sea (MidSupportStep).
--   T4     experimentals never walk inside the wave: each keeps
--          Config.T4Spacing from the wave and from the others, so a dying
--          one doesn't take its neighbours with it.
--   Search when the team has lost the enemy (Intel.Stale): fleets and
--          torpedo bombers sweep the enemy's deep water (an ACU hiding
--          underwater), land waves walk the enemy bases.
--   Hunt   an enemy ACU seen under water (Intel.SubmergedACUs): torpedo
--          bombers and fleets go for it in groups of two or more, to its
--          last known spot when it is out of sight.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')
local Style = import('/mods/DualGapAI/lua/AI/DualGapStyle.lua')
local LandCmd = import('/mods/DualGapAI/lua/AI/DualGapLandCommand.lua')
local AirCmd = import('/mods/DualGapAI/lua/AI/DualGapAirCommand.lua')
local NavalCmd = import('/mods/DualGapAI/lua/AI/DualGapNavalCommand.lua')

local function ACU()
    return import('/mods/DualGapAI/lua/AI/DualGapACUBehaviors.lua')
end

local Alive = Utils.Alive

local CatLandDF   = categories.LAND * categories.MOBILE - categories.ENGINEER - categories.COMMAND
                    - categories.INDIRECTFIRE - categories.SCOUT - categories.SUBCOMMANDER
local CatLandArty = categories.LAND * categories.MOBILE * categories.INDIRECTFIRE - categories.COMMAND
                    - categories.EXPERIMENTAL
local CatNaval    = categories.NAVAL * categories.MOBILE - categories.ENGINEER
local CatFighter  = categories.AIR * categories.MOBILE * categories.ANTIAIR
                    - categories.BOMBER - categories.GROUNDATTACK - categories.TRANSPORTATION
                    - categories.EXPERIMENTAL - categories.SCOUT
local CatBomber   = categories.AIR * categories.MOBILE * (categories.BOMBER + categories.ANTINAVY)
                    - categories.EXPERIMENTAL
-- Gunships fight armies, not ACUs or game enders: they have their own job.
local CatGunship  = categories.AIR * categories.MOBILE * categories.GROUNDATTACK
                    - categories.BOMBER - categories.ANTINAVY - categories.EXPERIMENTAL
local CatTorpBomber = categories.AIR * categories.MOBILE * categories.ANTINAVY
-- Novax satellites are aimed by DualGapProjects with the artillery priorities.
local CatAirT4    = categories.AIR * categories.MOBILE * categories.EXPERIMENTAL - categories.SATELLITE

local CatNavalTargets = categories.NAVAL - categories.WALL
local CatEnemyAir     = categories.AIR * categories.MOBILE
local CatEnemyFighter = categories.AIR * categories.MOBILE * categories.ANTIAIR - categories.BOMBER - categories.GROUNDATTACK
local CatEnemyLand    = categories.LAND * categories.MOBILE
-- What bombers fly at, after their main target: ACUs, game enders, anti-nukes.
local CatBomberExtras = categories.COMMAND + categories.EXPERIMENTAL * categories.STRUCTURE + categories.NUKE * categories.STRUCTURE
    + categories.ARTILLERY * categories.STRUCTURE * categories.TECH3
    + categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE
local OtherSide = Utils.OtherSide

local function Toward(ctx)
    return (ctx.side == 'LEFT') and 1 or -1
end

local function Shift(p, dx)
    local x = p[1] + dx
    return { x, GetSurfaceHeight(x, p[3]), p[3] }
end

local function FreeUnits(brain, cat)
    local out = {}
    for _, u in ipairs(brain:GetListOfUnits(cat, false)) do
        if Alive(u) and not u.DualGapAssigned and u:GetFractionComplete() >= 1 and u:IsIdleState() then
            table.insert(out, u)
        end
    end
    return out
end

local function Claim(units)
    for _, u in ipairs(units) do u.DualGapAssigned = true end
end

local function Release(units)
    for _, u in ipairs(units) do u.DualGapAssigned = nil end
end

local function AllIdle(units)
    for _, u in ipairs(units) do
        if not u:IsIdleState() then return false end
    end
    return true
end

local function Centroid(units)
    local x, z, n = 0, 0, 0
    for _, u in ipairs(units) do
        local p = u:GetPosition()
        x, z, n = x + p[1], z + p[3], n + 1
    end
    if n == 0 then return nil end
    return { x / n, GetSurfaceHeight(x / n, z / n), z / n }
end

local function MapRadius()
    local x0, z0, x1, z1 = Utils.MapBounds()
    return math.max(x1 - x0, z1 - z0)
end

local function TopTech(brain)
    local best = 1
    for _, f in ipairs(brain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false)) do
        if Alive(f) and f:GetFractionComplete() >= 1 then
            local t = Utils.TechOf(f)
            if t > best then best = t end
        end
    end
    return best
end

-- Exposed for tests: may a gathered group with these units leave? A wave
-- with an experimental needs Config.T4EscortMin other units with it.
function WaveReady(units, size)
    local exps, others = 0, 0
    for _, u in ipairs(units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) then exps = exps + 1 else others = others + 1 end
    end
    if exps > 0 and others < Config.T4EscortMin then return false end
    return exps * Config.ExperimentalWaveWeight + others >= size
end

-- Weight: experimentals count as several units.
local function Weight(units)
    local w = 0
    for _, u in ipairs(units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) then
            w = w + Config.ExperimentalWaveWeight
        else
            w = w + 1
        end
    end
    return w
end

-- Exposed for tests: sideways offsets for n experimentals, alternating
-- sides of the path: +s, -s, +2s, -2s ...
function SpreadOffsets(n, spacing)
    local out = {}
    for i = 1, n do
        local k = math.floor((i + 1) / 2)
        local odd = (i - 2 * math.floor(i / 2)) == 1
        table.insert(out, (odd and 1 or -1) * k * spacing)
    end
    return out
end

-- Unit vector perpendicular to from -> to (x, z).
local function Perp(from, to)
    local dx, dz = to[1] - from[1], to[3] - from[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then return 1, 0 end
    return -dz / len, dx / len
end

-- Exposed for tests: does this unit walk and shoot (moving = level MASTER)
-- rather than attack-move? Artillery and missile launchers can't fire on
-- the move: they still stop.
function FiresOnMove(moving, indirect)
    return moving == true and not indirect
end

-- Weapon target priorities (level MASTER), set once per unit; anti-air
-- weapons keep their own.
local function SetPriorities(u)
    if u.DGPrio then return end
    u.DGPrio = true
    local list = EntityCategoryContains(categories.NAVAL, u) and Config.NavalTargetPriorities or Config.LandTargetPriorities
    local n = (u.GetWeaponCount and u:GetWeaponCount()) or 0
    for i = 1, n do
        local w = u:GetWeapon(i)
        local bp = w and w.GetBlueprint and w:GetBlueprint()
        local rc = bp and bp.RangeCategory
        if w and w.SetWeaponPriorities and rc ~= 'UWRC_AntiAir' then pcall(w.SetWeaponPriorities, w, list) end
    end
end

-- Formation moves through waypoints, facing along the path: attack-move,
-- or (moving: level MASTER) a plain move for the units that fire on the
-- move - they shoot whatever comes in range and keep walking, a moving
-- target is harder to hit than one standing in front of the enemy.
-- Experimentals don't join the formation: each walks its own copy of the
-- path shifted sideways by SpreadOffsets.
function FormationPath(units, path, from, moving)
    units = Utils.FilterAlive(units)
    if table.getn(units) == 0 or table.getn(path) == 0 then return end
    IssueClearCommands(units)
    local exps, movers, stoppers = {}, {}, {}
    for _, u in ipairs(units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) then
            table.insert(exps, u)
        elseif FiresOnMove(moving, EntityCategoryContains(categories.INDIRECTFIRE * categories.LAND, u)) then
            SetPriorities(u)
            table.insert(movers, u)
        else
            table.insert(stoppers, u)
        end
    end
    local start = from or Centroid(units)
    for _, group in ipairs({ movers, stoppers }) do
        if table.getn(group) > 0 then
            local prev = start
            for _, wp in ipairs(path) do
                local p = { wp[1], GetSurfaceHeight(wp[1], wp[3]), wp[3] }
                if group == movers then
                    IssueFormMove(group, p, 'AttackFormation', Utils.FacingDegrees(prev, p))
                else
                    IssueFormAggressiveMove(group, p, 'AttackFormation', Utils.FacingDegrees(prev, p))
                end
                prev = p
            end
        end
    end
    -- Experimentals walk (they shoot on the move) instead of attack-moving:
    -- they don't stop for every tank on the way. Only another experimental
    -- stops them (T4Engage in UpdateWaves).
    local offsets = SpreadOffsets(table.getn(exps), Config.T4Spacing)
    for i, u in ipairs(exps) do
        local prev = start
        for _, wp in ipairs(path) do
            local px, pz = Perp(prev, wp)
            local x, z = wp[1] + px * offsets[i], wp[3] + pz * offsets[i]
            IssueMove({ u }, { x, GetSurfaceHeight(x, z), z })
            prev = wp
        end
    end
end

local function KnownNear(brain, cat, pos, radius)
    local army = brain:GetArmyIndex()
    local out = {}
    for _, e in ipairs(brain:GetUnitsAroundPoint(cat, pos, radius, 'Enemy') or {}) do
        if Intel.Known(e, army) then table.insert(out, e) end
    end
    return out
end

local function NearestKnown(brain, cat, pos, radius)
    local best, bestD
    for _, e in ipairs(KnownNear(brain, cat, pos, radius)) do
        local d = Utils.Dist2D(pos, e:GetPosition())
        if not bestD or d < bestD then best, bestD = e, d end
    end
    return best
end

---------------------------------------------------------------------------
-- Waves: { units, kind = 'LAND'|'NAVAL', stage }
--   stage 1: following its path; 2: hunting; 'retreat': falling back
---------------------------------------------------------------------------
local function EnemySlots(ctx)
    local out = {}
    for _, s in pairs(RoleManager.GetSlots()) do
        if s.side ~= ctx.side then table.insert(out, s.pos) end
    end
    return out
end

-- The enemy game ender the team piles on: the nearest scouted one to the
-- enemy... any scouted one (they are rare), the first in the list.
function EnderTarget(ctx)
    -- The strategic command's pick (the most dangerous one), else any.
    local t = import('/mods/DualGapAI/lua/AI/DualGapStratCommand.lua').EnderTarget(ctx.side)
    if t then return t end
    return Intel.Enders(ctx.side)[1]
end

-- Water a fleet can shell an enemy game ender from (battleships reach ~130).
function EnderWater(ctx)
    local e = EnderTarget(ctx)
    if not e then return nil end
    if ctx.enderWaterFor == e.unit then return ctx.enderWater end
    ctx.enderWaterFor = e.unit
    ctx.enderWater = Utils.FindNearestWater(e.pos, Config.DeepWaterDepth, 110)
    return ctx.enderWater
end

-- Exposed for tests: where a land wave walks with nothing scouted: the
-- enemy mid choke of its lane, the mirrored enemy base, the other bases.
function LandFallbackStops(choke, groundBase, slots)
    local out = {}
    if choke then table.insert(out, choke) end
    if groundBase then table.insert(out, groundBase) end
    for _, p in ipairs(slots or {}) do
        if p ~= groundBase then table.insert(out, p) end
    end
    return out
end

function LandFallback(ctx)
    local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
    return LandFallbackStops(Routes.GetPoint(zone, OtherSide(ctx.side)), ctx.enemyGroundBase, EnemySlots(ctx))
end

-- Exposed for tests: is p not too far behind a wave at c (toward its own
-- base)?
function ForwardOk(side, c, p)
    local dir = (side == 'LEFT') and 1 or -1
    return (p[1] - c[1]) * dir >= -Config.HuntBehindMax
end

function MoveFire(ctx)
    return Utils.Level(ctx).moveFire == true
end

-- Exposed for tests: the point a moving wave walks to - through a mobile
-- target, `over` beyond it on the line from the wave.
function ThroughPoint(c, t, over)
    local dx, dz = t[1] - c[1], t[3] - c[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1 then return { t[1], t[2], t[3] } end
    return { t[1] + dx / len * over, t[2], t[3] + dz / len * over }
end

-- Exposed for tests: a fleet's strafe around a target: legs back and
-- forth across the line wave -> target, `range` short of the target.
function StrafeLegs(c, t, range, width, legs)
    local dx, dz = c[1] - t[1], c[3] - t[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1 then dx, dz, len = 1, 0, 1 end
    local ux, uz = dx / len, dz / len
    local sx, sz = t[1] + ux * range, t[3] + uz * range
    local px, pz = -uz, ux
    local out = {}
    for i = 1, legs do
        local s = ((i - 2 * math.floor(i / 2)) == 1) and 1 or -1
        table.insert(out, { sx + px * width / 2 * s, 0, sz + pz * width / 2 * s })
    end
    return out
end

-- Level MASTER: land waves walk through mobile targets shooting (and stop
-- for structures - those don't dodge and need killing); fleets strafe.
function HuntOnTheMove(brain, wave, c, t, e)
    local structure = e and EntityCategoryContains(categories.STRUCTURE, e)
    if wave.kind == 'NAVAL' then
        -- Out of the reach of the shore defences seen around the target.
        local range = Config.NavalStrafeRange
        for _, d in ipairs(KnownNear(brain, categories.STRUCTURE * categories.DEFENSE, t, 120)) do
            range = math.max(range, WeaponRange(d:GetBlueprint()) + Config.KiteMargin
                - Utils.Dist2D(d:GetPosition(), t))
        end
        local legs = StrafeLegs(c, t, range, Config.NavalStrafeWidth, Config.NavalStrafeLegs)
        local ok = true
        for _, p in ipairs(legs) do
            if Utils.WaterDepth(p[1], p[3]) < 1.5 then ok = false; break end
        end
        if not ok then
            FormationPath(wave.units, { t }, c, false)
            return
        end
        IssueClearCommands(wave.units)
        for _, u in ipairs(wave.units) do SetPriorities(u) end
        for _, p in ipairs(legs) do IssueMove(wave.units, { p[1], GetSurfaceHeight(p[1], p[3]), p[3] }) end
        return
    end
    if structure or not e then
        FormationPath(wave.units, { t }, c, false)
        return
    end
    FormationPath(wave.units, { ThroughPoint(c, t, Config.MoveThroughOvershoot) }, c, true)
end

local function HuntTarget(brain, ctx, wave, c)
    -- Scouted game enders first, then anything known.
    if wave.kind == 'NAVAL' then
        local w = EnderWater(ctx)
        if w then return w end
    else
        local ender = EnderTarget(ctx)
        if ender then return ender.pos end
    end
    local cat = (wave.kind == 'NAVAL') and (categories.NAVAL + categories.STRUCTURE + categories.COMMAND - categories.WALL)
        or (categories.ALLUNITS - categories.AIR - categories.WALL)
    local best, bestD
    for _, e in ipairs(KnownNear(brain, cat, c, MapRadius())) do
        local p = e:GetPosition()
        if wave.kind == 'NAVAL' or ForwardOk(ctx.side, c, p) then
            local d = Utils.Dist2D(c, p)
            if not bestD or d < bestD then best, bestD = e, d end
        end
    end
    if best then return best:GetPosition(), best end
    -- Nothing known: search. Fleets sweep the enemy's deep water (sonar finds
    -- a hidden ACU), land waves walk to a random enemy base.
    -- Fleets go where the hidden ACU most likely is; each fleet takes the
    -- next clue, so several fleets spread over the search points.
    if wave.kind == 'NAVAL' and Intel.HuntMode(ctx.side) then
        ctx.searchIdx = (ctx.searchIdx or 0) + 1
        local p = Intel.SearchPoint(ctx.side, ctx.searchIdx)
        if p then return p end
    end
    if wave.kind == 'NAVAL' then
        if Intel.Stale(ctx.side) then return Intel.DeepWater(OtherSide(ctx.side)) end
        return nil
    end
    -- Nothing scouted: a land wave doesn't stand at the mid, it walks on -
    -- the enemy's mid, its base, then the other enemy bases.
    local stops = LandFallback(ctx)
    local n = table.getn(stops)
    if n == 0 then return nil end
    -- The next stop that is not behind the wave (else the last one).
    for k = 1, n do
        wave.fallback = (wave.fallback or 0) + 1
        local p = stops[wave.fallback - n * math.floor((wave.fallback - 1) / n)]
        if ForwardOk(ctx.side, c, p) then return p end
    end
    return stops[n]
end

local function NavalStrength(units)
    local s = 0
    for _, u in ipairs(units) do
        if Alive(u) then
            if EntityCategoryContains(categories.EXPERIMENTAL, u) then s = s + 20
            else s = s + ({ 1, 3, 8 })[Utils.TechOf(u)] end
        end
    end
    return s
end

-- Exposed for tests: is a wave stuck? moved: distance in the last check
-- window, fighting: known enemies around it.
function WaveStuck(moved, fighting)
    return moved < Config.WaveStuckDistance and not fighting
end

local CatWaveContact = categories.ALLUNITS - categories.WALL - categories.AIR

local function UnstickWave(brain, ctx, wave, c, now)
    if not wave.checkAt then
        wave.checkAt, wave.checkPos = now, c
        return
    end
    if now - wave.checkAt < Config.WaveStuckSeconds then return end
    local moved = Utils.Dist2D(c, wave.checkPos)
    wave.checkAt, wave.checkPos = now, c
    local fighting = table.getn(KnownNear(brain, CatWaveContact, c, 60)) > 0
    if not WaveStuck(moved, fighting) then return end
    local t = HuntTarget(brain, ctx, wave, c)
    if not t then return end
    wave.stage = 2
    IssueClearCommands(wave.units)
    IssueAggressiveMove(wave.units, { t[1], GetSurfaceHeight(t[1], t[3]), t[3] })
    Utils.Log(brain, 'land wave of ' .. table.getn(wave.units) .. ' was stuck at ' .. math.floor(c[1]) .. ','
        .. math.floor(c[3]) .. ', walks on to ' .. math.floor(t[1]) .. ',' .. math.floor(t[3]))
end

-- The wave's experimentals turn on a known enemy experimental close by
-- (the only thing worth stopping for); otherwise they keep walking.
local CatEnemyT4Ground = categories.EXPERIMENTAL * categories.MOBILE * (categories.LAND + categories.NAVAL)
function T4Engage(brain, wave)
    for _, u in ipairs(wave.units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) and Alive(u) then
            local e = NearestKnown(brain, CatEnemyT4Ground, u:GetPosition(), Config.T4EngageRadius)
            if e and u.DGT4Target ~= e then
                u.DGT4Target = e
                IssueClearCommands({ u })
                IssueAttack({ u }, e)
                Utils.Log(brain, Comms.UnitName(u) .. ' turns on the enemy ' .. Comms.UnitName(e))
            elseif not e and u.DGT4Target then
                u.DGT4Target = nil
                if wave.lastTarget then IssueMove({ u }, wave.lastTarget) end
            end
        end
    end
end

-- Exposed for tests: is a point (world x) in the enemy half for `side`?
function InEnemyHalfX(side, nx)
    if side == 'LEFT' then return nx > 0.5 end
    return nx < 0.5
end

function InEnemyHalf(side, pos)
    return InEnemyHalfX(side, (Utils.Normalise(pos[1], pos[3])))
end

local function UpdateWaves(brain, ctx)
    local now = GetGameTimeSeconds()
    local keep = {}
    for _, wave in ipairs(ctx.waves) do
        wave.units = Utils.FilterAlive(wave.units)
        if Utils.Count(wave.units) > 0 then
            table.insert(keep, wave)
            local c = Centroid(wave.units)
            if wave.kind == 'NAVAL' and wave.stage ~= 'retreat' then
                local enemy = KnownNear(brain, categories.NAVAL * categories.MOBILE, c, 150)
                local ntask = NavalCmd.Task(ctx.side, brain.Name)
                if ntask and ntask.mode == 'DEFEND' and InEnemyHalf(ctx.side, c) and not wave.ender then
                    Utils.Log(brain, 'fleet falls back to the rally (naval command: DEFEND)')
                    FormationPath(wave.units, { Routes.GetPoint('NavalRally', ctx.side) }, c, MoveFire(ctx))
                    wave.stage = 'retreat'
                elseif NavalStrength(enemy) > 1.5 * NavalStrength(wave.units) then
                    ctx.navalThreat = { pos = c, at = GetGameTimeSeconds() }
                    Utils.Log(brain, 'fleet falls back: stronger enemy fleet ahead')
                    FormationPath(wave.units, { Routes.GetPoint('NavalRally', ctx.side) }, c, MoveFire(ctx))
                    wave.stage = 'retreat'
                end
            end
            -- Land command says DEFEND: a wave out in the enemy half falls
            -- back to the own wall instead of being fed in alone.
            local task = (wave.kind == 'LAND') and LandCmd.Task(ctx.side, brain.Name)
            if task and task.mode == 'DEFEND' and wave.stage ~= 'regroup' and not wave.defending
                and not wave.t4only and InEnemyHalf(ctx.side, c) then
                SplitT4(ctx, wave)
                FormationPath(wave.units, { LandRally(ctx, task) }, c, MoveFire(ctx))
                wave.stage = 'regroup'
                Utils.Log(brain, 'land wave of ' .. table.getn(wave.units) .. ' falls back to the wall (land command: DEFEND)')
            end
            if wave.kind == 'LAND' then T4Engage(brain, wave) end
            if wave.kind == 'LAND' and wave.stage ~= 'regroup' and Utils.Level(ctx).micro and not AllIdle(wave.units)
                and wave.tactic ~= 'KITE' then
                UnstickWave(brain, ctx, wave, c, now)
            end
            if AllIdle(wave.units) and wave.tactic ~= 'KITE' then
                wave.checkAt = nil
                if wave.stage == 'retreat' or wave.stage == 'regroup' or wave.raid then
                    Release(wave.units)          -- rejoin the gathering army / fleet
                    wave.units = {}
                else
                    wave.stage = 2
                    local t, e = HuntTarget(brain, ctx, wave, c)
                    if t then
                        wave.lastTarget = t
                        if MoveFire(ctx) then
                            HuntOnTheMove(brain, wave, c, t, e)
                        else
                            FormationPath(wave.units, { t }, c, MoveFire(ctx))
                        end
                    end
                end
            end
        end
    end
    ctx.waves = keep
end

-- Known enemy army mass (land / sea) around a point.
local CatEnemyArmy = categories.MOBILE * (categories.LAND + categories.NAVAL) - categories.ENGINEER
local function EnemyArmyMass(brain, pos, radius)
    local m = 0
    for _, e in ipairs(KnownNear(brain, CatEnemyArmy, pos, radius)) do
        local eco = e:GetBlueprint().Economy
        m = m + ((eco and eco.BuildCostMass) or 0)
    end
    return m
end

-- Exposed for tests: should this player go help the ally at distance d
-- (its own base not under attack itself)?
function ShouldHelp(d, ownDistress)
    return not ownDistress and d <= Config.HelpRange
end

-- Call for help when the base is attacked; remember the nearest ally call
-- to answer (ctx.helpTarget).
local function DistressStep(brain, ctx)
    local mass = EnemyArmyMass(brain, ctx.startPos, Config.DistressRadius)
    local own = mass >= Config.DistressMass
    if own then
        local landMass = 0
        for _, e in ipairs(KnownNear(brain, CatEnemyArmy - categories.NAVAL - categories.AIR, ctx.startPos, Config.DistressRadius)) do
            local eco = e:GetBlueprint().Economy
            landMass = landMass + ((eco and eco.BuildCostMass) or 0)
        end
        Intel.PostDistress(ctx.side, brain.Name, ctx.startPos, mass, landMass)
        local seen = KnownNear(brain, CatEnemyArmy, ctx.startPos, Config.DistressRadius)
        Comms.Say(brain, ctx.side, 'distress:' .. brain.Name, 'My base is under attack by ' .. Comms.Describe(seen)
            .. ' (~' .. math.floor(mass) .. ' mass), help!', ctx.startPos, 'alert')
    end
    ctx.helpTarget = nil
    local bestD
    for _, d in ipairs(Intel.Distresses(ctx.side)) do
        if d.name ~= brain.Name then
            local dist = Utils.Dist2D(d.pos, ctx.startPos)
            if ShouldHelp(dist, own) and (not bestD or dist < bestD) then ctx.helpTarget, bestD = d, dist end
        end
    end
end

-- Exposed for tests: is a land wave any use against this attack (mass of
-- it all, of it on land)? Not against ships or planes alone.
function LandHelpUseful(mass, landMass)
    if not landMass then return true end
    return landMass >= Config.DistressMass / 2 or landMass >= 0.3 * mass
end

-- Land: ready units go defend the ally (any size from HelpWaveMin).
local function HelpLand(brain, ctx)
    local d = ctx.helpTarget
    if not d or not LandHelpUseful(d.mass, d.land) then return false end
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatLandDF)) do table.insert(ready, u) end
    if Utils.Count(ready) < Config.HelpWaveMin then return false end
    Claim(ready)
    FormationPath(ready, { d.pos }, Centroid(ready), MoveFire(ctx))
    table.insert(ctx.waves, { units = ready, kind = 'LAND', stage = 1 })
    Utils.Log(brain, 'land wave of ' .. Utils.Count(ready) .. ' goes to help ' .. d.name)
    Comms.Say(brain, ctx.side, 'help:' .. brain.Name, 'Coming to help with ' .. Utils.Count(ready) .. ' units!', d.pos, 'move')
    return true
end

-- Sea: a fleet goes to the water next to the ally's base.
local function HelpNaval(brain, ctx)
    local d = ctx.helpTarget
    if not d then return false end
    local water = Utils.FindNearestWater(d.pos, Config.DeepWaterDepth, 120)
    if not water then return false end
    local ready = FreeUnits(brain, CatNaval)
    if Utils.Count(ready) < 3 then return false end
    Claim(ready)
    FormationPath(ready, { water }, Centroid(ready), MoveFire(ctx))
    table.insert(ctx.waves, { units = ready, kind = 'NAVAL', stage = 1 })
    Utils.Log(brain, 'fleet of ' .. Utils.Count(ready) .. ' goes to help ' .. d.name)
    return true
end

---------------------------------------------------------------------------
-- Waves gather behind the furthest defence line the player holds
-- (DualGapProjects moves ctx.frontPoint forward as the front advances).
-- Units gather behind the own mid choke, not at an advanced front point:
-- walking there one by one, they were picked off on the way. The wave
-- passes the front point on its way out.
local function LandRally(ctx, task)
    -- On the defence line the land command holds (just behind it).
    if task and task.line and task.zone then
        return Shift(LandCmd.LineAnchor(task.line, task.zone, ctx.side), -Toward(ctx) * 15)
    end
    return Shift(ctx.choke or ctx.frontPoint, -Toward(ctx) * 25)
end

-- Exposed for tests: the rally of a free unit - the nearest of `rallies`
-- (the held line's, and one by every land factory standing ahead of it).
function PickRally(pos, rallies)
    local best, bestD
    for _, r in ipairs(rallies) do
        local d = Utils.Dist2D(pos, r)
        if not bestD or d < bestD then best, bestD = r, d end
    end
    return best, bestD
end

-- Exposed for tests: is a factory at x ahead of the line rally at lineX
-- (dir: +1 the left team, -1 the right)?
function FactoryAhead(x, lineX, dir)
    return dir * (x - lineX) > Config.RallyFactoryAhead
end

local CatLandFactory = categories.FACTORY * categories.LAND * categories.STRUCTURE

-- Every factory its own rally, in line with the fight: one behind the held
-- line sends its units up to the line; one standing ahead of it (a forward
-- factory once the line fell back) keeps them by itself, on its own side -
-- they guard it and join the waves from there instead of walking back to
-- the base.
local function Rallies(brain, ctx, lineRally)
    local out = { lineRally }
    local dir = Toward(ctx)
    for _, f in ipairs(brain:GetListOfUnits(CatLandFactory, false)) do
        if Alive(f) and f:GetFractionComplete() >= 1 then
            local p = f:GetPosition()
            if FactoryAhead(p[1], lineRally[1], dir) then table.insert(out, Shift(p, -dir * 12)) end
        end
    end
    return out
end

-- Exposed for tests: does a free land unit count as gathered?
function RallyReady(dist, idle)
    return dist <= Config.RallyRadius or (idle and dist <= Config.RallyIdleRadius)
end

-- Exposed for tests: the wave's waypoints in an order that only gets
-- closer to the last one (a point that would send the wave back - an own
-- front point already passed, a siege camp beyond the enemy choke - is
-- moved to its place on the way or dropped when it is behind the start).
function OrderPath(start, path)
    local n = table.getn(path)
    if n <= 1 then return path end
    local goal = path[n]
    local startD = Utils.Dist2D(start, goal)
    local mids = {}
    for i = 1, n - 1 do
        local p = path[i]
        if Utils.Dist2D(p, goal) < startD then table.insert(mids, p) end
    end
    table.sort(mids, function(a, b) return Utils.Dist2D(a, goal) > Utils.Dist2D(b, goal) end)
    table.insert(mids, goal)
    return mids
end

-- Exposed for tests: may a raid go for a mex with this much known around
-- it (point defences, army mass)?
function RaidTargetOk(defences, armyMass)
    return defences == 0 and armyMass < Config.RaidMaxEnemyMass
end

local CatRaidMex = categories.STRUCTURE * categories.MASSEXTRACTION
local CatRaidDefence = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE

-- Now and then a few fast units go for a scouted, unguarded enemy mex in
-- the enemy half instead of joining the next wave. Returns true when one
-- left (the rest keep gathering).
function RaidStep(brain, ctx, ready, enemyAtWall, task)
    local now = GetGameTimeSeconds()
    if not ctx.nextRaidAt then ctx.nextRaidAt = now + Style.RandInt(Config.RaidFirst[1], Config.RaidFirst[2]) end
    if now < ctx.nextRaidAt or enemyAtWall or (task and task.mode == 'DEFEND') then return false end
    local size = Style.RandInt(Config.RaidSize[1], Config.RaidSize[2])
    local pool = {}
    for _, u in ipairs(ready) do
        if not EntityCategoryContains(categories.EXPERIMENTAL + categories.INDIRECTFIRE, u) then table.insert(pool, u) end
    end
    if table.getn(pool) < size + Config.RaidKeep then return false end
    ctx.nextRaidAt = now + Style.RandInt(Config.RaidEvery[1], Config.RaidEvery[2])
    local from = Centroid(pool)
    local best, bestD
    for _, m in ipairs(KnownNear(brain, CatRaidMex, from, MapRadius())) do
        local p = m:GetPosition()
        if InEnemyHalf(ctx.side, p)
            and RaidTargetOk(table.getn(KnownNear(brain, CatRaidDefence, p, Config.RaidDefenceRadius)),
                EnemyArmyMass(brain, p, 60)) then
            local d = Utils.Dist2D(p, from)
            if not bestD or d < bestD then best, bestD = m, d end
        end
    end
    if not best then return false end
    table.sort(pool, function(a, b)
        local sa = a:GetBlueprint().Physics.MaxSpeed or 0
        local sb = b:GetBlueprint().Physics.MaxSpeed or 0
        return sa > sb
    end)
    local group = {}
    for i = 1, size do table.insert(group, pool[i]) end
    local taken = {}
    for _, u in ipairs(group) do taken[u] = true end
    for i = table.getn(ready), 1, -1 do
        if taken[ready[i]] then table.remove(ready, i) end
    end
    Claim(group)
    IssueClearCommands(group)
    IssueAttack(group, best)
    IssueAggressiveMove(group, best:GetPosition())
    table.insert(ctx.waves, { units = group, kind = 'LAND', stage = 1, raid = true })
    local p = best:GetPosition()
    Utils.Log(brain, string.format('raid: %d fast units on an enemy mex at %d,%d', size, math.floor(p[1]), math.floor(p[3])))
    return false
end

-- Exposed for tests: is the army at the line overwhelming enough to go
-- and clear the enemy bases?
function AllInWanted(count, ownMass, enemyMass)
    if count < Config.AllInMinUnits then return false end
    return count >= Config.AllInUnits or ownMass >= Config.AllInRatio * enemyMass
end

-- Exposed for tests: the enemy bases of a group, nearest first from
-- `first` and then each next nearest to the last (a walking order).
function BaseChain(first, bases, radius)
    local left = {}
    for _, p in ipairs(bases) do
        if Utils.Dist2D(p, first) <= radius then table.insert(left, p) end
    end
    local out, at = {}, first
    while table.getn(left) > 0 do
        local bi, bd
        for i, p in ipairs(left) do
            local d = Utils.Dist2D(p, at)
            if not bd or d < bd then bi, bd = i, d end
        end
        at = table.remove(left, bi)
        table.insert(out, at)
    end
    return out
end

local function MassOf(units)
    local m = 0
    for _, u in ipairs(units) do
        local eco = u:GetBlueprint().Economy
        m = m + ((eco and eco.BuildCostMass) or 0)
    end
    return m
end

local function AllInStep(brain, ctx, ready, rally, task)
    if not ctx.enemyGroundBase then return false end
    local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
    local enemyMass = EnemyArmyMass(brain, rally, 250) + EnemyArmyMass(brain, Routes.GetPoint(zone, OtherSide(ctx.side)), 150)
    if not AllInWanted(Utils.Count(ready), MassOf(ready), enemyMass) then return false end
    -- Everything free goes, not only what stands at the rally.
    local army, seen = {}, {}
    for _, u in ipairs(ready) do table.insert(army, u); seen[u] = true end
    for _, u in ipairs(FreeUnits(brain, CatLandDF)) do
        if not seen[u] and not InEnemyHalf(ctx.side, u:GetPosition()) then table.insert(army, u) end
    end
    local path = {}
    if task and task.line and task.zone then path = LandCmd.LinePath(task.line, task.zone, ctx.side) end
    for _, b in ipairs(BaseChain(ctx.enemyGroundBase, EnemySlots(ctx), Config.AllInBaseRadius)) do table.insert(path, b) end
    Claim(army)
    FormationPath(army, path, rally, MoveFire(ctx))
    table.insert(ctx.waves, { units = army, kind = 'LAND', stage = 1, allIn = true })
    Utils.Log(brain, string.format('all-in: %d units (%d mass vs %d seen) to clear their bases', Utils.Count(army),
        MassOf(army), enemyMass))
    Comms.Say(brain, ctx.side, 'allin:' .. brain.Name, 'All in: ' .. Utils.Count(army) .. ' units going to clear their bases!',
        ctx.enemyGroundBase, 'attack')
    return true
end

local function LandStep(brain, ctx)
    if HelpLand(brain, ctx) then return end
    local rally = LandRally(ctx)
    local ready = {}
    -- Units sent to support the other mid stay there while the task lasts
    -- (no walking home the moment the wave is done).
    local task0 = LandCmd.Task(ctx.side, brain.Name)
    rally = LandRally(ctx, task0)
    local holdAt = task0 and task0.mode == 'SUPPORT' and task0.support and LandCmd.ZonePoint(task0.support, ctx.side, task0.line)
    local rallies = Rallies(brain, ctx, rally)
    for _, u in ipairs(FreeUnits(brain, CatLandDF)) do
        local p = u:GetPosition()
        local own, d = PickRally(p, rallies)
        if RallyReady(d, u:IsIdleState()) then
            table.insert(ready, u)
        elseif u:IsIdleState() and not (holdAt and Utils.Dist2D(p, holdAt) <= Config.RallyIdleRadius) then
            IssueMove({ u }, own)
        end
    end
    local atWall = KnownNear(brain, CatEnemyLand, rally, 70)
    local enemyAtWall = table.getn(atWall) >= 5
    if enemyAtWall then
        Comms.Say(brain, ctx.side, 'wall:' .. brain.Name, 'Enemy at my wall: ' .. Comms.Describe(atWall) .. '. Need help here!',
            ctx.choke, 'alert')
    end
    local size = Config.WaveSize[TopTech(brain)] or 10
    local ender = EnderTarget(ctx)
    if ender then size = math.max(4, math.floor(size * Config.EnderWaveShare)) end
    -- Land command task (PUSH / HOLD / DEFEND / SUPPORT), when there is one.
    local task = LandCmd.Task(ctx.side, brain.Name)
    if task then size = math.max(4, math.floor(size * task.scale)) end
    -- This wave's manoeuvre (rolled anew after every wave).
    ctx.manoeuvre = ctx.manoeuvre or Style.RollManoeuvre()
    if ctx.manoeuvre == 'DOUBLE' then size = math.floor(size * Config.DoubleWaveScale) end
    if RaidStep(brain, ctx, ready, enemyAtWall, task) then return end
    if not enemyAtWall and AllInStep(brain, ctx, ready, rally, task) then return end
    local holdBack = task and task.mode == 'DEFEND' and not enemyAtWall and not ender
    if not holdBack and task and task.mode == 'SUPPORT' and not enemyAtWall and not ender
        and WaveReady(ready, size) then
        local to = LandCmd.ZonePoint(task.support, ctx.side, task.line)
        Claim(ready)
        FormationPath(ready, { to }, rally, MoveFire(ctx))
        table.insert(ctx.waves, { units = ready, kind = 'LAND', stage = 1 })
        Utils.Log(brain, 'land wave of ' .. Utils.Count(ready) .. ' supports the ' .. task.support .. ' mid (land command)')
    elseif not holdBack and (WaveReady(ready, size) or (enemyAtWall and Utils.Count(ready) >= 4)) then
        local enemy = OtherSide(ctx.side)
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        -- Through the own front, over the enemy's mid choke, on to its base.
        local path = { ctx.frontPoint or ctx.choke, Routes.GetPoint(zone, enemy) }
        -- On the lines: the zone's points on every line ahead, straight on.
        local mt = task and task.zone and Style.ManoeuvreT(ctx.manoeuvre, task.zone)
        if task and task.line and task.zone then path = LandCmd.LinePath(task.line, task.zone, ctx.side, nil, mt) end
        if ender and not enemyAtWall then
            -- Everyone on the game ender, through the mid lane with less
            -- known enemy army: the sneaky way in.
            local up, low = Routes.GetPoint('ChokeUpper', enemy), Routes.GetPoint('ChokeLower', enemy)
            local lane = (table.getn(KnownNear(brain, CatEnemyLand, up, 120))
                <= table.getn(KnownNear(brain, CatEnemyLand, low, 120))) and up or low
            path = { (task and task.line and task.zone) and LandCmd.LineAnchor(math.min(task.line + 1, LandCmd.LineCount() - 1), task.zone, ctx.side)
                or ctx.frontPoint or ctx.choke, lane, ender.pos }
            Comms.Say(brain, ctx.side, 'enderwave:' .. brain.Name, 'Going for their game ender with '
                .. Utils.Count(ready) .. ' units!', ender.pos, 'attack')
        elseif ctx.enemyGroundBase then table.insert(path, ctx.enemyGroundBase) end
        if enemyAtWall then path = { Centroid(atWall) } end
        path = OrderPath(Centroid(ready), path)
        Claim(ready)
        FormationPath(ready, path, rally, MoveFire(ctx))
        table.insert(ctx.waves, { units = ready, kind = 'LAND', stage = 1, defending = enemyAtWall })
        Utils.Log(brain, 'land wave of ' .. Utils.Count(ready) .. (enemyAtWall and ' (defending)' or (' (' .. ctx.manoeuvre .. ')')))
        ctx.manoeuvre = nil
        if not enemyAtWall then
            local where = (zone == 'ChokeLower') and 'lower' or 'upper'
            Comms.Say(brain, ctx.side, 'wave:' .. brain.Name, 'Attacking the ' .. where .. ' mid with '
                .. Utils.Count(ready) .. ' units.', Routes.GetPoint(zone, enemy), 'attack')
        end
    end

    -- Artillery / MML: behind the wall, then follow the last wave out.
    local staging = Shift(rally, -Toward(ctx) * 15)
    local arty = {}
    for _, u in ipairs(FreeUnits(brain, CatLandArty)) do
        if Utils.Dist2D(u:GetPosition(), staging) > 15 then IssueMove({ u }, staging)
        else table.insert(arty, u) end
    end
    local landWaveOut = false
    for _, w in ipairs(ctx.waves) do if w.kind == 'LAND' then landWaveOut = true end end
    if Utils.Count(arty) >= Config.ArtyWaveSize and landWaveOut then
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        Claim(arty)
        FormationPath(arty, { ctx.choke, Routes.GetPoint(zone, OtherSide(ctx.side)) }, staging, MoveFire(ctx))
        table.insert(ctx.waves, { units = arty, kind = 'LAND', stage = 1 })
    end
end

-- Water spots for the mid support: by the own lower mid choke, the centre,
-- and by the enemy's choke (map knowledge, cached).
function MidWater(side)
    local enemy = OtherSide(side)
    local depth = 3
    return Utils.FindNearestWater(Routes.GetPoint('ChokeLower', side), depth, 200),
        Utils.FindNearestWater(Routes.GetPoint('LandCenter', side), depth, 200),
        Utils.FindNearestWater(Routes.GetPoint('ChokeLower', enemy), depth, 200)
end

-- Exposed for tests: how many destroyers / cruisers the mid support wants.
function MidSupportWanted(waterPushed)
    local d = waterPushed and Config.MidSupportDestroyersPushed or Config.MidSupportDestroyers
    return d, Config.MidSupportCruisers
end

local function MidSupportStep(brain, ctx)
    if not Utils.HasDuty(ctx, 'NAVAL') then return end
    if not ctx.midWater then
        local own, centre, enemyW = MidWater(ctx.side)
        if not own then return end
        ctx.midWater = { own = own, centre = centre or own, enemy = enemyW }
    end
    local w = ctx.midWater
    ctx.midShips = Utils.FilterAlive(ctx.midShips or {})
    local ntask = NavalCmd.Task(ctx.side, brain.Name)
    local push = ctx.waterPushed or (ntask and ntask.mode == 'PUSH')
    local wantD, wantC = MidSupportWanted(push)
    if ntask and ntask.mode == 'SUPPORT_MID' then wantD = wantD + Config.NavalMidSupportExtra end
    local destroyer = Utils.FactionId(brain, 'T2Destroyer')
    local cruiser = Utils.FactionId(brain, 'T2Cruiser')
    local haveD, haveC = 0, 0
    for _, u in ipairs(ctx.midShips) do
        local id = u:GetBlueprint().BlueprintId
        if id == destroyer then haveD = haveD + 1 elseif id == cruiser then haveC = haveC + 1 end
    end
    local fresh = {}
    for _, u in ipairs(FreeUnits(brain, CatNaval)) do
        local id = u:GetBlueprint().BlueprintId
        if id == destroyer and haveD < wantD then
            haveD = haveD + 1
            table.insert(fresh, u)
        elseif id == cruiser and haveC < wantC then
            haveC = haveC + 1
            table.insert(fresh, u)
        end
    end
    if table.getn(fresh) > 0 then
        Claim(fresh)
        for _, u in ipairs(fresh) do table.insert(ctx.midShips, u) end
        if not ctx.midSupportSaid then
            ctx.midSupportSaid = true
            Comms.Say(brain, ctx.side, 'midnavy:' .. brain.Name, 'Destroyers coming to the mid to help ground from the water.',
                w.own, 'move')
        end
        Utils.Log(brain, table.getn(fresh) .. ' ships join the mid support (' .. table.getn(ctx.midShips) .. ' there)')
    end
    -- (Re)issue the patrol: new ships, idle ones, or the water got pushed.
    local far = (push and w.enemy) or w.centre
    local key = math.floor(far[1]) .. ':' .. math.floor(far[3])
    local orders = {}
    for _, u in ipairs(ctx.midShips) do
        if u.DGMidKey ~= key or u:IsIdleState() then
            u.DGMidKey = key
            table.insert(orders, u)
        end
    end
    if table.getn(orders) > 0 then
        IssueClearCommands(orders)
        IssueMove(orders, w.own)
        IssuePatrol(orders, far)
        IssuePatrol(orders, w.own)
    end
end

-- Exposed for tests: may a fleet that fell back sail again?
function RegroupDone(own, enemy)
    return own >= Config.NavalRegroupRatio * enemy
end

local function NavalStep(brain, ctx)
    MidSupportStep(brain, ctx)
    if HelpNaval(brain, ctx) then return end
    local rally = Routes.GetPoint('NavalRally', ctx.side)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatNaval)) do
        local d = Utils.Dist2D(u:GetPosition(), rally)
        -- FreeUnits are idle: near enough counts as gathered (a big fleet
        -- doesn't fit a small circle), the rest are sent there.
        if d <= Config.NavalRallyIdleRadius then table.insert(ready, u)
        else IssueMove({ u }, rally) end
    end
    local size = Config.NavalFleetSize[TopTech(brain)] or 6
    local ntask = NavalCmd.Task(ctx.side, brain.Name)
    if ntask then size = math.max(2, math.floor(size * ntask.scale)) end
    -- Searching for a hidden ACU: any two ships go.
    if Intel.HuntMode(ctx.side) then size = math.min(size, 2) end
    -- Fleets go for a game ender at full size: small groups only die one
    -- after another under its guns and the enemy navy.
    local enderWater = EnderWater(ctx)
    if WaveReady(ready, size) then
        local enemy = OtherSide(ctx.side)
        if enderWater then
            Claim(ready)
            FormationPath(ready, { Routes.GetPoint('BasinCenter', ctx.side), enderWater }, rally, MoveFire(ctx))
            table.insert(ctx.waves, { units = ready, kind = 'NAVAL', stage = 1, ender = true })
            Utils.Log(brain, 'fleet of ' .. Utils.Count(ready) .. ' sails for the enemy game ender')
            Comms.Say(brain, ctx.side, 'fleet:' .. brain.Name, 'Fleet going for their game ender.', enderWater, 'attack')
            return
        end
        -- Naval command: hold the fleet at home, or take it to the own mid.
        if ntask and ntask.mode == 'DEFEND' and not Intel.HuntMode(ctx.side) then return end
        if ntask and ntask.mode == 'SUPPORT_MID' then
            local own = MidWater(ctx.side)
            if own then
                Claim(ready)
                FormationPath(ready, { own }, rally, MoveFire(ctx))
                table.insert(ctx.waves, { units = ready, kind = 'NAVAL', stage = 1 })
                Utils.Log(brain, 'fleet of ' .. Utils.Count(ready) .. ' sails to the own mid (naval command: SUPPORT_MID)')
                return
            end
        end
        local ahead = KnownNear(brain, categories.NAVAL * categories.MOBILE, Routes.GetPoint('BasinCenter', ctx.side), 200)
        if NavalStrength(ahead) > 1.5 * NavalStrength(ready) then return end   -- wait, keep massing
        -- After falling back: out again only clearly stronger than what we
        -- ran from, not with one more ship.
        local th = ctx.navalThreat
        if th and GetGameTimeSeconds() - th.at < Config.NavalRegroupSeconds then
            local enemyThere = NavalStrength(KnownNear(brain, categories.NAVAL * categories.MOBILE, th.pos, 200))
            if not RegroupDone(NavalStrength(ready), enemyThere) then return end
        end
        ctx.navalThreat = nil
        Claim(ready)
        FormationPath(ready, { Routes.GetPoint('BasinCenter', ctx.side), Routes.GetPoint('NavalRally', enemy) }, rally, MoveFire(ctx))
        table.insert(ctx.waves, { units = ready, kind = 'NAVAL', stage = 1 })
        Utils.Log(brain, 'fleet of ' .. Utils.Count(ready) .. ' sails')
        Comms.Say(brain, ctx.side, 'fleet:' .. brain.Name, 'Fleet of ' .. Utils.Count(ready) .. ' moving out.',
            Routes.GetPoint('NavalRally', enemy), 'attack')
    end
end

---------------------------------------------------------------------------
-- Air
---------------------------------------------------------------------------
-- Exposed for tests: the patrol line, each point pushed back while the
-- AA count there (aaAt(point)) reaches the threshold.
-- zList: the stretch of the front this player covers (default: all of it).
function FrontLine(side, toWorld, aaAt, line)
    local pts = {}
    for _, np in ipairs(line or Config.AirPatrolAll) do
        local x, z = np[1], np[2]
        local p = toWorld({ x, z }, side)
        local steps = 0
        while aaAt(p) >= Config.AAThreat and steps < Config.AirFrontMaxSteps do
            steps = steps + 1
            x = x - Config.AirFrontStep
            p = toWorld({ x, z }, side)
        end
        table.insert(pts, p)
    end
    return pts
end

local function LineKey(pts)
    local s = ''
    for _, p in ipairs(pts) do s = s .. math.floor(p[1]) .. '/' .. math.floor(p[3]) .. ',' end
    return s
end

-- Is pos behind the own front line, in this player's stretch of it (with
-- a little margin north and south)?
local function BehindFront(ctx, pos)
    local nx, nz = Utils.Normalise(pos[1], pos[3])
    if ctx.side == 'RIGHT' then nx = 1 - nx end
    local zl = ctx.airZones or Config.AirPatrolAll
    local lineX = 0
    for _, np in ipairs(zl) do lineX = math.max(lineX, np[1]) end
    if nx >= lineX then return false end
    local zmin, zmax = zl[1][2], zl[table.getn(zl)][2]
    if zmin > 0.26 then zmin = zmin - 0.06 else zmin = -1 end   -- the outer edges
    if zmax < 0.80 then zmax = zmax + 0.06 else zmax = 2 end    -- reach the map edge
    return nz >= zmin and nz <= zmax
end

local function FreeFighters(ctx)
    local out = {}
    for _, u in ipairs(ctx.fighters) do
        if not u.DGIntercept and not u.DGEscort then table.insert(out, u) end
    end
    return out
end

local function Nearest(units, pos, n)
    local list = {}
    for _, u in ipairs(units) do table.insert(list, { u = u, d = Utils.Dist2D(u:GetPosition(), pos) }) end
    table.sort(list, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(n, table.getn(list)) do table.insert(out, list[i].u) end
    return out
end

-- Known enemy aircraft behind our front: the nearest free patrol fighters
-- go after them (several per enemy), then return to the patrol.
-- Exposed for tests: is an enemy plane at normalised (nx, nz) (left-team
-- view) over this player's part of the own half, near allied units?
function MidCover(nx, nz, zl, alliesNear)
    if nx >= Config.MidCoverX or not alliesNear then return false end
    local zmin, zmax = zl[1][2], zl[table.getn(zl)][2]
    if zmin > 0.1 then zmin = zmin - 0.06 else zmin = -1 end
    if zmax < 0.9 then zmax = zmax + 0.06 else zmax = 2 end
    return nz >= zmin and nz <= zmax
end

local CatAlliedGround = (categories.LAND + categories.NAVAL + categories.STRUCTURE) - categories.WALL
local CatHitsGround = categories.BOMBER + categories.GROUNDATTACK + categories.EXPERIMENTAL + categories.ANTINAVY

local function OverMid(brain, ctx, pos)
    local nx, nz = Utils.Normalise(pos[1], pos[3])
    if ctx.side == 'RIGHT' then nx = 1 - nx end
    local near = Utils.CountAround(brain, CatAlliedGround, pos, Config.MidCoverRadius, 'Ally') > 0
    return MidCover(nx, nz, ctx.airZones or Config.AirPatrolAll, near)
end

-- Exposed for tests: an enemy air experimental at normalised x (own-team
-- view) is everyone's business anywhere in the own half.
function T4InOwnHalf(nx, isExperimental)
    return isExperimental and nx < 0.5
end

function InOwnHalfT4(ctx, e, p)
    local nx = Utils.Normalise(p[1], p[3])
    if ctx.side == 'RIGHT' then nx = 1 - nx end
    return T4InOwnHalf(nx, EntityCategoryContains(categories.EXPERIMENTAL, e))
end

local function Intercept(brain, ctx, now)
    local threats = {}
    for _, e in ipairs(KnownNear(brain, CatEnemyAir, ctx.startPos, MapRadius())) do
        local p = e:GetPosition()
        if BehindFront(ctx, p) or OverMid(brain, ctx, p) or InOwnHalfT4(ctx, e, p) then table.insert(threats, e) end
    end
    -- Air experimentals first: their escort must not soak up the fighters.
    local ordered = {}
    for _, e in ipairs(threats) do
        if EntityCategoryContains(categories.EXPERIMENTAL, e) then table.insert(ordered, 1, e) else table.insert(ordered, e) end
    end
    threats = ordered
    for _, e in ipairs(threats) do
        local p = e:GetPosition()
        local isT4 = EntityCategoryContains(categories.EXPERIMENTAL, e)
        local covered = false
        local onIt = 0
        for _, u in ipairs(ctx.fighters) do
            if u.DGIntercept and u.DGInterceptTarget == e then onIt = onIt + 1 end
            -- A plane is covered by fighters already busy around it; a T4
            -- only by fighters sent at the T4 itself.
            if not isT4 and u.DGIntercept and u.DGInterceptPos and Utils.Dist2D(u.DGInterceptPos, p) < 60 then covered = true end
        end
        if isT4 and onIt >= Config.InterceptT4 then covered = true end
        if not covered then
            local group, heavy = 0, 0
            for _, o in ipairs(threats) do
                if Utils.Dist2D(o:GetPosition(), p) < 40 then
                    group = group + 1
                    if EntityCategoryContains(CatHitsGround, o) then heavy = heavy + 1 end
                end
            end
            -- Bombers, gunships and air T4s hitting our army get more fighters.
            local want = math.max(Config.InterceptMin, Config.InterceptPerEnemy * group,
                Config.MidCoverPerBomber * heavy)
            -- An air experimental (a Czar going for our ECO): every free fighter.
            if EntityCategoryContains(categories.EXPERIMENTAL, e) and Utils.Level(ctx).advanced then
                want = math.max(want, Config.InterceptT4)
            end
            if isT4 then want = math.max(0, want - onIt) end
            local units = Nearest(FreeFighters(ctx), p, want)
            if table.getn(units) > 0 and isT4 and Utils.Level(ctx).advanced then
                -- Against an air T4 the fighters meet first, between our
                -- base and the T4, and hit it together (no trickle into its
                -- escort and guns).
                local gp = { ctx.startPos[1] + (p[1] - ctx.startPos[1]) * Config.T4GatherShare, 0,
                    ctx.startPos[3] + (p[3] - ctx.startPos[3]) * Config.T4GatherShare }
                gp[2] = GetSurfaceHeight(gp[1], gp[3])
                IssueClearCommands(units)
                IssueMove(units, gp)
                ctx.t4Packs = ctx.t4Packs or {}
                table.insert(ctx.t4Packs, { target = e, units = units, point = gp, at = now })
            elseif table.getn(units) > 0 then
                IssueClearCommands(units)
                IssueAttack(units, e)
                IssueAggressiveMove(units, p)
                for _, u in ipairs(units) do
                    u.DGIntercept, u.DGInterceptPos, u.DGLine = now + Config.InterceptSeconds, p, nil
                    u.DGInterceptTarget = e
                end
                Utils.Log(brain, table.getn(units) .. ' fighters intercept ' .. group .. ' aircraft behind the front')
            end
        end
    end
end

-- Exposed for tests: send a sweep? free: own free fighters, enemy: known
-- enemy fighters, since: seconds since the last one.
function SweepWanted(free, enemy, since, mode)
    if mode == 'DEFEND' then return false end
    local min, ratio = Config.AirSweepMin, Config.AirSweepRatio
    if mode == 'DOMINATE' then min, ratio = Config.AirSweepMinDominate, Config.AirSweepRatioDominate end
    if since < Config.AirSweepCooldown or free < min then return false end
    return free >= ratio * enemy
end

-- Air superiority: the fighters fly over the enemy's side of the front
-- (its patrol line, where the AA allows) and kill its fighters there.
local function SweepStep(brain, ctx, now)
    local sw = ctx.sweep
    if sw then
        sw.units = Utils.FilterAlive(sw.units)
        if table.getn(sw.units) == 0 or now > sw.untilAt or (now - sw.at > 20 and AllIdle(sw.units)) then
            for _, u in ipairs(sw.units) do u.DGEscort, u.DGLine = nil, nil end
            ctx.sweep = nil
        end
        return
    end
    if not Utils.HasDuty(ctx, 'AIR') or not Utils.Level(ctx).advanced then return end
    local free = FreeFighters(ctx)
    local enemy = table.getn(KnownNear(brain, CatEnemyFighter, ctx.startPos, MapRadius()))
    local task = AirCmd.Task(ctx.side, brain.Name)
    if not SweepWanted(table.getn(free), enemy, now - (ctx.sweepAt or -1000), task and task.mode) then return end
    local pts = {}
    for _, np in ipairs(ctx.airZones or Config.AirPatrolAll) do
        local p = Utils.ToWorld({ np[1], np[2] }, OtherSide(ctx.side))
        if Intel.AAThreat(ctx.side, p) < Config.AAThreat then table.insert(pts, p) end
    end
    if table.getn(pts) == 0 then return end
    local keep = math.floor(table.getn(free) * Config.AirSweepHomeShare)
    local units = Nearest(free, pts[1], table.getn(free) - keep)
    if table.getn(units) == 0 then return end
    for _, u in ipairs(units) do u.DGEscort, u.DGLine = true, nil end
    IssueClearCommands(units)
    for _, p in ipairs(pts) do IssueAggressiveMove(units, p) end
    ctx.sweep = { units = units, at = now, untilAt = now + Config.AirSweepSeconds }
    ctx.sweepAt = now
    Utils.Log(brain, 'air sweep: ' .. table.getn(units) .. ' fighters over the enemy front (' .. enemy .. ' enemy fighters known)')
end

-- Fighter packs gathering against an air T4: go in together once most of
-- the pack is at the meeting point (or after AirGatherSeconds).
local function T4PackStep(ctx, now)
    local keep = {}
    for _, pk in ipairs(ctx.t4Packs or {}) do
        pk.units = Utils.FilterAlive(pk.units)
        if Alive(pk.target) and table.getn(pk.units) > 0 then
            if not pk.go then
                local near = 0
                for _, u in ipairs(pk.units) do
                    if Utils.Dist2D(u:GetPosition(), pk.point) < Config.AirGatherRadius then near = near + 1 end
                end
                if GatherDone(near, table.getn(pk.units), now - pk.at) then
                    pk.go = true
                    IssueClearCommands(pk.units)
                    IssueAttack(pk.units, pk.target)
                    IssueAggressiveMove(pk.units, pk.target:GetPosition())
                end
                -- Keep them flagged as intercepting meanwhile.
                for _, u in ipairs(pk.units) do u.DGIntercept = now + Config.InterceptSeconds end
            end
            if not pk.go then table.insert(keep, pk) end
        end
    end
    ctx.t4Packs = keep
end

local function FightersStep(brain, ctx, now)
    local line = FrontLine(ctx.side, Utils.ToWorld, function(p) return Intel.AAThreat(ctx.side, p) end, ctx.airZones)
    local key = LineKey(line)
    if ctx.airLineKey and key ~= ctx.airLineKey then Utils.Log(brain, 'air patrol line moved (enemy AA)') end
    ctx.airLineKey = key
    local fresh = FreeUnits(brain, CatFighter)
    Claim(fresh)
    ctx.fighters = Utils.FilterAlive(ctx.fighters or {})
    for _, u in ipairs(fresh) do table.insert(ctx.fighters, u) end

    Intercept(brain, ctx, now)
    T4PackStep(ctx, now)
    SweepStep(brain, ctx, now)

    -- Back to the patrol: interceptors that are done, new fighters, and
    -- everyone when the line moved.
    local patrol = {}
    for _, u in ipairs(ctx.fighters) do
        -- An escort with nothing left to do (its strike or op is over, or
        -- it was never released) goes back to the patrol instead of
        -- hanging over the enemy base.
        if u.DGEscort and u:IsIdleState() and not u.DGIdleSince then u.DGIdleSince = now end
        if not u:IsIdleState() then u.DGIdleSince = nil end
        if u.DGEscort and u.DGIdleSince and now - u.DGIdleSince > Config.EscortIdleSeconds then
            u.DGEscort, u.DGLine, u.DGIdleSince = nil, nil, nil
        end
        if u.DGIntercept and (now > u.DGIntercept or u:IsIdleState()) then
            u.DGIntercept, u.DGInterceptPos, u.DGInterceptTarget = nil, nil, nil
        end
        if not u.DGIntercept and not u.DGEscort and u.DGLine ~= key then
            u.DGLine = key
            table.insert(patrol, u)
        end
    end
    if table.getn(patrol) > 0 then
        IssueClearCommands(patrol)
        for _, p in ipairs(line) do IssuePatrol(patrol, p) end
    end
end

local function Clamp(p)
    local x0, z0, x1, z1 = Utils.MapBounds()
    local x = math.max(x0 + 20, math.min(x1 - 20, p[1]))
    local z = math.max(z0 + 20, math.min(z1 - 20, p[3]))
    return { x, GetSurfaceHeight(x, z), z }
end

-- Bombers' detour: to the side of the direct line with less known AA.
local function FlankPoint(ctx, from, to)
    local mid = { (from[1] + to[1]) / 2, 0, (from[3] + to[3]) / 2 }
    local px, pz = Perp(from, to)
    local off = Utils.Dist2D(from, to) * Config.BomberFlankShare
    local a = Clamp({ mid[1] + px * off, 0, mid[3] + pz * off })
    local b = Clamp({ mid[1] - px * off, 0, mid[3] - pz * off })
    if Intel.AAThreat(ctx.side, b, 120) < Intel.AAThreat(ctx.side, a, 120) then return b end
    return a
end

-- Exposed for tests: the AA cost of flying a polyline (sampled every
-- AirRouteSample along it; the last AirRouteSkipEnd before the target are
-- left out - the target's own AA is paid on every route).
function AirRouteCost(points, aaAt)
    local cost = 0
    local n = table.getn(points)
    local total = 0
    for i = 2, n do total = total + Utils.Dist2D(points[i - 1], points[i]) end
    local walked = 0
    for i = 2, n do
        local a, b = points[i - 1], points[i]
        local len = Utils.Dist2D(a, b)
        local t = 0
        while t < len do
            if walked + t < total - Config.AirRouteSkipEnd then
                local k = t / math.max(len, 0.01)
                cost = cost + aaAt({ a[1] + (b[1] - a[1]) * k, 0, a[3] + (b[3] - a[3]) * k })
            end
            t = t + Config.AirRouteSample
        end
        walked = walked + len
    end
    return cost
end

-- Waypoints from `from` to `to` around the known enemy AA (ships included):
-- the direct line, or a dog-leg to either side (near or wide), whichever
-- flies past the least AA. Returns the waypoints before `to`.
function SafeAirPath(ctx, from, to)
    local px, pz = Perp(from, to)
    local mid = { (from[1] + to[1]) / 2, 0, (from[3] + to[3]) / 2 }
    local dist = Utils.Dist2D(from, to)
    local aaAt = function(p) return Intel.AAThreat(ctx.side, p, Config.AirRouteAARadius) end
    local best, bestCost = {}, AirRouteCost({ from, to }, aaAt)
    for _, k in ipairs({ 0.35, -0.35, 0.7, -0.7 }) do
        local wp = Clamp({ mid[1] + px * dist * k, 0, mid[3] + pz * dist * k })
        -- A detour costs a little for its length, so straight wins a tie.
        local cost = AirRouteCost({ from, wp, to }, aaAt) + math.abs(k)
        if cost < bestCost then best, bestCost = { wp }, cost end
    end
    return best
end

-- Exposed for tests: escort size for a strike, or nil to hold it.
function EscortSize(enemyFighters, available)
    if enemyFighters > Config.EscortIgnore and available < math.ceil(enemyFighters * Config.EscortLaunchRatio) then return nil end
    return math.min(available, math.max(Config.EscortMin, math.ceil(enemyFighters * Config.EscortRatio)))
end

local function LaunchStrike(brain, ctx, units, target, staging, now)
    local tpos = target:GetPosition()
    local mid = { (staging[1] + tpos[1]) / 2, 0, (staging[3] + tpos[3]) / 2 }
    local enemyF = table.getn(KnownNear(brain, CatEnemyFighter, tpos, 120))
        + table.getn(KnownNear(brain, CatEnemyFighter, mid, 120))
    local free = FreeFighters(ctx)
    local n = EscortSize(enemyF, table.getn(free))
    if not n then
        if not ctx.strikeHeldAt or now - ctx.strikeHeldAt > 60 then
            ctx.strikeHeldAt = now
            Utils.Log(brain, 'strike held: ' .. enemyF .. ' known enemy fighters, ' .. table.getn(free) .. ' escorts')
        end
        return false
    end
    local escort = Nearest(free, staging, n)
    local route = SafeAirPath(ctx, staging, tpos)
    for _, u in ipairs(escort) do u.DGEscort, u.DGLine = true, nil end
    if table.getn(escort) > 0 then
        -- The escort flies ahead on the route with the least known AA.
        IssueClearCommands(escort)
        for _, wp in ipairs(route) do IssueAggressiveMove(escort, wp) end
        IssueAggressiveMove(escort, tpos)
    end
    Claim(units)
    IssueClearCommands(units)
    ForkThread(function()
        WaitSeconds(Config.BomberDelay)
        local alive = Utils.FilterAlive(units)
        if table.getn(alive) == 0 or not Alive(target) then return end
        for _, wp in ipairs(route) do IssueMove(alive, wp) end
        IssueAttack(alive, target)
        IssueMove(alive, staging)
    end)
    table.insert(ctx.strikes, { units = units, escort = escort, started = now, target = target, staging = staging })
    Utils.Log(brain, 'air strike: ' .. table.getn(units) .. ' bombers, ' .. table.getn(escort) .. ' escorts on '
        .. Comms.UnitName(target))
    Comms.Say(brain, ctx.side, 'strike:' .. brain.Name, 'Air strike going in here.', tpos, 'attack')
    return true
end

local function TorpTargetOk(e)
    -- Torpedoes only reach ships and units under water (a submerged ACU).
    if EntityCategoryContains(categories.COMMAND, e) then return Utils.IsUnderwater(e) end
    return true
end

-- Air: bombers at the attackers (the known enemy unit nearest the ally base).
local function HelpAir(brain, ctx, staging, bombers, now)
    local d = ctx.helpTarget
    if not d or not Utils.HasDuty(ctx, 'AIR') then return false end
    if ctx.helpAirAt and now - ctx.helpAirAt < 45 then return false end
    if Utils.Count(bombers) < Config.T4StrikeMin then return false end
    local target = NearestKnown(brain, CatEnemyArmy, d.pos, Config.DistressRadius)
    if not target then return false end
    if not LaunchStrike(brain, ctx, bombers, target, staging, now) then return false end
    ctx.helpAirAt = now
    Utils.Log(brain, Utils.Count(bombers) .. ' bombers help ' .. d.name)
    return true
end

-- Where the bombers, torpedo bombers and gunships wait: over the base,
-- AirParkBack behind the start position.
function AirPark(ctx)
    return Shift(ctx.startPos, -Toward(ctx) * Config.AirParkBack)
end

-- Gunships: to an ally base calling for help, else at known enemy army on
-- our side of the mid; with nothing to do they wait over the base.
function GunshipStep(brain, ctx, park)
    local free = FreeUnits(brain, CatGunship)
    ctx.gunships = Utils.FilterAlive(ctx.gunships or {})
    for _, u in ipairs(free) do
        u.DualGapAssigned = true
        table.insert(ctx.gunships, u)
    end
    local g = ctx.gunships
    if table.getn(g) == 0 then return end
    local target
    if ctx.helpTarget then target = ctx.helpTarget.pos end
    if not target then
        -- Over the front, or with the land wave that is out pushing.
        local front = ctx.frontPoint or ctx.choke or Routes.GetPoint('Choke', ctx.side)
        for _, w in ipairs(ctx.waves or {}) do
            if w.kind == 'LAND' and table.getn(Utils.FilterAlive(w.units)) > 0 then front = Centroid(Utils.FilterAlive(w.units)) end
        end
        -- Air command: work over the mid the team needs help in (gunships
        -- hunt land armies; the water is the torpedo bombers' business).
        local task = AirCmd.Task(ctx.side, brain.Name)
        local sp = task and task.support and task.support ~= 'WATER' and AirCmd.SupportPoint(task.support, ctx.side)
        if sp then front = sp end
        local e = NearestKnown(brain, CatEnemyLand, front, Config.GunshipFrontRadius)
        if e then target = e:GetPosition() end
    end
    local key = target and (math.floor(target[1] / 40) .. ':' .. math.floor(target[3] / 40)) or 'park'
    if table.getn(g) < Config.GunshipGroupMin and target then key, target = 'park', nil end
    local idle = AllIdle(g)
    if key ~= ctx.gunshipKey or idle then
        ctx.gunshipKey = key
        IssueClearCommands(g)
        if target then
            IssueAggressiveMove(g, target)
            Utils.Log(brain, table.getn(g) .. ' gunships attack the enemy army at ' .. math.floor(target[1]) .. ',' .. math.floor(target[3]))
        else
            -- Nothing to shoot: hover behind the front, ready for the
            -- next target, instead of the long trip home and back.
            local front = ctx.frontPoint or ctx.choke
            local hold = (front and table.getn(g) >= Config.GunshipGroupMin) and Shift(front, -Toward(ctx) * 40) or park
            if Utils.Dist2D(Centroid(g), hold) > 30 then IssueMove(g, hold) end
        end
    end
end

-- The strike's target is dead and the bombers are still out: the next
-- thing worth a bomb around them - an ACU on land first, then game
-- enders / anti-nukes, then an enemy army - instead of flying home over it.
local CatFollowArmy = categories.MOBILE * categories.EXPERIMENTAL * (categories.LAND + categories.NAVAL)
function FollowUp(brain, ctx, st, now)
    if not Utils.Level(ctx).advanced then return end
    if st.search or not st.target or Alive(st.target) or Utils.Count(st.units) == 0 then return end
    if (st.followUps or 0) >= Config.FollowUpMax then return end
    local c = Centroid(st.units)
    if st.staging and Utils.Dist2D(c, st.staging) < 80 then return end
    local r = Config.FollowUpRadius
    local t
    for _, e in ipairs(KnownNear(brain, categories.COMMAND, c, r)) do
        if not Utils.IsUnderwater(e) then t = e; break end
    end
    t = t or NearestKnown(brain, CatBomberExtras, c, r)
        or NearestKnown(brain, categories.STRUCTURE * categories.TECH3 * (categories.ENERGYPRODUCTION + categories.MASSFABRICATION), c, r)
        or NearestKnown(brain, CatFollowArmy, c, r)
    if not t then return end
    st.target, st.followUps, st.started = t, (st.followUps or 0) + 1, now
    IssueClearCommands(st.units)
    IssueAttack(st.units, t)
    if st.staging then IssueMove(st.units, st.staging) end
    Utils.Log(brain, Utils.Count(st.units) .. ' bombers go on to ' .. Comms.UnitName(t) .. ' nearby')
end

local function AirStep(brain, ctx)
    local now = GetGameTimeSeconds()
    FightersStep(brain, ctx, now)

    -- Bombers wait over the own base (under its AA and shields), then
    -- strike. Not over the river: that's where enemy ships and AA are.
    local staging = AirPark(ctx)
    GunshipStep(brain, ctx, staging)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatBomber)) do
        if Utils.Dist2D(u:GetPosition(), staging) > 25 then IssueMove({ u }, staging)
        else table.insert(ready, u) end
    end
    local torps, bombers = {}, {}
    for _, u in ipairs(ready) do
        if EntityCategoryContains(CatTorpBomber, u) then table.insert(torps, u) else table.insert(bombers, u) end
    end
    local stale = Intel.Stale(ctx.side)
    local hunt = Intel.HuntMode(ctx.side)
    -- Torpedo bombers always go after a submerged ACU, two or more at a
    -- time: in sight -> attack it, out of sight -> sweep its last spot;
    -- while the enemy is lost they sweep its deep water with their sonar.
    local torpsBusy = false
    local subACU = NearestKnown(brain, categories.COMMAND, ctx.startPos, MapRadius())
    subACU = subACU and Utils.IsUnderwater(subACU)
    if Utils.Count(torps) >= Config.AirStrikeSize or (hunt and Utils.Count(torps) >= 2)
        or (subACU and Utils.Count(torps) >= Config.TorpACUStrikeMin) then
        -- A small hunting group goes for the hidden ACU only, not for any
        -- ship in the basin.
        local few = Utils.Count(torps) < Config.AirStrikeSize
        local cat = few and categories.COMMAND or (CatNavalTargets + categories.COMMAND)
        -- A bigger group may fly into more AA (a submerged ACU sits under
        -- the base's AA, and torpedoes are the only thing that reach it).
        local maxAA = Config.AAThreat + Utils.Count(torps) / Config.BomberAAPerUnit
        local target = PickStrikeTarget(brain, ctx, categories.COMMAND, staging, false, TorpTargetOk, maxAA)
            or PickStrikeTarget(brain, ctx, cat, staging, false, TorpTargetOk, maxAA)
        if target then
            torpsBusy = LaunchStrike(brain, ctx, torps, target, staging, now)
        elseif hunt or stale then
            ctx.searchIdx = (ctx.searchIdx or 0) + 1
            local deep = Intel.SearchPoint(ctx.side, ctx.searchIdx) or Intel.DeepWater(OtherSide(ctx.side))
            if deep then
                Claim(torps)
                IssueClearCommands(torps)
                IssuePatrol(torps, deep)
                IssuePatrol(torps, Shift(deep, Toward(ctx) * 60))
                table.insert(ctx.strikes, { units = torps, escort = {}, started = now, search = true })
                Utils.Log(brain, Utils.Count(torps) .. ' torpedo bombers search the enemy deep water')
                torpsBusy = true
            end
        end
    end
    if not torpsBusy then GuardHiddenACUs(brain, ctx, torps, now) end
    -- An enemy experimental pushing into our half: bombers go now; an ally
    -- base under attack: bombers go there.
    local defended = DefendAgainstT4(brain, ctx, staging, bombers, torps, now)
        or HelpAir(brain, ctx, staging, bombers, now)
    if defended then bombers = {} end
    local inOp = JoinAirT4Op(brain, ctx, bombers, now)
    if inOp then bombers = {} end
    local massed = (not defended) and (not inOp) and MassAirStep(brain, ctx, staging, bombers, now)
    local airTask = AirCmd.Task(ctx.side, brain.Name)
    if not massed and Utils.Count(bombers) >= Config.AirStrikeSize and not (airTask and airTask.mode == 'DEFEND') then
        -- The bigger the group, the more AA it may fly into. Past
        -- AirRaidMaxAir the strategic targets wait for the mass attack, but
        -- enemy armies at the front still get bombed.
        local maxAA = Config.AAThreat + Utils.Count(bombers) / Config.BomberAAPerUnit
        local target
        if AirCount(brain) < Config.AirRaidMaxAir then target = BomberTarget(brain, ctx, maxAA) end
        if target then LaunchStrike(brain, ctx, bombers, target, staging, now) end
    end

    -- Strikes end when the bombers are back (idle), gone or out of time;
    -- the escort returns to the patrol.
    local keep = {}
    for _, st in ipairs(ctx.strikes) do
        st.units = Utils.FilterAlive(st.units)
        FollowUp(brain, ctx, st, now)
        local timeout = (st.search and 120) or (st.mass and Config.AirMassTimeout) or Config.StrikeTimeout
        local idle = not st.gathering and now - st.started > Config.BomberDelay + 5 and AllIdle(st.units)
        if Utils.Count(st.units) == 0 or idle or now - st.started > timeout then
            Release(st.units)
            for _, u in ipairs(Utils.FilterAlive(st.escort)) do u.DGEscort, u.DGLine = nil, nil end
        else
            table.insert(keep, st)
        end
    end
    ctx.strikes = keep

    AirT4OpStep(brain, ctx, staging, now)
    MassOpStep(brain, ctx, now)

    -- Air experimentals hunt game enders, else the best economy target;
    -- each picks a different target, so they don't crash onto each other.
    local taken = {}
    for _, u in ipairs(FreeUnits(brain, CatAirT4)) do
        local t = BomberTarget(brain, ctx, nil, function(e) return not taken[e] end)
        if t then
            taken[t] = true
            IssueAttack({ u }, t)
        end
    end
end

---------------------------------------------------------------------------
-- Air T4 operation (see the header and Config.T4OpGatherSeconds).
---------------------------------------------------------------------------
-- Exposed for tests: the op's target - the enemy ECO's ACU if known (not
-- under water: a T4 can't reach it there), else the enemy ECO base.
-- acus: { {pos, underwater} }, ecoBase: position or nil.
function T4OpTarget(acus, ecoBase, near)
    local best, bestD
    for _, a in ipairs(acus) do
        local d = ecoBase and Utils.Dist2D(a.pos, ecoBase) or 0
        if not a.underwater and (not ecoBase or d < near) and (not bestD or d < bestD) then best, bestD = a, d end
    end
    return best
end

local function EnemyEcoBase(ctx)
    -- Whoever holds the enemy ECO role now (its heir once the ECO is out).
    return import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua').DutyPositions(OtherSide(ctx.side), 'ECO')[1]
end

local function PickOpTarget(brain, ctx)
    local base = EnemyEcoBase(ctx)
    local list = {}
    for _, e in ipairs(KnownNear(brain, categories.COMMAND, ctx.startPos, MapRadius())) do
        table.insert(list, { pos = e:GetPosition(), underwater = Utils.IsUnderwater(e), unit = e })
    end
    local acu = T4OpTarget(list, base, 200)
    if acu then return acu.unit, acu.pos end
    -- Not seen: the heart of the enemy ECO base (game enders there first).
    for _, rec in ipairs(Intel.Enders(ctx.side)) do
        if base and Utils.Dist2D(rec.pos, base) < 200 then return rec.unit, rec.pos end
    end
    local t = base and NearestKnown(brain, categories.STRUCTURE * categories.TECH3 - categories.WALL, base, 150)
    if t then return t, t:GetPosition() end
    return nil, base
end

-- Exposed for tests: re-issue the group's formation order now?
function OpReissue(lastAt, now, lastAim, aim, strays)
    if not lastAt or not lastAim then return true end
    if strays then return true end
    if Utils.Dist2D(lastAim, aim) > 40 then return true end
    return now - lastAt >= Config.T4OpReissue
end

-- Exposed for tests: the operation's flight path to targetPos for `side`:
-- the route round the map edge on the target's half, from the waypoint
-- nearest to `from` on, then the target. Close to the target already (no
-- waypoint lies between) -> straight at it.
function T4OpPath(side, from, targetPos)
    local _, nz = Utils.Normalise(targetPos[1], targetPos[3])
    local route = (nz < Config.T4RouteSplitZ) and Config.T4RouteUpper or Config.T4RouteLower
    local pts = {}
    for _, np in ipairs(route) do table.insert(pts, Utils.ToWorld(np, side)) end
    local k, kd
    for i, p in ipairs(pts) do
        local d = Utils.Dist2D(p, from)
        if not kd or d < kd then k, kd = i, d end
    end
    local path = {}
    if Utils.Dist2D(from, targetPos) > Utils.Dist2D(pts[k], targetPos) then
        for i = k, table.getn(pts) do table.insert(path, pts[i]) end
    end
    table.insert(path, { targetPos[1], targetPos[2], targetPos[3] })
    return path
end

-- Exposed for tests: where the escort and the bombers fly, relative to the
-- T4 at lp heading for aim: the fighters a screen ahead (between the T4
-- and what it flies into), the bombers tucked in behind it.
function OpStations(lp, aim)
    local d = Utils.Dist2D(lp, aim)
    if d < 1 then return { lp[1], lp[2], lp[3] }, { lp[1], lp[2], lp[3] } end
    local ux, uz = (aim[1] - lp[1]) / d, (aim[3] - lp[3]) / d
    local a = math.min(Config.T4OpScreenAhead, d)
    local screen = { lp[1] + ux * a, lp[2], lp[3] + uz * a }
    local tuck = { lp[1] - ux * Config.T4OpBombersBehind, lp[2], lp[3] - uz * Config.T4OpBombersBehind }
    return screen, tuck
end

-- The march. The T4 flies to its target; every planner tick (5 s) each
-- player's escort is sent to a screen just ahead of it and the bombers to a
-- spot just behind it, so nobody races ahead: they move at the T4's pace,
-- take on enemy fighters around it and soak up ground AA fire first.
-- (Orders are per player: one formation can't mix units of several armies.)
local function MarchOp(brain, ctx, op, now)
    local final = (Alive(op.target) and op.target:GetPosition()) or op.targetPos
    if not final then return end
    -- Fly the route round the map edge, waypoint by waypoint, then the target.
    local aim = final
    op.path = op.path or {}
    local n = table.getn(op.path)
    while op.wp and op.wp < n and Utils.Dist2D(op.lead:GetPosition(), op.path[op.wp]) < Config.T4WaypointReached do
        op.wp = op.wp + 1
    end
    if op.wp and op.wp < n then aim = op.path[op.wp] end
    op.escort = Utils.FilterAlive(op.escort or {})
    op.bombers = Utils.FilterAlive(op.bombers or {})
    local lp = op.lead:GetPosition()
    local close = aim == final and Utils.Dist2D(lp, final) < Config.T4OpAttackRange
    if OpReissue(op.marchAt, now, op.marchAim, aim, false) or close ~= op.wasClose then
        op.marchAt, op.marchAim, op.wasClose = now, { aim[1], aim[2], aim[3] }, close
        IssueClearCommands(op.units)
        if close and Alive(op.target) then IssueAttack(op.units, op.target) else IssueMove(op.units, aim) end
    end
    local screen, tuck = OpStations(lp, aim)
    local facing = Utils.FacingDegrees(lp, aim)
    local byArmy = {}
    for _, u in ipairs(op.escort) do
        local a = u:GetArmy()
        byArmy[a] = byArmy[a] or { f = {}, b = {} }
        table.insert(byArmy[a].f, u)
    end
    if not op.dived then
        for _, u in ipairs(op.bombers) do
            local a = u:GetArmy()
            byArmy[a] = byArmy[a] or { f = {}, b = {} }
            table.insert(byArmy[a].b, u)
        end
    end
    for _, g in pairs(byArmy) do
        if table.getn(g.f) > 0 then
            IssueClearCommands(g.f)
            IssueFormAggressiveMove(g.f, screen, 'GrowthFormation', facing)
        end
        if table.getn(g.b) > 0 then
            IssueClearCommands(g.b)
            IssueFormMove(g.b, tuck, 'GrowthFormation', facing)
        end
    end
end

-- Owner of air experimentals: starts and leads the operation.
function AirT4OpStep(brain, ctx, staging, now)
    local op = ctx.t4Op
    if op then
        op.units = Utils.FilterAlive(op.units)
        if table.getn(op.units) == 0 then
            Utils.Log(brain, 'air T4 operation over')
            ctx.t4Op = nil
            Intel.SetAirT4Op(ctx.side, nil)
            return
        end
        op.lead = op.units[1]
        if op.phase == 'gather' and now - op.started >= Config.T4OpGatherSeconds then
            op.phase = 'go'
            op.target = nil
            Comms.Say(brain, ctx.side, 't4op:' .. brain.Name, 'Our ' .. Comms.UnitName(op.lead)
                .. ' is going in for their ECO commander. Air, stay with it!', op.lead:GetPosition(), 'attack')
        end
        if op.phase == 'go' then
            -- (Re)target when the target is gone; a move to the base without
            -- a target is re-checked every half minute.
            if not Alive(op.target) and not (op.target == nil and op.movedAt and now - op.movedAt < 30) then
                local t, pos = PickOpTarget(brain, ctx)
                if t ~= op.target or not op.targetPos then
                    op.dived, op.marchAt = false, nil
                    Utils.Log(brain, 'air T4 operation: ' .. (t and Comms.UnitName(t) or 'the enemy ECO base'))
                end
                if pos and (t ~= op.target or not op.path) then
                    op.path = T4OpPath(ctx.side, op.lead:GetPosition(), pos)
                    op.wp = 1
                    Utils.Log(brain, 'air T4 operation: route with ' .. (table.getn(op.path) - 1) .. ' waypoints')
                end
                op.target, op.targetPos = t, pos
                op.movedAt = (not t) and now or nil
            end
            MarchOp(brain, ctx, op, now)
            -- Close to the target: the bombers dive in on it.
            if not op.dived and op.targetPos
                and Utils.Dist2D(op.lead:GetPosition(), op.targetPos) < Config.T4OpBomberRange then
                local b = Utils.FilterAlive(op.bombers or {})
                if table.getn(b) > 0 then
                    IssueClearCommands(b)
                    if Alive(op.target) then IssueAttack(b, op.target) end
                    for _, x in ipairs(KnownNear(brain, CatBomberExtras, op.targetPos, 60)) do IssueAttack(b, x) end
                    IssueGuard(b, op.lead)
                    Utils.Log(brain, table.getn(b) .. ' bombers dive in with the air T4')
                end
                op.dived = true
            end
        end
        Intel.SetAirT4Op(ctx.side, op)
        return
    end
    local t4s = FreeUnits(brain, CatAirT4)
    if table.getn(t4s) == 0 then return end
    Claim(t4s)
    IssueClearCommands(t4s)
    IssueMove(t4s, staging)
    ctx.t4OpId = (ctx.t4OpId or 0) + 1
    ctx.t4Op = { units = t4s, lead = t4s[1], phase = 'gather', started = now, escort = {}, bombers = {},
        id = brain:GetArmyIndex() * 1000 + ctx.t4OpId, by = brain:GetArmyIndex() }
    Intel.SetAirT4Op(ctx.side, ctx.t4Op)
    Utils.Log(brain, 'air T4 operation: gathering escort')
    Comms.Say(brain, ctx.side, 't4gather:' .. brain.Name, 'Our ' .. Comms.UnitName(t4s[1])
        .. ' is ready. Air, escort it!', staging, 'move')
end

-- AIR (and the T4's owner): hand fighters and bombers to the team's air T4
-- operation; its leader moves them with the T4. Returns true while this
-- player's planes are in it.
function JoinAirT4Op(brain, ctx, bombers, now)
    local op = Intel.AirT4Op(ctx.side)
    local mine = ctx.opJoin
    if mine and (not op or op.id ~= mine.id or not Alive(op.lead)) then
        -- Operation over: everyone back.
        for _, u in ipairs(Utils.FilterAlive(mine.fighters)) do u.DGEscort, u.DGLine = nil, nil end
        Release(Utils.FilterAlive(mine.bombers))
        ctx.opJoin = nil
        return false
    end
    if not op or not Alive(op.lead) then return false end
    if not Utils.HasDuty(ctx, 'AIR') and op.by ~= brain:GetArmyIndex() then return false end
    if mine then return true end
    ctx.fighters = Utils.FilterAlive(ctx.fighters or {})
    local free = FreeFighters(ctx)
    local n = math.floor(table.getn(free) * Config.T4OpEscortShare)
    local escort = Nearest(free, op.lead:GetPosition(), n)
    local strikers = {}
    for _, u in ipairs(bombers) do table.insert(strikers, u) end
    for _, u in ipairs(FreeUnits(brain, CatBomber - CatTorpBomber)) do
        local dup = false
        for _, v in ipairs(strikers) do if v == u then dup = true; break end end
        if not dup then table.insert(strikers, u) end
    end
    for _, u in ipairs(escort) do u.DGEscort, u.DGLine = true, nil end
    Claim(strikers)
    op.escort = op.escort or {}
    op.bombers = op.bombers or {}
    local all = {}
    for _, u in ipairs(escort) do table.insert(op.escort, u); table.insert(all, u) end
    for _, u in ipairs(strikers) do table.insert(op.bombers, u); table.insert(all, u) end
    -- Gathering: come to the T4 and stay with it. On the march the leader
    -- folds them into the formation at its next order.
    if table.getn(all) > 0 then
        IssueClearCommands(all)
        IssueGuard(all, op.lead)
    end
    op.marchAt = nil
    ctx.opJoin = { id = op.id, fighters = escort, bombers = strikers }
    Utils.Log(brain, 'joins the air T4 operation: ' .. table.getn(escort) .. ' fighters, ' .. table.getn(strikers) .. ' bombers')
    return true
end

---------------------------------------------------------------------------
-- Enemy experimental (land / sea) in the own half: the bombers and gunships
-- at hand strike it with an escort; torpedo bombers join against a ship.
---------------------------------------------------------------------------
local CatEnemyT4Ground = categories.EXPERIMENTAL * categories.MOBILE - categories.AIR

function DefendAgainstT4(brain, ctx, staging, bombers, torps, now)
    if not Utils.HasDuty(ctx, 'AIR') then return false end
    if ctx.t4StrikeAt and now - ctx.t4StrikeAt < 45 then return false end
    local best, bestD
    for _, e in ipairs(KnownNear(brain, CatEnemyT4Ground, ctx.startPos, MapRadius())) do
        local p = e:GetPosition()
        local nx = Utils.Normalise(p[1], p[3])
        if ctx.side == 'RIGHT' then nx = 1 - nx end
        local d = Utils.Dist2D(p, ctx.startPos)
        if nx < Config.MidCoverX and (not bestD or d < bestD) then best, bestD = e, d end
    end
    if not best then return false end
    local group = {}
    for _, u in ipairs(bombers) do table.insert(group, u) end
    if EntityCategoryContains(categories.NAVAL, best) or Utils.IsUnderwater(best) then
        for _, u in ipairs(torps) do table.insert(group, u) end
    end
    if table.getn(group) < Config.T4StrikeMin then return false end
    if not LaunchStrike(brain, ctx, group, best, staging, now) then return false end
    ctx.t4StrikeAt = now
    Utils.Log(brain, 'air defence: ' .. table.getn(group) .. ' bombers on an enemy ' .. Comms.UnitName(best) .. ' in our half')
    Comms.Say(brain, ctx.side, 't4def:' .. brain.Name, 'Bombers coming for their ' .. Comms.UnitName(best) .. '!',
        best:GetPosition(), 'attack')
    return true
end

---------------------------------------------------------------------------
-- Mass air attack (see the header and Config.AirMassSize).
---------------------------------------------------------------------------
local CatAllAir = categories.AIR * categories.MOBILE - categories.ENGINEER - categories.SCOUT - categories.TRANSPORTATION
function AirCount(brain)
    return Utils.Count(brain:GetListOfUnits(CatAllAir, false))
end

-- Exposed for tests: launch a mass attack now? Returns 'ender', 'mass',
-- 'join' or nil.
function MassAirDecision(air, enderKnown, teamStrikeOn, sinceLast, bombers, mode)
    if sinceLast < Config.AirMassCooldown then return nil end
    if enderKnown and air >= Config.AirEnderStrikeMin then return 'ender' end
    -- The enemy rules the sky: only a game ender is worth the losses.
    if mode == 'DEFEND' then return nil end
    local scale = (mode == 'DOMINATE') and Config.AirMassDominateScale or 1
    if teamStrikeOn and air >= Config.AirMassSize * Config.AirMassJoinShare * scale then return 'join' end
    if air >= Config.AirMassSize * scale then return 'mass' end
    if (bombers or 0) >= Config.AirMassBombers * scale then return 'bombers' end
    return nil
end

-- The strategic target: game ender > enemy experimental structure (they
-- are enders too) > anti-nuke while the team owns a nuke > the T3
-- economy structure with the most T3 economy around it (the heart).
local function MassAirTarget(brain, ctx)
    -- The whole air force: assassination first, then a game ender, then
    -- the anti-nuke for our nuke; no mass attack on mexes.
    return BomberTarget(brain, ctx, nil)
end

function MassAirStep(brain, ctx, staging, bombers, now)
    if not Utils.HasDuty(ctx, 'AIR') then return false end
    -- Only what is home and free counts: planes still out on the last
    -- strike or chasing intruders would turn the attack into a trickle.
    ctx.fighters = Utils.FilterAlive(ctx.fighters or {})
    local air = table.getn(FreeFighters(ctx)) + table.getn(FreeUnits(brain, CatBomber - CatTorpBomber))
        + Utils.Count(bombers)
    local team = Intel.AirMass(ctx.side)
    local teamOn = team and now - team.at < 90 and Alive(team.unit)
    local nBombers = table.getn(FreeUnits(brain, CatBomber - CatTorpBomber)) + Utils.Count(bombers)
    local why = MassAirDecision(air, EnderTarget(ctx) ~= nil, teamOn and team.by ~= brain:GetArmyIndex(),
        now - (ctx.airMassAt or -1000), nBombers, (AirCmd.Task(ctx.side, brain.Name) or {}).mode)
    if not why then return false end
    local target = (why == 'join') and team.unit or MassAirTarget(brain, ctx)
    if not Alive(target) then return false end
    local tpos = target:GetPosition()
    -- Not into a wall of AA: the stack must be big enough for the AA there
    -- (a game ender deep in the enemy base waits for a bigger stack).
    if not MassAAOk(Intel.AAThreat(ctx.side, tpos, 50), air) then
        if not ctx.massAAHeldAt or now - ctx.massAAHeldAt > 60 then
            ctx.massAAHeldAt = now
            Utils.Log(brain, 'mass air attack held: ' .. Intel.AAThreat(ctx.side, tpos, 50) .. ' known AA at the target, '
                .. air .. ' planes')
        end
        return false
    end
    ctx.airMassAt = now
    if why ~= 'join' then Intel.SetAirMass(ctx.side, { unit = target, pos = tpos, at = now, by = brain:GetArmyIndex() }) end

    -- Fighters: all but a home guard (the ones nearest our base stay).
    ctx.fighters = Utils.FilterAlive(ctx.fighters or {})
    local free = FreeFighters(ctx)
    local keepHome = math.floor(table.getn(free) * Config.AirMassHomeShare)
    local byDist = {}
    for _, u in ipairs(free) do table.insert(byDist, { u = u, d = Utils.Dist2D(u:GetPosition(), ctx.startPos) }) end
    table.sort(byDist, function(a, b) return a.d > b.d end)
    local escort = {}
    for i = 1, table.getn(byDist) - keepHome do table.insert(escort, byDist[i].u) end
    -- Everyone gathers over the own base first and leaves together
    -- (MassOpStep): planes from the patrol line would otherwise trickle in.
    for _, u in ipairs(escort) do u.DGEscort, u.DGLine = true, nil end
    if table.getn(escort) > 0 then
        IssueClearCommands(escort)
        IssueMove(escort, staging)
    end
    -- Bombers: every free one (raids are off by now), plus air experimentals.
    local strikers = {}
    for _, u in ipairs(bombers) do table.insert(strikers, u) end
    for _, u in ipairs(FreeUnits(brain, CatBomber - CatTorpBomber)) do
        local dup = false
        for _, v in ipairs(strikers) do if v == u then dup = true; break end end
        if not dup then table.insert(strikers, u) end
    end
    for _, u in ipairs(FreeUnits(brain, CatAirT4)) do table.insert(strikers, u) end
    Claim(strikers)
    if table.getn(strikers) > 0 then
        IssueClearCommands(strikers)
        IssueMove(strikers, staging)
    end
    ctx.massOp = { target = target, escort = escort, strikers = strikers, staging = staging, at = now }
    table.insert(ctx.strikes, { units = strikers, escort = escort, started = now, mass = true, target = target,
        staging = staging, gathering = true })
    local what = Comms.UnitName(target)
    Utils.Log(brain, 'mass air attack (' .. why .. '): ' .. table.getn(escort) .. ' fighters, '
        .. table.getn(strikers) .. ' bombers on ' .. what)
    local text = (why == 'join') and ('Joining the air attack on their ' .. what .. ' with ' .. air .. ' planes!')
        or ('Massing all air over the base: ' .. air .. ' planes for their ' .. what .. '!')
    Comms.Say(brain, ctx.side, 'massair:' .. brain.Name, text, tpos, 'attack')
    return true
end

-- Exposed for tests: may a stack of `air` planes go at a target with
-- `aa` known AA around it?
function MassAAOk(aa, air)
    return aa <= Config.AAThreat + air / Config.BomberAAPerUnit
end

-- Exposed for tests: has the stack gathered (share of it within reach of
-- the gathering point) or waited long enough?
function GatherDone(near, total, waited)
    if total == 0 then return true end
    return near / total >= Config.AirGatherShare or waited >= Config.AirGatherSeconds
end

-- The mass attack's gathering: once the stack is together over the own
-- base, fighters go first on the route with the least AA, bombers right
-- behind them, then the target and what is worth it around it, then home.
function MassOpStep(brain, ctx, now)
    local op = ctx.massOp
    if not op then return end
    op.escort = Utils.FilterAlive(op.escort)
    op.strikers = Utils.FilterAlive(op.strikers)
    local all = {}
    for _, u in ipairs(op.escort) do table.insert(all, u) end
    for _, u in ipairs(op.strikers) do table.insert(all, u) end
    if not Alive(op.target) or table.getn(all) == 0 then
        Release(op.strikers)
        for _, u in ipairs(op.escort) do u.DGEscort, u.DGLine = nil, nil end
        for _, st in ipairs(ctx.strikes) do if st.gathering and st.target == op.target then st.units = {} end end
        ctx.massOp = nil
        return
    end
    local near = 0
    for _, u in ipairs(all) do
        if Utils.Dist2D(u:GetPosition(), op.staging) < Config.AirGatherRadius then near = near + 1 end
    end
    if not GatherDone(near, table.getn(all), now - op.at) then return end
    local tpos = op.target:GetPosition()
    local route = SafeAirPath(ctx, op.staging, tpos)
    if table.getn(op.escort) > 0 then
        IssueClearCommands(op.escort)
        for _, wp in ipairs(route) do IssueAggressiveMove(op.escort, wp) end
        IssueAggressiveMove(op.escort, tpos)
    end
    local strikers, target, staging = op.strikers, op.target, op.staging
    local extra = KnownNear(brain, CatBomberExtras, tpos, 60)
    ForkThread(function()
        WaitSeconds(Config.BomberDelay)
        local alive = Utils.FilterAlive(strikers)
        if table.getn(alive) == 0 then return end
        IssueClearCommands(alive)
        for _, wp in ipairs(route) do IssueMove(alive, wp) end
        if Alive(target) then IssueAttack(alive, target) end
        local n = 0
        for _, x in ipairs(extra) do
            if Alive(x) and x ~= target and n < 6 then IssueAttack(alive, x); n = n + 1 end
        end
        IssueMove(alive, staging)
    end)
    for _, st in ipairs(ctx.strikes) do
        if st.gathering and st.target == op.target then st.gathering, st.started = nil, now end
    end
    Utils.Log(brain, 'mass air attack goes in: ' .. near .. '/' .. table.getn(all) .. ' planes gathered, '
        .. table.getn(route) .. ' detour waypoint(s)')
    ctx.massOp = nil
end

-- Torpedo bombers with nothing to strike patrol over the team's hidden
-- ACUs (up to Config.TorpGuardsPerACU each from this bot), killing subs
-- and ships that come for them.
function GuardHiddenACUs(brain, ctx, torps, now)
    ctx.torpGuards = ctx.torpGuards or {}
    local spots = ACU().HideSpots(ctx.side)
    local free = {}
    for _, u in ipairs(torps) do table.insert(free, u) end
    for _, s in ipairs(spots) do
        local key = s.name
        local guards = Utils.FilterAlive(ctx.torpGuards[key] or {})
        ctx.torpGuards[key] = guards
        -- Hunting an enemy ACU: one guard each, the rest go hunting.
        local want = Intel.HuntMode(ctx.side) and Config.TorpGuardsHunt or Config.TorpGuardsPerACU
        while table.getn(guards) > want do
            local g = table.remove(guards)
            Release({ g })
            IssueClearCommands({ g })
        end
        local need = want - table.getn(guards)
        if need > 0 and table.getn(free) > 0 then
            local group = {}
            while need > 0 and table.getn(free) > 0 do
                table.insert(group, table.remove(free))
                need = need - 1
            end
            Claim(group)
            IssueClearCommands(group)
            local p = s.pos
            for _, d in ipairs({ { 30, 0 }, { 0, 30 }, { -30, 0 }, { 0, -30 } }) do
                IssuePatrol(group, { p[1] + d[1], GetSurfaceHeight(p[1] + d[1], p[3] + d[2]), p[3] + d[2] })
            end
            for _, u in ipairs(group) do table.insert(guards, u) end
            Utils.Log(brain, table.getn(group) .. ' torpedo bombers guard the hidden ACU of ' .. key)
        end
    end
    -- Guards of an ACU that came out of the water go back to the pool.
    for key, guards in pairs(ctx.torpGuards) do
        local still = false
        for _, s in ipairs(spots) do if s.name == key then still = true end end
        if not still then
            Release(Utils.FilterAlive(guards))
            ctx.torpGuards[key] = nil
        end
    end
end

-- Exposed for tests: a bomber group's target kind, by priority: an enemy
-- ACU on land (assassination), a game ender, the enemy anti-nuke while the
-- team owns a nuke; else nothing - bombing mexes is a waste.
-- c: { acu = bool, ender = bool, antiNuke = bool, ownNuke = bool }
-- Then the T3 economy (power generators blow up their neighbours), then
-- big static defences / factories; never mexes, never moving armies
-- (bombers miss them - gunships take those).
function BomberTargetKind(c)
    if c.acu then return 'ACU' end
    if c.ender then return 'ENDER' end
    if c.antiNuke and c.ownNuke then return 'ANTINUKE' end
    if c.power then return 'POWER' end
    if c.static then return 'STATIC' end
    return nil
end

local CatBomberEco = categories.STRUCTURE * categories.TECH3 * (categories.ENERGYPRODUCTION + categories.MASSFABRICATION)
local CatBomberMex = categories.STRUCTURE * categories.MASSEXTRACTION * (categories.TECH2 + categories.TECH3)
local CatBomberStatic = categories.STRUCTURE * (categories.ARTILLERY + categories.SHIELD + categories.FACTORY) * (categories.TECH2 + categories.TECH3)
local CatArmyTarget = categories.MOBILE * (categories.LAND + categories.NAVAL) - categories.ENGINEER - categories.COMMAND

-- The known enemy unit in the heaviest army cluster (Config.ArmyStrikeMass
-- or more), the nearest to our front first; known AA below maxAA.
function ArmyTarget(brain, ctx, maxAA)
    local front = ctx.frontPoint or ctx.choke or ctx.startPos
    local best, bestScore
    for _, e in ipairs(KnownNear(brain, CatArmyTarget, front, MapRadius())) do
        local p = e:GetPosition()
        if not maxAA or Intel.AAThreat(ctx.side, p, 50) < maxAA then
            local m = 0
            for _, o in ipairs(KnownNear(brain, CatArmyTarget, p, Config.ArmyStrikeRadius)) do
                local eco = o:GetBlueprint().Economy
                m = m + ((eco and eco.BuildCostMass) or 0)
            end
            if m >= Config.ArmyStrikeMass then
                local score = m / (1 + Utils.Dist2D(p, front) / 200)
                if not bestScore or score > bestScore then best, bestScore = e, score end
            end
        end
    end
    return best
end

local function OwnTeamNuke(brain)
    return Utils.CountAround(brain, categories.NUKE * categories.STRUCTURE, { 512, 0, 512 }, 3000, 'Ally') > 0
end

-- The bomber group's target (see BomberTargetKind): among each kind the one
-- with the least known AA (at most maxAA when given). ok(e) filters.
function BomberTarget(brain, ctx, maxAA, ok)
    local function pick(list)
        local best, bestAA
        for _, e in ipairs(list) do
            local aa = Intel.AAThreat(ctx.side, e:GetPosition(), 50)
            if (not maxAA or aa < maxAA) and (not ok or ok(e)) and (not bestAA or aa < bestAA) then best, bestAA = e, aa end
        end
        return best
    end
    local acus = {}
    for _, e in ipairs(KnownNear(brain, categories.COMMAND, ctx.startPos, MapRadius())) do
        if not Utils.IsUnderwater(e) then table.insert(acus, e) end
    end
    local t = pick(acus)
    if t then return t end
    local enders = {}
    for _, rec in ipairs(Intel.Enders(ctx.side)) do table.insert(enders, rec.unit) end
    t = pick(enders)
    if t then return t end
    if OwnTeamNuke(brain) then
        t = pick(KnownNear(brain, categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE, ctx.startPos, MapRadius()))
        if t then return t end
    end
    -- Then the T3 economy (power blows up its neighbours), then the big
    -- static defences and factories. Bombers miss moving armies - those are
    -- the gunships' job.
    -- Then this player's current focus (re-rolled now and then): the T3
    -- economy (power blows up its neighbours), the upgraded mexes, or the
    -- big static defences and factories. Bombers miss moving armies -
    -- those are the gunships' job.
    local now = GetGameTimeSeconds()
    if not ctx.airFocus or now >= (ctx.airFocusUntil or 0) then
        local f = Style.AirFocus(Style.Rand())
        if f ~= ctx.airFocus then Utils.Log(brain, 'bombers focus: ' .. f) end
        ctx.airFocus, ctx.airFocusUntil = f, now + Config.AirFocusSeconds
    end
    local cats = { eco = CatBomberEco, mex = CatBomberMex, static = CatBomberStatic }
    for _, k in ipairs(Style.FocusOrder(ctx.airFocus)) do
        t = pick(KnownNear(brain, cats[k], ctx.startPos, MapRadius()))
        if t then return t end
    end
    return nil
end

-- Scouted game enders first (if endersOk), then `cat`; among them the
-- least AA-covered. ok(e), when given, filters candidates; maxAA (default
-- Config.AAThreat) is the most known AA a target may have around it.
function PickStrikeTarget(brain, ctx, cat, from, endersOk, ok, maxAA)
    maxAA = maxAA or Config.AAThreat
    local best, bestAA
    if endersOk then
        for _, rec in ipairs(Intel.Enders(ctx.side)) do
            local aa = Intel.AAThreat(ctx.side, rec.pos, 50)
            if aa < maxAA and (not ok or ok(rec.unit)) and (not bestAA or aa < bestAA) then
                best, bestAA = rec.unit, aa
            end
        end
        if best then return best end
    end
    for _, e in ipairs(KnownNear(brain, cat, from, MapRadius())) do
        local aa = Intel.AAThreat(ctx.side, e:GetPosition(), 50)
        if aa < maxAA and (not ok or ok(e)) and (not bestAA or aa < bestAA) then best, bestAA = e, aa end
    end
    return best
end

---------------------------------------------------------------------------
local function ArmyStep(brain, ctx)
    DistressStep(brain, ctx)
    UpdateWaves(brain, ctx)
    LandStep(brain, ctx)
    NavalStep(brain, ctx)
    AirStep(brain, ctx)
end

---------------------------------------------------------------------------
-- Tactics in contact (level MASTER): how a wave fights the enemy in front
-- of it, and damaged units going back for repairs.
---------------------------------------------------------------------------
local rangeCache = {}

-- Exposed for tests: the longest reach of a blueprint's weapons against
-- ground and sea (no anti-air, no death weapons).
function WeaponRange(bp)
    if not bp then return 0 end
    local id = bp.BlueprintId
    if id and rangeCache[id] then return rangeCache[id] end
    local r = 0
    for _, w in ipairs(bp.Weapon or {}) do
        local rc = w.RangeCategory
        if (rc == 'UWRC_DirectFire' or rc == 'UWRC_IndirectFire' or rc == 'UWRC_AntiNavy')
            and w.Label ~= 'DeathWeapon' and not w.DummyWeapon and (w.MaxRadius or 0) > r then
            r = w.MaxRadius
        end
    end
    if id then rangeCache[id] = r end
    return r
end

local function MedianRange(units)
    local list = {}
    for _, u in ipairs(units) do
        local r = WeaponRange(u:GetBlueprint())
        if r > 0 then table.insert(list, r) end
    end
    local n = table.getn(list)
    if n == 0 then return 0 end
    table.sort(list)
    return list[math.floor((n + 1) / 2)]
end

-- Exposed for tests: the tactic for a wave in contact (see Config).
function ChooseTactic(ratio, rangeAdv, fortified, losing, naval, enemyT4)
    if losing then return 'DISENGAGE' end
    if enemyT4 and not naval then return 'T4' end
    if rangeAdv >= Config.KiteRangeEdge and ratio < Config.PushRatio then return 'KITE' end
    if ratio >= Config.PushRatio then return 'PUSH' end
    if ratio < Config.HoldRatio and fortified and not naval then return 'HOLD' end
    if ratio < Config.DisengageRatio then return 'DISENGAGE' end
    return 'CONCAVE'
end

-- atan2 (Lua 5.0 has math.atan2; newer ones math.atan(y, x)).
local function Atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    return math.atan(y, x)
end

-- Exposed for tests: n points on an arc of `arc` degrees around `centre`,
-- `r` from it, facing `from` (the wave); the outer `flank` share of them
-- a further half-arc round the sides.
function ArcPoints(centre, from, r, n, arc, flank)
    local base = Atan2(from[3] - centre[3], from[1] - centre[1])
    local out = {}
    local outer = math.floor(n * flank)
    for i = 1, n do
        local f = (n == 1) and 0 or ((i - 1) / (n - 1) - 0.5)       -- -0.5 .. 0.5
        local spread = arc
        if i <= math.floor(outer / 2) or i > n - (outer - math.floor(outer / 2)) then spread = arc * 1.5 end
        local a = base + f * spread * math.pi / 180
        table.insert(out, { centre[1] + math.cos(a) * r, 0, centre[3] + math.sin(a) * r })
    end
    return out
end

-- Exposed for tests: points to the sides and back of a T4 (angles off the
-- line T4 -> wave), `r` from it.
function FlankPoints(t4, from, r, angles)
    local base = Atan2(from[3] - t4[3], from[1] - t4[1])
    local out = {}
    for _, deg in ipairs(angles) do
        local a = base + deg * math.pi / 180
        table.insert(out, { t4[1] + math.cos(a) * r, 0, t4[3] + math.sin(a) * r })
    end
    return out
end

-- Units sorted across the line wave -> enemy (left to right), so arc spots
-- go to the nearest units without crossing paths.
local function SortAcross(units, c, target)
    local dx, dz = target[1] - c[1], target[3] - c[3]
    local function side(u)
        local p = u:GetPosition()
        return (p[1] - c[1]) * dz - (p[3] - c[3]) * dx
    end
    local list = {}
    for _, u in ipairs(units) do table.insert(list, u) end
    table.sort(list, function(a, b) return side(a) < side(b) end)
    return list
end

-- Exposed for tests: is the fight going badly (loss fractions since contact)?
function Losing(ownLoss, enemyLoss)
    return ownLoss >= Config.LosingOwnLoss and ownLoss > enemyLoss + Config.LosingMargin
end

-- Exposed for tests: the kiting step for distance d to the nearest enemy:
-- BACK out of its reach, IN to the own reach, or STAND and shoot.
function KiteStep(d, ownRange, enemyRange)
    if d < enemyRange + Config.KiteMargin then return 'BACK' end
    if d > ownRange * 0.95 then return 'IN' end
    return 'STAND'
end

-- Exposed for tests: should a damaged unit go back / come back?
-- 'GO', 'DONE', 'KEEP' (repairing on) or nil (fight on).
function RepairState(hp, since, now)
    if since then
        if hp >= Config.RepairDoneHealth or now - since >= Config.RepairMaxSeconds then return 'DONE' end
        return 'KEEP'
    end
    if hp < Config.RepairHealth then return 'GO' end
    return nil
end

-- Exposed for tests: focus fire value of a target (mass per hit point
-- left): the cheapest kill of the most worth first.
function FocusScore(mass, hp)
    return mass / math.max(1, hp)
end

local function FocusTarget(enemies, army, from, range)
    local best, bestS
    for _, e in ipairs(enemies) do
        if Alive(e) and Intel.SeenNow(e, army) and Utils.Dist2D(from, e:GetPosition()) <= range then
            local eco = e:GetBlueprint().Economy
            local s = FocusScore((eco and eco.BuildCostMass) or 0, e:GetHealth())
            if not bestS or s > bestS then best, bestS = e, s end
        end
    end
    return best
end

-- Exposed for tests: does a unit of reach `r` stand off from an enemy of
-- reach `enemyRange` (and how: 'BACK', 'STAND' or nil = go on)?
function StandoffStep(r, enemyRange, d)
    if r < enemyRange + Config.StandoffEdge then return nil end
    if d < enemyRange + Config.KiteMargin then return 'BACK' end
    if d <= r * 0.95 then return 'STAND' end
    return nil
end

local function Nearest(enemies, p)
    local near, d
    for _, e in ipairs(enemies) do
        local dd = Utils.Dist2D(p, e:GetPosition())
        if not d or dd < d then near, d = e, dd end
    end
    return near, d
end

local CatContactEnemy = (categories.MOBILE * (categories.LAND + categories.NAVAL) - categories.ENGINEER - categories.SCOUT)
    + categories.STRUCTURE * categories.DEFENSE * (categories.DIRECTFIRE + categories.INDIRECTFIRE + categories.ANTINAVY)

local function HealthOf(u)
    local m = u:GetMaxHealth()
    if not m or m <= 0 then return 1 end
    return u:GetHealth() / m
end

-- Mass x health; the enemy's health only where it is in sight right now.
local function Strength(units, army)
    local s = 0
    for _, u in ipairs(units) do
        if Alive(u) then
            local eco = u:GetBlueprint().Economy
            local h = 1
            if not army or Intel.SeenNow(u, army) then h = HealthOf(u) end
            s = s + ((eco and eco.BuildCostMass) or 0) * h
        end
    end
    return s
end

local function Away(from, c, dist)
    local dx, dz = c[1] - from[1], c[3] - from[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1 then dx, dz, len = 1, 0, 1 end
    local x, z = c[1] + dx / len * dist, c[3] + dz / len * dist
    return { x, GetSurfaceHeight(x, z), z }
end

-- Submarines: under anti-sub units seen close by they dive away to the
-- rally; otherwise they go for the surface ships in reach.
local CatSub = categories.NAVAL * categories.MOBILE * categories.SUBMERSIBLE - categories.NUKE - categories.STRATEGIC
local CatAntiSub = categories.MOBILE * categories.ANTINAVY
local CatSurface = categories.NAVAL * categories.MOBILE - categories.SUBMERSIBLE
function SubmarineStep(brain, ctx, units, enemies, army)
    for _, u in ipairs(units) do
        if EntityCategoryContains(CatSub, u) then
            local p = u:GetPosition()
            if table.getn(KnownNear(brain, CatAntiSub, p, Config.SubDangerRadius)) > 0 then
                if not u.DGDiving then
                    u.DGDiving = true
                    IssueClearCommands({ u })
                    IssueMove({ u }, Routes.GetPoint('NavalRally', ctx.side))
                end
            else
                u.DGDiving = nil
                local best, bestD
                for _, e in ipairs(enemies) do
                    if EntityCategoryContains(CatSurface, e) and Intel.SeenNow(e, army) then
                        local d = Utils.Dist2D(p, e:GetPosition())
                        if not bestD or d < bestD then best, bestD = e, d end
                    end
                end
                if best and u.DGFocus ~= best then
                    u.DGFocus = best
                    IssueClearCommands({ u })
                    IssueAttack({ u }, best)
                end
            end
        end
    end
end

-- Bait: a few fast units poke the enemy in front of the held line and run
-- back to the guns, to draw it in.
function BaitStep(brain, ctx, units, enemies, rally, now)
    if ctx.baitAt and now - ctx.baitAt < Config.BaitEvery then return end
    local near = Nearest(enemies, rally)
    if not near then return end
    local pool = {}
    for _, u in ipairs(units) do
        if not EntityCategoryContains(categories.EXPERIMENTAL + categories.INDIRECTFIRE, u) then table.insert(pool, u) end
    end
    if table.getn(pool) < Config.BaitSize * 2 then return end
    table.sort(pool, function(a, b)
        return (a:GetBlueprint().Physics.MaxSpeed or 0) > (b:GetBlueprint().Physics.MaxSpeed or 0)
    end)
    local bait = {}
    for i = 1, Config.BaitSize do table.insert(bait, pool[i]) end
    ctx.baitAt = now
    local np = near:GetPosition()
    local poke = Away(np, Centroid(bait), WeaponRange(bait[1]:GetBlueprint()) * 0.9 - Utils.Dist2D(np, Centroid(bait)))
    IssueClearCommands(bait)
    IssueMove(bait, poke)
    IssueAttack(bait, near)
    IssueMove(bait, rally)
    Utils.Log(brain, Config.BaitSize .. ' units bait the enemy toward the line')
end

local CatOwnArmy = categories.MOBILE * (categories.LAND + categories.NAVAL) - categories.ENGINEER - categories.COMMAND

-- Experimentals never fall back with a wave (a Ythotha dying among the
-- enemy is a bomb going off): out of a wave that backs off they go on as a
-- wave of their own. Returns the units left in the wave.
function SplitT4(ctx, wave)
    local t4, rest = {}, {}
    for _, u in ipairs(wave.units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) then table.insert(t4, u) else table.insert(rest, u) end
    end
    if table.getn(t4) > 0 and table.getn(rest) > 0 then
        wave.units = rest
        table.insert(ctx.waves, { units = t4, kind = wave.kind, stage = 2, t4only = true, lastTarget = wave.lastTarget })
    end
    return rest
end

local function OnlyT4(units)
    for _, u in ipairs(units) do
        if not EntityCategoryContains(categories.EXPERIMENTAL, u) then return false end
    end
    return true
end

local function WaveTactic(brain, ctx, wave, now)
    if wave.stage == 'retreat' or wave.stage == 'regroup' or wave.ender or wave.raid then return end
    local units = Utils.FilterAlive(wave.units)
    if table.getn(units) == 0 or OnlyT4(units) then return end
    local c = Centroid(units)
    local army = brain:GetArmyIndex()
    local enemies = KnownNear(brain, CatContactEnemy, c, Config.ContactRadius)
    if table.getn(enemies) == 0 then
        if wave.tactic then
            if wave.tactic == 'KITE' then IssueClearCommands(units) end    -- back to hunting
            wave.tactic, wave.contact = nil, nil
        end
        return
    end
    -- Our side of the fight: every allied army unit around, not just this
    -- wave (a wave of four next to the whole army is not weak).
    local around = {}
    for _, u in ipairs(brain:GetUnitsAroundPoint(CatOwnArmy, c, Config.ContactRadius, 'Ally') or {}) do
        if Alive(u) and u:GetFractionComplete() >= 1 then table.insert(around, u) end
    end
    local own, enemy = Strength(around), Strength(enemies, army)
    wave.contact = wave.contact or { own0 = own, enemy0 = enemy }
    if enemy > wave.contact.enemy0 then wave.contact.enemy0 = enemy end
    local ownLoss = 1 - own / math.max(1, wave.contact.own0)
    local enemyLoss = 1 - enemy / math.max(1, wave.contact.enemy0)
    local ownRange, enemyRange = MedianRange(units), MedianRange(enemies)
    local naval = wave.kind == 'NAVAL'
    local task = (not naval) and LandCmd.Task(ctx.side, brain.Name)
    local rally = naval and Routes.GetPoint('NavalRally', ctx.side) or LandRally(ctx, task)
    local fortified = (not naval) and Utils.Dist2D(c, rally) <= Config.HoldReach
        and Utils.CountAround(brain, categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE, rally, 40, 'Ally')
            >= Config.LineFortifiedPDs
    local enemyT4, ownT4
    for _, e in ipairs(enemies) do
        if EntityCategoryContains(categories.EXPERIMENTAL * categories.LAND, e) then enemyT4 = e; break end
    end
    for _, u in ipairs(units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) then ownT4 = true; break end
    end
    if ownT4 then enemyT4 = nil end
    local t = ChooseTactic(own / math.max(1, enemy), ownRange - enemyRange, fortified, Losing(ownLoss, enemyLoss), naval,
        enemyT4 ~= nil)
    if naval then SubmarineStep(brain, ctx, units, enemies, army) end
    -- At the line already (or out to defend it): HOLD means fight here.
    if t == 'HOLD' and (wave.defending or Utils.Dist2D(c, rally) < Config.HoldAtLine) then t = 'CONCAVE' end
    -- T4s don't back off with the wave.
    if t == 'KITE' or t == 'HOLD' or t == 'DISENGAGE' then units = SplitT4(ctx, wave) end
    if wave.tactic and t ~= wave.tactic and t ~= 'DISENGAGE' and now - (wave.tacticAt or 0) < Config.TacticHold then
        t = wave.tactic
    end
    if t ~= wave.tactic then
        Utils.Log(brain, string.format('%s wave of %d: %s (strength %d vs %d, reach %d vs %d)',
            naval and 'naval' or 'land', table.getn(units), t, own, enemy, ownRange, enemyRange))
        wave.tactic, wave.tacticAt = t, now
    end
    if t == 'KITE' then
        local near, d = nil, nil
        for _, e in ipairs(enemies) do
            local dd = Utils.Dist2D(c, e:GetPosition())
            if not d or dd < d then near, d = e, dd end
        end
        local step = KiteStep(d, ownRange, enemyRange)
        local p
        if step == 'BACK' then
            p = Away(near:GetPosition(), c, enemyRange + Config.KiteMargin + 8 - d)
        elseif step == 'IN' then
            p = Away(near:GetPosition(), c, ownRange * 0.85 - d)
        end
        if p and naval and Utils.WaterDepth(p[1], p[3]) < 1.5 then p = nil end
        IssueClearCommands(units)
        if p then
            IssueMove(units, p)
        else
            local f = FocusTarget(enemies, army, c, ownRange)
            if f then IssueAttack(units, f) end
        end
    elseif t == 'PUSH' then
        for _, u in ipairs(units) do
            if not EntityCategoryContains(categories.EXPERIMENTAL, u) then
                local p = u:GetPosition()
                local near, d = Nearest(enemies, p)
                local r = WeaponRange(u:GetBlueprint())
                local step = near and StandoffStep(r, enemyRange, d)
                if step == 'BACK' then
                    local q = Away(near:GetPosition(), p, enemyRange + Config.KiteMargin + 8 - d)
                    if not naval or Utils.WaterDepth(q[1], q[3]) >= 1.5 then
                        IssueClearCommands({ u })
                        IssueMove({ u }, q)
                        u.DGStandoff = true
                    end
                elseif step == 'STAND' then
                    local f = FocusTarget(enemies, army, p, r)
                    if f and u.DGFocus ~= f then
                        IssueClearCommands({ u })
                        IssueAttack({ u }, f)
                        u.DGFocus = f
                    end
                    u.DGStandoff = true
                elseif u.DGStandoff then
                    -- Out of the stand-off: on with the wave.
                    u.DGStandoff, u.DGFocus = nil, nil
                    if wave.lastTarget then IssueMove({ u }, wave.lastTarget) end
                end
            end
        end
    elseif t == 'CONCAVE' then
        if not wave.arcAt or now - wave.arcAt >= Config.TacticHold then
            wave.arcAt = now
            local ec = Centroid(enemies)
            local spots = ArcPoints(ec, c, math.max(15, ownRange * 0.9), table.getn(units), Config.ConcaveArc,
                Config.ConcaveFlankShare)
            local ok = true
            for i, u in ipairs(SortAcross(units, c, ec)) do
                local p = spots[i]
                if naval and Utils.WaterDepth(p[1], p[3]) < 1.5 then ok = false end
                if ok then
                    IssueClearCommands({ u })
                    IssueMove({ u }, { p[1], GetSurfaceHeight(p[1], p[3]), p[3] })
                    local f = FocusTarget(enemies, army, p, WeaponRange(u:GetBlueprint()) + 10)
                    if f then IssueAttack({ u }, f) end
                end
            end
        end
    elseif t == 'T4' then
        if not wave.arcAt or now - wave.arcAt >= Config.TacticHold or wave.t4 ~= enemyT4 then
            wave.arcAt, wave.t4 = now, enemyT4
            local tp = enemyT4:GetPosition()
            local spots = FlankPoints(tp, c, math.max(20, ownRange * 0.85), Config.T4FlankAngles)
            local k = table.getn(spots)
            for i, u in ipairs(units) do
                local p = spots[i - k * math.floor((i - 1) / k)]
                IssueClearCommands({ u })
                IssueMove({ u }, { p[1], GetSurfaceHeight(p[1], p[3]), p[3] })
                IssueAttack({ u }, enemyT4)
            end
            Utils.Log(brain, 'land wave of ' .. table.getn(units) .. ' splits round the enemy ' .. Comms.UnitName(enemyT4))
        end
    elseif t == 'HOLD' then
        Utils.Log(brain, 'land wave of ' .. table.getn(units) .. ' holds at its fortified line')
        FormationPath(units, { rally }, c, true)
        wave.stage, wave.tactic = 'regroup', nil
        BaitStep(brain, ctx, units, enemies, rally, now)
    elseif t == 'DISENGAGE' then
        FormationPath(units, { rally }, c, true)
        wave.stage, wave.tactic = naval and 'retreat' or 'regroup', nil
    end
end

local CatRepairable = (categories.LAND + categories.NAVAL) * categories.MOBILE * (categories.TECH2 + categories.TECH3)
    - categories.ENGINEER - categories.COMMAND - categories.EXPERIMENTAL

local function RepairPoint(brain, ctx, u)
    if EntityCategoryContains(categories.NAVAL, u) then
        local best, bestD
        for _, f in ipairs(brain:GetListOfUnits(categories.FACTORY * categories.NAVAL * categories.STRUCTURE, false)) do
            if Alive(f) then
                local d = Utils.Dist2D(f:GetPosition(), u:GetPosition())
                if not bestD or d < bestD then best, bestD = f, d end
            end
        end
        return best and best:GetPosition() or Routes.GetPoint('NavalRally', ctx.side)
    end
    return Shift(LandRally(ctx, LandCmd.Task(ctx.side, brain.Name)), -Toward(ctx) * Config.RepairBack)
end

local function RepairStep(brain, ctx, now)
    local sent = 0
    for _, u in ipairs(brain:GetListOfUnits(CatRepairable, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local s = RepairState(HealthOf(u), u.DGRepairAt, now)
            if s == 'GO' then
                for _, w in ipairs(ctx.waves) do
                    for i = table.getn(w.units), 1, -1 do
                        if w.units[i] == u then table.remove(w.units, i) end
                    end
                end
                for i = table.getn(ctx.midShips or {}), 1, -1 do
                    if ctx.midShips[i] == u then table.remove(ctx.midShips, i) end
                end
                u.DualGapAssigned, u.DGRepairAt = true, now
                IssueClearCommands({ u })
                IssueMove({ u }, RepairPoint(brain, ctx, u))
                sent = sent + 1
            elseif s == 'DONE' then
                u.DGRepairAt, u.DualGapAssigned = nil, nil
                IssueClearCommands({ u })
            end
        end
    end
    if sent > 0 then Utils.Log(brain, sent .. ' damaged units go back for repairs') end
end

local function TacticsStep(brain, ctx)
    local now = GetGameTimeSeconds()
    for _, wave in ipairs(ctx.waves or {}) do WaveTactic(brain, ctx, wave, now) end
    ctx.repairTick = (ctx.repairTick or 0) + 1
    if ctx.repairTick >= 2 then
        ctx.repairTick = 0
        RepairStep(brain, ctx, now)
    end
end

function Start(brain, ctx)
    ctx.waves = {}
    ctx.strikes = {}
    -- The mirrored slot's start: where land waves end up.
    local slots = RoleManager.GetSlots()
    local own = slots[brain.Name]
    if own then
        for _, other in pairs(slots) do
            if other.side ~= own.side and other.rank == own.rank then ctx.enemyGroundBase = other.pos end
        end
        -- Upper half of the team patrols the upper front, lower half the lower.
        ctx.airZones = (own.rank <= 3) and Config.AirPatrolTop or Config.AirPatrolBottom
    end
    ForkThread(Utils.RunLoop, 'Army', brain, ctx, 5, ArmyStep)
    if Utils.Level(ctx).tactics then
        ForkThread(Utils.RunLoop, 'Tactics', brain, ctx, Config.TacticsSeconds, TacticsStep)
    end
end
