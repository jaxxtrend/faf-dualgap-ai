-- Army control: picks up idle factory output and sends it along the role's
-- routes. Units handled here are flagged with unit.DualGapAssigned so they are
-- never re-tasked by two waves at once. No PlatoonFormBuilders are loaded by
-- the DualGap base templates, so nothing else competes for these units.

local Config = import('/lua/AI/DualGapConfig.lua')
local Utils = import('/lua/AI/DualGapUtils.lua')
local Routes = import('/lua/AI/DualGapRoutes.lua')
local RoleManager = import('/lua/AI/DualGapRoleManager.lua')

local Alive = Utils.Alive

local CatLandDF   = categories.LAND * categories.MOBILE - categories.ENGINEER - categories.COMMAND
                    - categories.INDIRECTFIRE - categories.SCOUT - categories.SUBCOMMANDER
local CatLandArty = categories.LAND * categories.MOBILE * categories.INDIRECTFIRE - categories.COMMAND
local CatNaval    = categories.NAVAL * categories.MOBILE - categories.ENGINEER
local CatFighter  = categories.AIR * categories.MOBILE * categories.ANTIAIR
                    - categories.BOMBER - categories.GROUNDATTACK - categories.TRANSPORTATION
local CatBomber   = categories.AIR * categories.MOBILE * (categories.BOMBER + categories.ANTINAVY)
local CatTorpBomber = categories.AIR * categories.MOBILE * categories.ANTINAVY

local CatNavalTargets = categories.NAVAL - categories.WALL
local CatEcoTargets   = categories.STRUCTURE * (categories.MASSEXTRACTION + categories.ENERGYPRODUCTION
                        + categories.MASSFABRICATION + categories.STRATEGIC + categories.EXPERIMENTAL)

local function OtherSide(side)
    if side == 'LEFT' then return 'RIGHT' end
    return 'LEFT'
end

-- Fully built, alive, idle and not already owned by a wave.
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

local function Reverse(list)
    local out = {}
    for i = table.getn(list), 1, -1 do table.insert(out, list[i]) end
    return out
end

local function NearestEnemy(brain, cat, pos, radius)
    local best, bestD
    for _, e in ipairs(brain:GetUnitsAroundPoint(cat, pos, radius, 'Enemy') or {}) do
        if Alive(e) then
            local d = Utils.Dist2D(pos, e:GetPosition())
            if not bestD or d < bestD then best, bestD = e, d end
        end
    end
    return best
end

local function MapRadius()
    local x0, z0, x1, z1 = Utils.MapBounds()
    return math.max(x1 - x0, z1 - z0)
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

---------------------------------------------------------------------------
-- Wave bookkeeping. A wave: { units, route, stage }.
--   stage 1: walking our-side route
--   stage 2: pushing the mirrored enemy-side route
--   stage 3: hunting whatever is nearest
---------------------------------------------------------------------------
local function LaunchWave(ctx, units, routeName)
    Claim(units)
    local wave = { units = units, routeName = routeName, stage = 1 }
    Routes.ExecuteQueuedMovement(units, Routes.GetRoute(routeName, ctx.side), true)
    table.insert(ctx.waves, wave)
end

local function UpdateWaves(brain, ctx)
    local keep = {}
    for _, wave in ipairs(ctx.waves) do
        wave.units = Utils.FilterAlive(wave.units)
        if Utils.Count(wave.units) > 0 then
            table.insert(keep, wave)
            if AllIdle(wave.units) then
                if wave.stage == 1 then
                    local enemyRoute = Reverse(Routes.GetRoute(wave.routeName, OtherSide(ctx.side)))
                    Routes.ExecuteQueuedMovement(wave.units, enemyRoute, true)
                    wave.stage = 2
                else
                    wave.stage = 3
                    local c = Centroid(wave.units)
                    local cat = categories.ALLUNITS - categories.AIR - categories.WALL
                    local target = c and NearestEnemy(brain, cat, c, MapRadius())
                    if target then
                        IssueAggressiveMove(wave.units, target:GetPosition())
                    end
                end
            end
        end
    end
    ctx.waves = keep
end

---------------------------------------------------------------------------
local function LandStep(brain, ctx)
    local df = FreeUnits(brain, CatLandDF)
    if Utils.Count(df) >= Config.GroundWaveSize then
        ctx.nextArc = (ctx.nextArc == 'GroundArcNorth') and 'GroundArcSouth' or 'GroundArcNorth'
        LaunchWave(ctx, df, ctx.nextArc)
    end

    -- Artillery / MML: gather behind the wall, then shell the centre together.
    local staging = Routes.GetPoint('ArtyStaging', ctx.side)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatLandArty)) do
        if Utils.Dist2D(u:GetPosition(), staging) > 15 then
            IssueMove({ u }, staging)
        else
            table.insert(ready, u)
        end
    end
    if Utils.Count(ready) >= Config.ArtyWaveSize then
        Claim(ready)
        IssueAggressiveMove(ready, Routes.GetPoint('LandCenter', ctx.side))
        table.insert(ctx.waves, { units = ready, routeName = 'GroundArcSouth', stage = 2 })
    end
end

local function NavalStep(brain, ctx)
    local ships = FreeUnits(brain, CatNaval)
    if Utils.Count(ships) >= Config.NavalWaveSize then
        LaunchWave(ctx, ships, 'NavalVector')
    end
end

---------------------------------------------------------------------------
-- AIR: fighters patrol over the GROUND allies; bombers stage and strike.
---------------------------------------------------------------------------
local function PatrolPoints(ctx)
    local pts = {}
    for _, p in ipairs(RoleManager.SlotPositions('GROUND', ctx.side)) do table.insert(pts, p) end
    table.insert(pts, Routes.GetPoint('Choke', ctx.side))
    table.insert(pts, Routes.GetPoint('LandCenter', ctx.side))
    return pts
end

local function AirStep(brain, ctx)
    local fighters = FreeUnits(brain, CatFighter)
    if Utils.Count(fighters) > 0 then
        Claim(fighters)
        IssueClearCommands(fighters)
        for _, p in ipairs(PatrolPoints(ctx)) do IssuePatrol(fighters, p) end
    end

    local staging = Routes.GetPoint('AirStaging', ctx.side)
    local ready = {}
    for _, u in ipairs(FreeUnits(brain, CatBomber)) do
        if Utils.Dist2D(u:GetPosition(), staging) > 25 then
            IssueMove({ u }, staging)
        else
            table.insert(ready, u)
        end
    end
    if Utils.Count(ready) >= Config.AirStrikeSize then
        local torps, bombers = {}, {}
        for _, u in ipairs(ready) do
            if EntityCategoryContains(CatTorpBomber, u) then table.insert(torps, u) else table.insert(bombers, u) end
        end
        local groups = { { torps, CatNavalTargets }, { bombers, CatEcoTargets } }
        for _, g in ipairs(groups) do
            local units, cat = g[1], g[2]
            if Utils.Count(units) > 0 then
                local target = NearestEnemy(brain, cat, staging, MapRadius())
                    or NearestEnemy(brain, categories.STRUCTURE, staging, MapRadius())
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

    -- Strike groups that are back home and idle rejoin the staging pool.
    local keep = {}
    for _, units in ipairs(ctx.strikes) do
        units = Utils.FilterAlive(units)
        if Utils.Count(units) > 0 then
            if AllIdle(units) then Release(units) else table.insert(keep, units) end
        end
    end
    ctx.strikes = keep
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
    ForkThread(Utils.RunLoop, 'Army', brain, ctx, 5, ArmyStep)
end
