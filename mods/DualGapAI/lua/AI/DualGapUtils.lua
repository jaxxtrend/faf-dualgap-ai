-- Shared helpers. Written for FAF's Lua 5.0 (no '#', no '%', no varargs).

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')

-- Structure / unit IDs per faction index (1 UEF, 2 Aeon, 3 Cybran, 4 Seraphim).
UnitIds = {
    MassExtractorT1 = { 'ueb1103', 'uab1103', 'urb1103', 'xsb1103' },
    HydroT1        = { 'ueb1102', 'uab1102', 'urb1102', 'xsb1102' },
    PointDefenseT1 = { 'ueb2101', 'uab2101', 'urb2101', 'xsb2101' },
    PointDefenseT2 = { 'ueb2301', 'uab2301', 'urb2301', 'xsb2301' },
    RadarT1        = { 'ueb3101', 'uab3101', 'urb3101', 'xsb3101' },   -- -> T2 radar -> Omni
    SonarT1        = { 'ueb3102', 'uab3102', 'urb3102', 'xsb3102' },   -- -> T2 sonar
    AntiAirT1      = { 'ueb2104', 'uab2104', 'urb2104', 'xsb2104' },
    AntiAirT2      = { 'ueb2204', 'uab2204', 'urb2204', 'xsb2204' },   -- flak
    AntiAirT3      = { 'ueb2304', 'uab2304', 'urb2304', 'xsb2304' },   -- SAM
    ShieldT2       = { 'ueb4202', 'uab4202', 'urb4202', 'xsb4202' },
    Wall           = { 'ueb5101', 'uab5101', 'urb5101', 'xsb5101' },
    NavalFactoryT1 = { 'ueb0103', 'uab0103', 'urb0103', 'xsb0103' },
    TorpedoT1      = { 'ueb2109', 'uab2109', 'urb2109', 'xsb2109' },
    TorpedoT2      = { 'ueb2205', 'uab2205', 'urb2205', 'xsb2205' },
    StratArtyT3    = { 'ueb2302', 'uab2302', 'urb2302', 'xsb2302' },
    NukeSilo       = { 'ueb2305', 'uab2305', 'urb2305', 'xsb2305' },
    -- Faction experimental for ECO: Mavor, Paragon, Scathis, Yolona Oss.
    StrategicT4    = { 'ueb2401', 'xab1401', 'url0401', 'xsb2401' },

    PowerT1        = { 'ueb1101', 'uab1101', 'urb1101', 'xsb1101' },
    PowerT2        = { 'ueb1201', 'uab1201', 'urb1201', 'xsb1201' },
    PowerT3        = { 'ueb1301', 'uab1301', 'urb1301', 'xsb1301' },
    EnergyStorage  = { 'ueb1105', 'uab1105', 'urb1105', 'xsb1105' },
    MassStorage    = { 'ueb1106', 'uab1106', 'urb1106', 'xsb1106' },
    MassFabT3      = { 'ueb1303', 'uab1303', 'urb1303', 'xsb1303' },

    EngineerT1     = { 'uel0105', 'ual0105', 'url0105', 'xsl0105' },
    EngineerT2     = { 'uel0208', 'ual0208', 'url0208', 'xsl0208' },
    EngineerT3     = { 'uel0309', 'ual0309', 'url0309', 'xsl0309' },
    AirScout       = { 'uea0101', 'uaa0101', 'ura0101', 'xsa0101' },

    T1Tank         = { 'uel0201', 'ual0201', 'url0107', 'xsl0201' },
    T1Artillery    = { 'uel0103', 'ual0103', 'url0103', 'xsl0103' },
    T2Tank         = { 'uel0202', 'ual0202', 'url0202', 'xsl0202' },
    T2MML          = { 'uel0111', 'ual0111', 'url0111', 'xsl0111' },
    T3Assault      = { 'uel0303', 'ual0303', 'url0303', 'xsl0303' },
    T1Interceptor  = { 'uea0102', 'uaa0102', 'ura0102', 'xsa0102' },
    T1Bomber       = { 'uea0103', 'uaa0103', 'ura0103', 'xsa0103' },
    T2TorpBomber   = { 'uea0204', 'uaa0204', 'ura0204', 'xsa0204' },
    T3ASF          = { 'uea0303', 'uaa0303', 'ura0303', 'xsa0303' },
    T3StratBomber  = { 'uea0304', 'uaa0304', 'ura0304', 'xsa0304' },
    T3Gunship      = { 'uea0305', 'xaa0305', 'xra0305', false },   -- Seraphim has none
    T1Frigate      = { 'ues0103', 'uas0103', 'urs0103', 'xss0103' },
    T1Sub          = { 'ues0203', 'uas0203', 'urs0203', 'xss0203' },
    T2Destroyer    = { 'ues0201', 'uas0201', 'urs0201', 'xss0201' },
    T2Cruiser      = { 'ues0202', 'uas0202', 'urs0202', 'xss0202' },
    T3Battleship   = { 'ues0302', 'uas0302', 'urs0302', 'xss0302' },

    LandScout      = { 'uel0101', 'ual0101', 'url0101', 'xsl0101' },
    SpyPlane       = { 'uea0302', 'uaa0302', 'ura0302', 'xsa0302' },
    ArtilleryT2    = { 'ueb2303', 'uab2303', 'urb2303', 'xsb2303' },
    -- Cybran has no directly buildable T3 shield: ED1 is built and upgraded.
    ShieldT3       = { 'ueb4301', 'uab4301', 'urb4202', 'xsb4301' },
    AntiNuke       = { 'ueb4302', 'uab4302', 'urb4302', 'xsb4302' },

    -- Experimentals per role. Seraphim has no naval experimental: the
    -- amphibious Ythotha walks the sea floor. UEF has no air experimental:
    -- the Novax satellite centre takes that slot.
    LandT4         = { 'uel0401', 'ual0401', 'url0402', 'xsl0401' },
    NavalT4        = { 'ues0401', 'uas0401', 'xrl0403', 'xsl0401' },
    AirT4          = { 'xeb2402', 'uaa0310', 'ura0401', 'xsa0402' },
    -- Game enders ECO picks from (StrategicT4 above is the faction artillery
    -- / launcher: Mavor, Paragon(unused), Scathis, Yolona Oss).
    ArtilleryT4    = { 'ueb2401', 'xab2307', 'url0401', 'xsb2401' },
}

-- Factory blueprint IDs. kind: 'Land' | 'Air' | 'Naval'.
-- T1 -> T2/T3 upgrades go to the HQ for the first factory of a kind and to
-- the cheaper support factory once an HQ of that tech exists.
local FactionPrefix = { 'ue', 'ua', 'ur', 'xs' }
local SupportPrefix = { 'ze', 'za', 'zr', 'zs' }
local KindDigit = { Land = '1', Air = '2', Naval = '3' }

function FactoryId(brain, kind, tech)
    local f = brain:GetFactionIndex()
    if not FactionPrefix[f] or not KindDigit[kind] then return nil end
    return FactionPrefix[f] .. 'b0' .. (tech or 1) .. '0' .. KindDigit[kind]
end

function SupportFactoryId(brain, kind, tech)
    local f = brain:GetFactionIndex()
    if not SupportPrefix[f] or not KindDigit[kind] then return nil end
    return SupportPrefix[f] .. 'b9' .. (tech + 3) .. '0' .. KindDigit[kind]
end

local KindCategory = {
    Land = categories.FACTORY * categories.LAND * categories.STRUCTURE,
    Air = categories.FACTORY * categories.AIR * categories.STRUCTURE,
    Naval = categories.FACTORY * categories.NAVAL * categories.STRUCTURE,
}

function FactoryCategory(kind)
    return KindCategory[kind]
end

function FactoryKind(unit)
    for kind, cat in pairs(KindCategory) do
        if EntityCategoryContains(cat, unit) then return kind end
    end
    return nil
end

-- Degrees for IssueFormMove / IssueFormAggressiveMove facing from -> to
-- (same formula as FAF's platoon-base.lua).
function FacingDegrees(from, to)
    local dx, dz = to[1] - from[1], to[3] - from[3]
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then return 0 end
    dx, dz = dx / len, dz / len
    local rads = math.acos(dz)
    if dx < 0 then rads = 2 * math.pi - rads end
    return rads * 180 / math.pi
end

function TechOf(unit)
    if EntityCategoryContains(categories.TECH3, unit) then return 3 end
    if EntityCategoryContains(categories.TECH2, unit) then return 2 end
    return 1
end

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

function IsDualGapMap()
    if Config.ForceDualGapLayout then return true end
    local name = string.lower(tostring(ScenarioInfo.name or '') .. ' ' .. tostring(ScenarioInfo.map or ''))
    for _, token in ipairs(Config.MapNameTokens) do
        if not string.find(name, token, 1, true) then return false end
    end
    return true
end

-- Rectangle the normalised layout refers to: fixed on Dual Gap, else the map.
function LayoutBounds()
    local r = Config.LayoutRect
    if r and IsDualGapMap() then return r[1], r[2], r[3], r[4] end
    return MapBounds()
end

function Normalise(x, z)
    local x0, z0, x1, z1 = LayoutBounds()
    return (x - x0) / (x1 - x0), (z - z0) / (z1 - z0)
end

-- Normalised left-team point -> world position for the given side.
function ToWorld(np, side)
    local x0, z0, x1, z1 = LayoutBounds()
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

-- Deepest water in the own rear (layout nx <= RearDepth for LEFT, mirrored
-- for RIGHT), inside the current playable area. Sampled on an 8-unit grid;
-- recomputed per call because the adaptive map can grow its playable area.
-- avoid / minDist: skip spots closer than minDist to avoid (a point or a
-- list of points).
RearDepth = 0.35

function DeepestRearWater(side, avoid, minDist)
    -- avoid: one point or a list of points.
    local avoidList = {}
    -- A point is {x, y, z}; anything else (incl. an empty table) is a list.
    if avoid and type(avoid[1]) == 'number' then avoidList = { avoid } elseif avoid then avoidList = avoid end
    local x0, z0, x1, z1 = MapBounds()
    local best, bestDepth
    local x = x0 + 4
    while x < x1 do
        local nx = Normalise(x, z0)
        local rear = (side == 'RIGHT' and nx >= 1 - RearDepth) or (side ~= 'RIGHT' and nx <= RearDepth)
        if rear then
            local z = z0 + 4
            while z < z1 do
                local d = WaterDepth(x, z)
                local far = true
                for _, a in ipairs(avoidList) do
                    if math.sqrt((x - a[1]) * (x - a[1]) + (z - a[3]) * (z - a[3])) < minDist then far = false; break end
                end
                if far and d >= Config.DeepWaterDepth and (not bestDepth or d > bestDepth) then
                    best, bestDepth = { x, GetSurfaceHeight(x, z), z }, d
                end
                z = z + 8
            end
        end
        x = x + 8
    end
    return best
end

-- Size of a structure's skirt (the cells it really occupies). Adjacency
-- bonuses and placement both work on the skirt, not on the smaller
-- Footprint: a T1 factory has Footprint 5 but Skirt 8.
function SizeOfBp(bp)
    if not bp then return 2 end
    local skirt = bp.Physics and bp.Physics.SkirtSizeX
    if skirt and skirt > 0 then return skirt end
    return (bp.Footprint and bp.Footprint.SizeX) or 2
end

function FootprintOf(id)
    return SizeOfBp(__blueprints[id])
end

-- Placement rule that keeps bases walkable: every structure keeps `gap` free
-- cells around it, and nothing is placed in the exit lane in front (+z) of a
-- factory, where new units roll out. Adjacency spots (power next to a
-- factory, storage next to a hydro) skip this check on purpose.
FactoryExitLane = 10

function HasClearance(brain, id, pos, gap)
    gap = gap or 2
    local size = FootprintOf(id)
    local near = brain:GetUnitsAroundPoint(categories.STRUCTURE, pos, size + 30, 'Ally') or {}
    for _, u in ipairs(near) do
        if Alive(u) then
            local up = u:GetPosition()
            local us = SizeOfBp(u:GetBlueprint())
            -- 0.01 slack: exactly touching (adjacency) is allowed.
            local half = (us + size) / 2 + gap - 0.01
            if math.abs(up[1] - pos[1]) < half and math.abs(up[3] - pos[3]) < half then return false end
            if EntityCategoryContains(categories.FACTORY, u) then
                local laneHalfX = us / 2 + 2 + size / 2
                local laneStart = up[3] + us / 2
                if math.abs(up[1] - pos[1]) < laneHalfX
                    and pos[3] + size / 2 > laneStart and pos[3] - size / 2 < laneStart + FactoryExitLane then
                    return false
                end
            end
        end
    end
    return true
end

-- Find a buildable spot for bpId near pos (spiral). Returns position or nil.
function FindBuildSpot(brain, bpId, pos, maxRadius, gap)
    maxRadius = maxRadius or 30
    if brain:CanBuildStructureAt(bpId, pos) and HasClearance(brain, bpId, pos, gap) then return pos end
    local r = 4
    while r <= maxRadius do
        for i = 0, 11 do
            local a = (i / 12) * 2 * math.pi
            local p = { pos[1] + math.cos(a) * r, 0, pos[3] + math.sin(a) * r }
            p[2] = GetSurfaceHeight(p[1], p[3])
            if brain:CanBuildStructureAt(bpId, p) and HasClearance(brain, bpId, p, gap) then return p end
        end
        r = r + 4
    end
    return nil
end

-- Order a builder to place a structure near pos. Returns true if issued.
-- gap: clearance cells (default 2; 0 for tight defensive lines).
function BuildNear(brain, builder, bpId, pos, maxRadius, gap)
    if not bpId or not Alive(builder) or not builder:CanBuild(bpId) then return false end
    local spot = FindBuildSpot(brain, bpId, pos, maxRadius, gap)
    if not spot then return false end
    IssueBuildMobile({ builder }, spot, bpId, {})
    return true
end

-- Realistic building (Config.MaxConcurrentBuilds): may this player start
-- one more new structure of bpId? Mexes and storages are always fine.
local CatFree = categories.MASSEXTRACTION + categories.MASSSTORAGE + categories.ENERGYSTORAGE + categories.WALL

function BuildWeight(bp)
    local eco = bp and bp.Economy
    if eco and (eco.BuildCostMass or 0) >= Config.ExpensiveMass then return 2 end
    return 1
end

-- Exposed for tests: the decision itself.
function SlotsAllow(usedWeight, newWeight, banked)
    local slots = Config.MaxConcurrentBuilds
    if banked then slots = slots + Config.BankedExtraBuilds end
    return usedWeight + newWeight <= slots
end

-- Does this player do `role`'s job: its own role, or one it inherited from
-- a defeated ally (ctx.duties, kept by DualGapInit)?
function HasDuty(ctx, role)
    return ctx.role == role or (ctx.duties ~= nil and ctx.duties[role] == true)
end

-- Mass storage well filled: spend it (more builds, units, engineers).
function MassBanked(brain)
    if not brain.GetEconomyStoredRatio then return false end
    return brain:GetEconomyStoredRatio('MASS') >= Config.MassBankedRatio
        and brain:GetEconomyStoredRatio('ENERGY') >= Config.BankedEnergyRatio
end

function CanStartBuild(brain, bpId)
    local bp = __blueprints[bpId]
    if not bp then return true end
    local cats = bp.CategoriesHash or {}
    if cats.MASSEXTRACTION or cats.MASSSTORAGE or cats.ENERGYSTORAGE or cats.WALL then return true end
    local used = 0
    for _, u in ipairs(brain:GetListOfUnits(categories.STRUCTURE - CatFree, false)) do
        if Alive(u) and u:GetFractionComplete() < 1 then used = used + BuildWeight(u:GetBlueprint()) end
    end
    return SlotsAllow(used, BuildWeight(bp), MassBanked(brain))
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

-- Is the unit below the water surface (a submerged ACU, a sub)?
function IsUnderwater(unit)
    local p = unit:GetPosition()
    return p[2] < GetSurfaceHeight(p[1], p[3]) - 1
end

-- Which side of the map a position is on ('LEFT' / 'RIGHT').
function SideOf(pos)
    local nx = Normalise(pos[1], pos[3])
    if nx < 0.5 then return 'LEFT' end
    return 'RIGHT'
end

function Log(brain, msg)
    -- '@<game seconds>' lets tools/parse_match.py put events on a timeline.
    LOG('DualGap [' .. tostring(brain.Nickname or brain.Name) .. '] @' .. math.floor(GetGameTimeSeconds())
        .. ': ' .. msg)
end
