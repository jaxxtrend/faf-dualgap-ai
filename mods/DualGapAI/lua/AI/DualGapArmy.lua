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
--   Ender  a scouted enemy game ender is everyone's target: AIR strikes it
--          as soon as it can, land waves leave earlier and take the less
--          defended mid lane to it, fleets sail to the water next to it.
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
local CatBomber   = categories.AIR * categories.MOBILE * (categories.BOMBER + categories.ANTINAVY + categories.GROUNDATTACK)
                    - categories.EXPERIMENTAL
local CatTorpBomber = categories.AIR * categories.MOBILE * categories.ANTINAVY
-- Novax satellites are aimed by DualGapProjects with the artillery priorities.
local CatAirT4    = categories.AIR * categories.MOBILE * categories.EXPERIMENTAL - categories.SATELLITE

local CatNavalTargets = categories.NAVAL - categories.WALL
local CatEnemyAir     = categories.AIR * categories.MOBILE
local CatEnemyFighter = categories.AIR * categories.MOBILE * categories.ANTIAIR - categories.BOMBER - categories.GROUNDATTACK
local CatEcoTargets   = categories.STRUCTURE * (categories.MASSEXTRACTION + categories.ENERGYPRODUCTION
                        + categories.MASSFABRICATION + categories.FACTORY)
local CatEnemyLand    = categories.LAND * categories.MOBILE

local function OtherSide(side)
    if side == 'LEFT' then return 'RIGHT' end
    return 'LEFT'
end

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

-- Formation attack-move through waypoints, facing along the path.
-- Experimentals don't join the formation: each walks its own copy of the
-- path shifted sideways by SpreadOffsets.
function FormationPath(units, path, from)
    units = Utils.FilterAlive(units)
    if table.getn(units) == 0 or table.getn(path) == 0 then return end
    IssueClearCommands(units)
    local exps, rest = {}, {}
    for _, u in ipairs(units) do
        if EntityCategoryContains(categories.EXPERIMENTAL, u) then table.insert(exps, u) else table.insert(rest, u) end
    end
    local start = from or Centroid(units)
    if table.getn(rest) > 0 then
        local prev = start
        for _, wp in ipairs(path) do
            local p = { wp[1], GetSurfaceHeight(wp[1], wp[3]), wp[3] }
            IssueFormAggressiveMove(rest, p, 'AttackFormation', Utils.FacingDegrees(prev, p))
            prev = p
        end
    end
    local offsets = SpreadOffsets(table.getn(exps), Config.T4Spacing)
    for i, u in ipairs(exps) do
        local prev = start
        for _, wp in ipairs(path) do
            local px, pz = Perp(prev, wp)
            local x, z = wp[1] + px * offsets[i], wp[3] + pz * offsets[i]
            IssueAggressiveMove({ u }, { x, GetSurfaceHeight(x, z), z })
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
    local t = NearestKnown(brain, cat, c, MapRadius())
    if t then return t:GetPosition() end
    -- Nothing known: search. Fleets sweep the enemy's deep water (sonar finds
    -- a hidden ACU), land waves walk to a random enemy base.
    -- Fleets go where the hidden ACU most likely is; each fleet takes the
    -- next clue, so several fleets spread over the search points.
    if wave.kind == 'NAVAL' and Intel.HuntMode(ctx.side) then
        ctx.searchIdx = (ctx.searchIdx or 0) + 1
        local p = Intel.SearchPoint(ctx.side, ctx.searchIdx)
        if p then return p end
    end
    if Intel.Stale(ctx.side) then
        if wave.kind == 'NAVAL' then return Intel.DeepWater(OtherSide(ctx.side)) end
        local slots = EnemySlots(ctx)
        local n = table.getn(slots)
        if n > 0 then return slots[Random and Random(1, n) or 1] end
    end
    return nil
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

local function UpdateWaves(brain, ctx)
    local keep = {}
    for _, wave in ipairs(ctx.waves) do
        wave.units = Utils.FilterAlive(wave.units)
        if Utils.Count(wave.units) > 0 then
            table.insert(keep, wave)
            local c = Centroid(wave.units)
            if wave.kind == 'NAVAL' and wave.stage ~= 'retreat' then
                local enemy = KnownNear(brain, categories.NAVAL * categories.MOBILE, c, 150)
                if NavalStrength(enemy) > 1.5 * NavalStrength(wave.units) then
                    Utils.Log(brain, 'fleet falls back: stronger enemy fleet ahead')
                    FormationPath(wave.units, { Routes.GetPoint('NavalRally', ctx.side) }, c)
                    wave.stage = 'retreat'
                end
            end
            if AllIdle(wave.units) then
                if wave.stage == 'retreat' then
                    Release(wave.units)          -- rejoin the gathering fleet
                    wave.units = {}
                else
                    wave.stage = 2
                    local t = HuntTarget(brain, ctx, wave, c)
                    if t then FormationPath(wave.units, { t }, c) end
                end
            end
        end
    end
    ctx.waves = keep
end

---------------------------------------------------------------------------
-- Waves gather behind the furthest defence line the player holds
-- (DualGapProjects moves ctx.frontPoint forward as the front advances).
local function LandRally(ctx)
    return Shift(ctx.frontPoint or ctx.choke, -Toward(ctx) * 25)
end

local function LandStep(brain, ctx)
    local rally = LandRally(ctx)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatLandDF)) do
        if Utils.Dist2D(u:GetPosition(), rally) > 20 then
            IssueMove({ u }, rally)
        else
            table.insert(ready, u)
        end
    end
    local enemyAtWall = table.getn(KnownNear(brain, CatEnemyLand, ctx.choke, 70)) >= 5
    if enemyAtWall then
        Comms.Say(brain, ctx.side, 'wall:' .. brain.Name, 'Enemy army at my wall, need help here!', ctx.choke, 'alert')
    end
    local size = Config.WaveSize[TopTech(brain)] or 10
    local ender = EnderTarget(ctx)
    if ender then size = math.max(4, math.floor(size * Config.EnderWaveShare)) end
    if WaveReady(ready, size) or (enemyAtWall and Utils.Count(ready) >= 4) then
        local enemy = OtherSide(ctx.side)
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        local path = { ctx.frontPoint or ctx.choke, Routes.GetPoint(zone, enemy) }
        if ctx.frontPoint then path = { ctx.frontPoint } end
        if ender and not enemyAtWall then
            -- Everyone on the game ender, through the mid lane with less
            -- known enemy army: the sneaky way in.
            local up, low = Routes.GetPoint('ChokeUpper', enemy), Routes.GetPoint('ChokeLower', enemy)
            local lane = (table.getn(KnownNear(brain, CatEnemyLand, up, 120))
                <= table.getn(KnownNear(brain, CatEnemyLand, low, 120))) and up or low
            path = { ctx.frontPoint or ctx.choke, lane, ender.pos }
            Comms.Say(brain, ctx.side, 'enderwave:' .. brain.Name, 'Going for their game ender with '
                .. Utils.Count(ready) .. ' units!', ender.pos, 'attack')
        elseif ctx.enemyGroundBase then table.insert(path, ctx.enemyGroundBase) end
        Claim(ready)
        FormationPath(ready, path, rally)
        table.insert(ctx.waves, { units = ready, kind = 'LAND', stage = 1 })
        Utils.Log(brain, 'land wave of ' .. Utils.Count(ready) .. (enemyAtWall and ' (defending)' or ''))
        if not enemyAtWall then
            local where = (zone == 'ChokeLower') and 'lower' or 'upper'
            Comms.Say(brain, ctx.side, 'wave:' .. brain.Name, 'Attacking the ' .. where .. ' mid with '
                .. Utils.Count(ready) .. ' units.', Routes.GetPoint(zone, enemy), 'attack')
        end
    end

    -- Artillery / MML: behind the wall, then follow the last wave out.
    local staging = Shift(ctx.choke, -Toward(ctx) * 40)
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
        FormationPath(arty, { ctx.choke, Routes.GetPoint(zone, OtherSide(ctx.side)) }, staging)
        table.insert(ctx.waves, { units = arty, kind = 'LAND', stage = 1 })
    end
end

local function NavalStep(brain, ctx)
    local rally = Routes.GetPoint('NavalRally', ctx.side)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatNaval)) do
        if Utils.Dist2D(u:GetPosition(), rally) > 25 then IssueMove({ u }, rally)
        else table.insert(ready, u) end
    end
    local size = Config.NavalFleetSize[TopTech(brain)] or 6
    -- Searching for a hidden ACU: any two ships go.
    if Intel.HuntMode(ctx.side) then size = math.min(size, 2) end
    local enderWater = EnderWater(ctx)
    if enderWater then size = math.max(3, math.floor(size * Config.EnderWaveShare)) end
    if WaveReady(ready, size) then
        local enemy = OtherSide(ctx.side)
        if enderWater then
            Claim(ready)
            FormationPath(ready, { Routes.GetPoint('BasinCenter', ctx.side), enderWater }, rally)
            table.insert(ctx.waves, { units = ready, kind = 'NAVAL', stage = 1 })
            Utils.Log(brain, 'fleet of ' .. Utils.Count(ready) .. ' sails for the enemy game ender')
            Comms.Say(brain, ctx.side, 'fleet:' .. brain.Name, 'Fleet going for their game ender.', enderWater, 'attack')
            return
        end
        local ahead = KnownNear(brain, categories.NAVAL * categories.MOBILE, Routes.GetPoint('BasinCenter', ctx.side), 200)
        if NavalStrength(ahead) > 1.5 * NavalStrength(ready) then return end   -- wait, keep massing
        Claim(ready)
        FormationPath(ready, { Routes.GetPoint('BasinCenter', ctx.side), Routes.GetPoint('NavalRally', enemy) }, rally)
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
function FrontLine(side, toWorld, aaAt, zList)
    local pts = {}
    for _, z in ipairs(zList or Config.AirFrontZ) do
        local x = Config.AirFrontX
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
    if nx >= Config.AirFrontX then return false end
    local zl = ctx.airZones or Config.AirFrontZ
    local zmin, zmax = zl[1], zl[table.getn(zl)]
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
local function Intercept(brain, ctx, now)
    local threats = {}
    for _, e in ipairs(KnownNear(brain, CatEnemyAir, ctx.startPos, MapRadius())) do
        if BehindFront(ctx, e:GetPosition()) then table.insert(threats, e) end
    end
    for _, e in ipairs(threats) do
        local p = e:GetPosition()
        local covered = false
        for _, u in ipairs(ctx.fighters) do
            if u.DGIntercept and u.DGInterceptPos and Utils.Dist2D(u.DGInterceptPos, p) < 60 then covered = true; break end
        end
        if not covered then
            local group = 0
            for _, o in ipairs(threats) do
                if Utils.Dist2D(o:GetPosition(), p) < 40 then group = group + 1 end
            end
            local want = math.max(Config.InterceptMin, Config.InterceptPerEnemy * group)
            local units = Nearest(FreeFighters(ctx), p, want)
            if table.getn(units) > 0 then
                IssueClearCommands(units)
                IssueAttack(units, e)
                IssueAggressiveMove(units, p)
                for _, u in ipairs(units) do
                    u.DGIntercept, u.DGInterceptPos, u.DGLine = now + Config.InterceptSeconds, p, nil
                end
                Utils.Log(brain, table.getn(units) .. ' fighters intercept ' .. group .. ' aircraft behind the front')
            end
        end
    end
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

    -- Back to the patrol: interceptors that are done, new fighters, and
    -- everyone when the line moved.
    local patrol = {}
    for _, u in ipairs(ctx.fighters) do
        if u.DGIntercept and (now > u.DGIntercept or u:IsIdleState()) then
            u.DGIntercept, u.DGInterceptPos = nil, nil
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
    for _, u in ipairs(escort) do u.DGEscort, u.DGLine = true, nil end
    if table.getn(escort) > 0 then
        -- The escort flies the direct line and draws the enemy fighters.
        IssueClearCommands(escort)
        IssueAggressiveMove(escort, Clamp(mid))
        IssueAggressiveMove(escort, tpos)
    end
    Claim(units)
    IssueClearCommands(units)
    local flank = FlankPoint(ctx, staging, tpos)
    ForkThread(function()
        WaitSeconds(Config.BomberDelay)
        local alive = Utils.FilterAlive(units)
        if table.getn(alive) == 0 or not Alive(target) then return end
        IssueMove(alive, flank)
        IssueAttack(alive, target)
        IssueMove(alive, staging)
    end)
    table.insert(ctx.strikes, { units = units, escort = escort, started = now })
    Utils.Log(brain, 'air strike: ' .. table.getn(units) .. ' bombers, ' .. table.getn(escort) .. ' escorts')
    Comms.Say(brain, ctx.side, 'strike:' .. brain.Name, 'Air strike going in here.', tpos, 'attack')
    return true
end

local function TorpTargetOk(e)
    -- Torpedoes only reach ships and units under water (a submerged ACU).
    if EntityCategoryContains(categories.COMMAND, e) then return Utils.IsUnderwater(e) end
    return true
end

local function AirStep(brain, ctx)
    local now = GetGameTimeSeconds()
    FightersStep(brain, ctx, now)

    -- Bombers stage, then strike the target with the least AA around it.
    local staging = Routes.GetPoint('AirStaging', ctx.side)
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
    if Utils.Count(torps) >= Config.AirStrikeSize or (hunt and Utils.Count(torps) >= 2) then
        local target = PickStrikeTarget(brain, ctx, CatNavalTargets + categories.COMMAND, staging, false, TorpTargetOk)
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
    local massed = MassAirStep(brain, ctx, staging, bombers, now)
    if not massed and Utils.Count(bombers) >= Config.AirStrikeSize and AirCount(brain) < Config.AirRaidMaxAir then
        -- The bigger the group, the more AA it may fly into.
        local maxAA = Config.AAThreat + Utils.Count(bombers) / Config.BomberAAPerUnit
        local target = PickStrikeTarget(brain, ctx, CatEcoTargets, staging, true, nil, maxAA)
        if target then LaunchStrike(brain, ctx, bombers, target, staging, now) end
    end

    -- Strikes end when the bombers are back (idle), gone or out of time;
    -- the escort returns to the patrol.
    local keep = {}
    for _, st in ipairs(ctx.strikes) do
        st.units = Utils.FilterAlive(st.units)
        local timeout = (st.search and 120) or (st.mass and Config.AirMassTimeout) or Config.StrikeTimeout
        local idle = now - st.started > Config.BomberDelay + 5 and AllIdle(st.units)
        if Utils.Count(st.units) == 0 or idle or now - st.started > timeout then
            Release(st.units)
            for _, u in ipairs(Utils.FilterAlive(st.escort)) do u.DGEscort, u.DGLine = nil, nil end
        else
            table.insert(keep, st)
        end
    end
    ctx.strikes = keep

    -- Air experimentals hunt game enders, else the best economy target;
    -- each picks a different target, so they don't crash onto each other.
    local taken = {}
    for _, u in ipairs(FreeUnits(brain, CatAirT4)) do
        local t = PickStrikeTarget(brain, ctx, CatEcoTargets, u:GetPosition(), true, function(e) return not taken[e] end)
        if t then
            taken[t] = true
            IssueAttack({ u }, t)
        end
    end
end

---------------------------------------------------------------------------
-- Mass air attack (see the header and Config.AirMassSize).
---------------------------------------------------------------------------
local CatAllAir = categories.AIR * categories.MOBILE - categories.ENGINEER - categories.SCOUT - categories.TRANSPORTATION
local CatHeart = categories.STRUCTURE * categories.TECH3 * (categories.ENERGYPRODUCTION + categories.MASSFABRICATION
    + categories.MASSEXTRACTION)
local CatEnemyAntiNuke = categories.STRUCTURE * categories.ANTIMISSILE * categories.TECH3

function AirCount(brain)
    return Utils.Count(brain:GetListOfUnits(CatAllAir, false))
end

-- Exposed for tests: launch a mass attack now? Returns 'ender', 'mass',
-- 'join' or nil.
function MassAirDecision(air, enderKnown, teamStrikeOn, sinceLast)
    if sinceLast < Config.AirMassCooldown then return nil end
    if teamStrikeOn and air >= Config.AirMassSize * Config.AirMassJoinShare then return 'join' end
    if enderKnown and air >= Config.AirEnderStrikeMin then return 'ender' end
    if air >= Config.AirMassSize then return 'mass' end
    return nil
end

local function OwnTeamNuke(brain)
    return Utils.Count(brain:GetListOfUnits(categories.NUKE * categories.STRUCTURE, false)) > 0
        or Utils.CountAround(brain, categories.NUKE * categories.STRUCTURE, { 512, 0, 512 }, 2000, 'Ally') > 0
end

-- The strategic target: game ender > enemy experimental structure (they
-- are enders too) > anti-nuke while the team owns a nuke > the T3
-- economy structure with the most T3 economy around it (the heart).
local function MassAirTarget(brain, ctx)
    local e = EnderTarget(ctx)
    if e then return e.unit end
    for _, rec in ipairs(Intel.Enders(ctx.side)) do return rec.unit end
    local all = MapRadius()
    if OwnTeamNuke(brain) then
        local a = NearestKnown(brain, CatEnemyAntiNuke, ctx.startPos, all)
        if a then return a end
    end
    local best, bestN
    for _, s in ipairs(KnownNear(brain, CatHeart, ctx.startPos, all)) do
        local n = table.getn(KnownNear(brain, CatHeart, s:GetPosition(), 40))
        if not bestN or n > bestN then best, bestN = s, n end
    end
    if best then return best end
    return NearestKnown(brain, CatEcoTargets, ctx.startPos, all)
end

function MassAirStep(brain, ctx, staging, bombers, now)
    if ctx.role ~= 'AIR' then return false end
    local air = AirCount(brain)
    local team = Intel.AirMass(ctx.side)
    local teamOn = team and now - team.at < 90 and Alive(team.unit)
    local why = MassAirDecision(air, EnderTarget(ctx) ~= nil, teamOn and team.by ~= brain:GetArmyIndex(),
        now - (ctx.airMassAt or -1000))
    if not why then return false end
    local target = (why == 'join') and team.unit or MassAirTarget(brain, ctx)
    if not Alive(target) then return false end
    local tpos = target:GetPosition()
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
    local mid = Clamp({ (staging[1] + tpos[1]) / 2, 0, (staging[3] + tpos[3]) / 2 })
    if table.getn(escort) > 0 then
        for _, u in ipairs(escort) do u.DGEscort, u.DGLine = true, nil end
        IssueClearCommands(escort)
        IssueAggressiveMove(escort, mid)
        IssueAggressiveMove(escort, tpos)
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
    -- Close behind the fighters, then the target and whatever is worth it
    -- around it, then home.
    local extra = KnownNear(brain, CatHeart + CatEnemyAntiNuke + categories.EXPERIMENTAL, tpos, 60)
    ForkThread(function()
        WaitSeconds(Config.BomberDelay)
        local alive = Utils.FilterAlive(strikers)
        if table.getn(alive) == 0 then return end
        IssueClearCommands(alive)
        IssueMove(alive, mid)
        if Alive(target) then IssueAttack(alive, target) end
        local n = 0
        for _, x in ipairs(extra) do
            if Alive(x) and x ~= target and n < 6 then IssueAttack(alive, x); n = n + 1 end
        end
        IssueMove(alive, staging)
    end)
    table.insert(ctx.strikes, { units = strikers, escort = escort, started = now, mass = true })
    local what = Comms.UnitName(target)
    Utils.Log(brain, 'mass air attack (' .. why .. '): ' .. table.getn(escort) .. ' fighters, '
        .. table.getn(strikers) .. ' bombers on ' .. what)
    local text = (why == 'join') and ('Joining the air attack on their ' .. what .. ' with ' .. air .. ' planes!')
        or ('All air in: ' .. air .. ' planes on their ' .. what .. '!')
    Comms.Say(brain, ctx.side, 'massair:' .. brain.Name, text, tpos, 'attack')
    return true
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
        local need = Config.TorpGuardsPerACU - table.getn(guards)
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
    UpdateWaves(brain, ctx)
    LandStep(brain, ctx)
    NavalStep(brain, ctx)
    AirStep(brain, ctx)
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
        ctx.airZones = (own.rank <= 3) and Config.AirFrontZTop or Config.AirFrontZBottom
    end
    ForkThread(Utils.RunLoop, 'Army', brain, ctx, 5, ArmyStep)
end
