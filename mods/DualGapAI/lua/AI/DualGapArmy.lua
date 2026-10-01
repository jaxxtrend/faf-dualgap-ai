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
--          steps back while scouted enemy AA is near it. Bombers stage and
--          strike scouted game enders first, then ships / economy, always
--          the target with the least AA around.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')

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
local CatAirT4    = categories.AIR * categories.MOBILE * categories.EXPERIMENTAL

local CatNavalTargets = categories.NAVAL - categories.WALL
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

-- Formation attack-move through waypoints, facing along the path.
function FormationPath(units, path, from)
    units = Utils.FilterAlive(units)
    if table.getn(units) == 0 or table.getn(path) == 0 then return end
    IssueClearCommands(units)
    local prev = from or Centroid(units)
    for _, wp in ipairs(path) do
        local p = { wp[1], GetSurfaceHeight(wp[1], wp[3]), wp[3] }
        IssueFormAggressiveMove(units, p, 'AttackFormation', Utils.FacingDegrees(prev, p))
        prev = p
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
local function HuntTarget(brain, ctx, wave, c)
    -- Scouted game enders first if any are within reach, then anything known.
    for _, rec in ipairs(Intel.Enders(ctx.side)) do
        if Utils.Dist2D(rec.pos, c) < 300 then return rec.pos end
    end
    local cat = (wave.kind == 'NAVAL') and (categories.NAVAL + categories.STRUCTURE)
        or (categories.ALLUNITS - categories.AIR - categories.WALL)
    local t = NearestKnown(brain, cat, c, MapRadius())
    return t and t:GetPosition()
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
local function LandRally(ctx)
    return Shift(ctx.choke, -Toward(ctx) * 25)
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
    local size = Config.WaveSize[TopTech(brain)] or 10
    if Weight(ready) >= size or (enemyAtWall and Utils.Count(ready) >= 4) then
        local enemy = OtherSide(ctx.side)
        local zone = (ctx.groundArc == 'GroundArcSouth') and 'ChokeLower' or 'ChokeUpper'
        local path = { ctx.choke, Routes.GetPoint(zone, enemy) }
        if ctx.enemyGroundBase then table.insert(path, ctx.enemyGroundBase) end
        Claim(ready)
        FormationPath(ready, path, rally)
        table.insert(ctx.waves, { units = ready, kind = 'LAND', stage = 1 })
        Utils.Log(brain, 'land wave of ' .. Utils.Count(ready) .. (enemyAtWall and ' (defending)' or ''))
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
    if Weight(ready) >= size then
        local enemy = OtherSide(ctx.side)
        local ahead = KnownNear(brain, categories.NAVAL * categories.MOBILE, Routes.GetPoint('BasinCenter', ctx.side), 200)
        if NavalStrength(ahead) > 1.5 * NavalStrength(ready) then return end   -- wait, keep massing
        Claim(ready)
        FormationPath(ready, { Routes.GetPoint('BasinCenter', ctx.side), Routes.GetPoint('NavalRally', enemy) }, rally)
        table.insert(ctx.waves, { units = ready, kind = 'NAVAL', stage = 1 })
        Utils.Log(brain, 'fleet of ' .. Utils.Count(ready) .. ' sails')
    end
end

---------------------------------------------------------------------------
-- Air
---------------------------------------------------------------------------
-- Exposed for tests: the patrol line, each point pushed back while the
-- AA count there (aaAt(point)) reaches the threshold.
function FrontLine(side, toWorld, aaAt)
    local pts = {}
    for _, z in ipairs(Config.AirFrontZ) do
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
    for _, p in ipairs(pts) do s = s .. math.floor(p[1]) .. ',' end
    return s
end

local function AirStep(brain, ctx)
    local line = FrontLine(ctx.side, Utils.ToWorld, function(p) return Intel.AAThreat(ctx.side, p) end)
    local key = LineKey(line)
    local fresh = FreeUnits(brain, CatFighter)
    Claim(fresh)
    ctx.fighters = Utils.FilterAlive(ctx.fighters or {})
    for _, u in ipairs(fresh) do table.insert(ctx.fighters, u) end
    if key ~= ctx.airLineKey or table.getn(fresh) > 0 then
        if key ~= ctx.airLineKey and ctx.airLineKey then Utils.Log(brain, 'air patrol line moved (enemy AA)') end
        ctx.airLineKey = key
        if Utils.Count(ctx.fighters) > 0 then
            IssueClearCommands(ctx.fighters)
            for _, p in ipairs(line) do IssuePatrol(ctx.fighters, p) end
        end
    end

    -- Bombers stage, then strike the target with the least AA around it.
    local staging = Routes.GetPoint('AirStaging', ctx.side)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatBomber)) do
        if Utils.Dist2D(u:GetPosition(), staging) > 25 then IssueMove({ u }, staging)
        else table.insert(ready, u) end
    end
    if Utils.Count(ready) >= Config.AirStrikeSize then
        local torps, bombers = {}, {}
        for _, u in ipairs(ready) do
            if EntityCategoryContains(CatTorpBomber, u) then table.insert(torps, u) else table.insert(bombers, u) end
        end
        for _, g in ipairs({ { torps, CatNavalTargets }, { bombers, CatEcoTargets } }) do
            local units, cat = g[1], g[2]
            if Utils.Count(units) > 0 then
                local target = PickStrikeTarget(brain, ctx, cat, staging)
                if target then
                    Claim(units)
                    IssueClearCommands(units)
                    IssueAttack(units, target)
                    IssueMove(units, staging)
                    table.insert(ctx.strikes, units)
                end
            end
        end
    end
    local keep = {}
    for _, units in ipairs(ctx.strikes) do
        units = Utils.FilterAlive(units)
        if Utils.Count(units) > 0 then
            if AllIdle(units) then Release(units) else table.insert(keep, units) end
        end
    end
    ctx.strikes = keep

    -- Air experimentals hunt game enders, else the best economy target.
    for _, u in ipairs(FreeUnits(brain, CatAirT4)) do
        local t = PickStrikeTarget(brain, ctx, CatEcoTargets, u:GetPosition())
        if t then IssueAttack({ u }, t) end
    end
end

-- Scouted game enders first, then `cat`; among them the least AA-covered.
function PickStrikeTarget(brain, ctx, cat, from)
    local best, bestAA
    for _, rec in ipairs(Intel.Enders(ctx.side)) do
        local aa = Intel.AAThreat(ctx.side, rec.pos, 50)
        if aa < Config.AAThreat and (not bestAA or aa < bestAA) then best, bestAA = rec.unit, aa end
    end
    if best then return best end
    for _, e in ipairs(KnownNear(brain, cat, from, MapRadius())) do
        local aa = Intel.AAThreat(ctx.side, e:GetPosition(), 50)
        if aa < Config.AAThreat and (not bestAA or aa < bestAA) then best, bestAA = e, aa end
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
    end
    ForkThread(Utils.RunLoop, 'Army', brain, ctx, 5, ArmyStep)
end
