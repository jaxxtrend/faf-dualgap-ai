-- Shared helpers. Written for FAF's Lua 5.0 (no '#', no '%', no varargs).

local Config = import('/lua/AI/DualGapConfig.lua')

-- Structure / unit IDs per faction index (1 UEF, 2 Aeon, 3 Cybran, 4 Seraphim).
UnitIds = {
    MassExtractorT1 = { 'ueb1103', 'uab1103', 'urb1103', 'xsb1103' },
    HydroT1        = { 'ueb1102', 'uab1102', 'urb1102', 'xsb1102' },
    PointDefenseT1 = { 'ueb2101', 'uab2101', 'urb2101', 'xsb2101' },
    PointDefenseT2 = { 'ueb2301', 'uab2301', 'urb2301', 'xsb2301' },
    ShieldT2       = { 'ueb4202', 'uab4202', 'urb4202', 'xsb4202' },
    Wall           = { 'ueb5101', 'uab5101', 'urb5101', 'xsb5101' },
    NavalFactoryT1 = { 'ueb0103', 'uab0103', 'urb0103', 'xsb0103' },
    TorpedoT1      = { 'ueb2109', 'uab2109', 'urb2109', 'xsb2109' },
    TorpedoT2      = { 'ueb2205', 'uab2205', 'urb2205', 'xsb2205' },
    StratArtyT3    = { 'ueb2302', 'uab2302', 'urb2302', 'xsb2302' },
    NukeSilo       = { 'ueb2305', 'uab2305', 'urb2305', 'xsb2305' },
    -- Faction experimental for ECO: Mavor, Paragon, Scathis, Yolona Oss.
    StrategicT4    = { 'ueb2401', 'xab1401', 'url0401', 'xsb2401' },
}

function FactionId(brain, key)
    local list = UnitIds[key]
    local idx = brain:GetFactionIndex()
    if not list or not list[idx] then return nil end
    return list[idx]
end

function Alive(unit)
    if not unit or unit.Dead then return false end
    if IsDestroyed and IsDestroyed(unit) then return false end
    return true
end

function FilterAlive(units)
    local out = {}
    for _, u in ipairs(units or {}) do
        if Alive(u) then table.insert(out, u) end
    end
    return out
end

function Count(t)
    return table.getn(t or {})
end

function Dist2D(a, b)
    local dx = a[1] - b[1]
    local dz = a[3] - b[3]
    return math.sqrt(dx * dx + dz * dz)
end

-- Playable area as x0, z0, x1, z1.
function MapBounds()
    local pa = ScenarioInfo.PlayableArea
    if pa and pa[3] and pa[4] then
        return pa[1], pa[2], pa[3], pa[4]
    end
    local size = ScenarioInfo.size or { 1024, 1024 }
    return 0, 0, size[1], size[2]
end

function Normalise(x, z)
    local x0, z0, x1, z1 = MapBounds()
    return (x - x0) / (x1 - x0), (z - z0) / (z1 - z0)
end

-- Normalised left-team point -> world position for the given side.
function ToWorld(np, side)
    local x0, z0, x1, z1 = MapBounds()
    local nx = np[1]
    if side == 'RIGHT' then nx = 1 - nx end
    local x = x0 + nx * (x1 - x0)
    local z = z0 + np[2] * (z1 - z0)
    return { x, GetSurfaceHeight(x, z), z }
end

function RouteToWorld(route, side)
    local out = {}
    for _, np in ipairs(route) do
        table.insert(out, ToWorld(np, side))
    end
    return out
end

function WaterDepth(x, z)
    return GetSurfaceHeight(x, z) - GetTerrainHeight(x, z)
end

-- Spiral search for the closest point whose water depth >= minDepth.
function FindNearestWater(origin, minDepth, maxRadius)
    minDepth = minDepth or Config.DeepWaterDepth
    maxRadius = maxRadius or 300
    local x0, z0, x1, z1 = MapBounds()
    if WaterDepth(origin[1], origin[3]) >= minDepth then
        return { origin[1], GetSurfaceHeight(origin[1], origin[3]), origin[3] }
    end
    local r = 8
    while r <= maxRadius do
        local best, bestD
        local steps = math.max(8, math.floor(r / 4))
        for i = 0, steps - 1 do
            local a = (i / steps) * 2 * math.pi
            local x = origin[1] + math.cos(a) * r
            local z = origin[3] + math.sin(a) * r
            if x > x0 and x < x1 and z > z0 and z < z1 and WaterDepth(x, z) >= minDepth then
                local d = r
                if not bestD or d < bestD then best, bestD = { x, GetSurfaceHeight(x, z), z }, d end
            end
        end
        if best then return best end
        r = r + 8
    end
    return nil
end

-- Find a buildable spot for bpId near pos (spiral). Returns position or nil.
function FindBuildSpot(brain, bpId, pos, maxRadius)
    maxRadius = maxRadius or 30
    if brain:CanBuildStructureAt(bpId, pos) then return pos end
    local r = 4
    while r <= maxRadius do
        for i = 0, 11 do
            local a = (i / 12) * 2 * math.pi
            local p = { pos[1] + math.cos(a) * r, 0, pos[3] + math.sin(a) * r }
            p[2] = GetSurfaceHeight(p[1], p[3])
            if brain:CanBuildStructureAt(bpId, p) then return p end
        end
        r = r + 4
    end
    return nil
end

-- Order a builder to place a structure near pos. Returns true if issued.
function BuildNear(brain, builder, bpId, pos, maxRadius)
    if not bpId or not Alive(builder) or not builder:CanBuild(bpId) then return false end
    local spot = FindBuildSpot(brain, bpId, pos, maxRadius)
    if not spot then return false end
    IssueBuildMobile({ builder }, spot, bpId, {})
    return true
end

function CountAround(brain, category, pos, radius, alliance)
    return Count(brain:GetUnitsAroundPoint(category, pos, radius, alliance or 'Ally'))
end

function IsIdle(unit)
    return Alive(unit) and unit:IsIdleState() and not unit:IsUnitState('Upgrading')
        and not unit:IsUnitState('Enhancing') and not unit:IsUnitState('Building')
end

function Commander(brain)
    local list = brain:GetListOfUnits(categories.COMMAND, false)
    for _, u in ipairs(list) do
        if Alive(u) then return u end
    end
    return nil
end

function BrainDefeated(brain)
    if brain.Result == 'defeat' then return true end
    if brain.IsDefeated and brain:IsDefeated() then return true end
    return false
end

-- Run step(brain, ctx) every `interval` seconds until the brain is defeated.
-- Each step is pcall'd so a single error never kills the controller.
function RunLoop(name, brain, ctx, interval, step)
    while not BrainDefeated(brain) do
        local ok, err = pcall(step, brain, ctx)
        if not ok then
            WARN('DualGap [' .. tostring(brain.Name) .. '] ' .. name .. ': ' .. tostring(err))
        end
        WaitSeconds(interval)
    end
end

function Log(brain, msg)
    LOG('DualGap [' .. tostring(brain.Nickname or brain.Name) .. ']: ' .. msg)
end
