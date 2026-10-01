-- Builder conditions used by the DualGap builder groups. The builder managers
-- call these as func(aiBrain, unpack(args)), so every function takes the brain
-- first. Kept self-contained so the builders don't depend on the signatures of
-- FAF's stock condition files.

local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

-- `cat` is a category object (preferred) or a category string.
local function CountCat(aiBrain, cat)
    if type(cat) == 'string' then cat = ParseEntityCategory(cat) end
    return table.getn(aiBrain:GetListOfUnits(cat, false))
end

function HaveLessThan(aiBrain, num, cat)
    return CountCat(aiBrain, cat) < num
end

function HaveAtLeast(aiBrain, num, cat)
    return CountCat(aiBrain, cat) >= num
end

-- Used by the placeholder builder that keeps the stock FactoryManager inert.
function Never(aiBrain)
    return false
end

function GameTimeBelow(aiBrain, seconds)
    return GetGameTimeSeconds() < seconds
end

function GameTimeAbove(aiBrain, seconds)
    return GetGameTimeSeconds() >= seconds
end

-- Mass income in mass per second.
function MassIncomeBelow(aiBrain, perSecond)
    return aiBrain:GetEconomyIncome('MASS') * 10 < perSecond
end

function MassIncomeAbove(aiBrain, perSecond)
    return aiBrain:GetEconomyIncome('MASS') * 10 >= perSecond
end

-- Energy storage low or drained: build power.
function EnergyLow(aiBrain, ratio)
    return aiBrain:GetEconomyStoredRatio('ENERGY') < ratio or aiBrain:GetEconomyTrend('ENERGY') < 0
end

function EnergyHealthy(aiBrain, ratio)
    return aiBrain:GetEconomyStoredRatio('ENERGY') >= ratio
end

function MassStoredAbove(aiBrain, ratio)
    return aiBrain:GetEconomyStoredRatio('MASS') >= ratio
end

-- Not in the ECO strategic phase (engineers belong to DualGapEconomy then).
function NotStrategicPhase(aiBrain)
    local ctx = aiBrain.DualGap
    return not (ctx and ctx.strategic)
end

-- A free resource marker of `markerType` ('Mass' / 'Hydrocarbon') within `dist`
-- of the builder manager's base. Stops resource builders spinning on nothing.
local function FreeMarkerWithin(aiBrain, locationType, dist, markerType, idKey)
    local bm = aiBrain.BuilderManagers and aiBrain.BuilderManagers[locationType]
    local base = bm and bm.Position
    local id = Utils.FactionId(aiBrain, idKey)
    if not base or not id then return false end
    for _, m in pairs(ScenarioUtils.GetMarkers() or {}) do
        if m.type == markerType and m.position
            and Utils.Dist2D(base, m.position) <= dist
            and aiBrain:CanBuildStructureAt(id, m.position) then
            return true
        end
    end
    return false
end

function FreeMassWithin(aiBrain, locationType, dist)
    return FreeMarkerWithin(aiBrain, locationType, dist, 'Mass', 'MassExtractorT1')
end

function FreeHydroWithin(aiBrain, locationType, dist)
    return FreeMarkerWithin(aiBrain, locationType, dist, 'Hydrocarbon', 'HydroT1')
end
