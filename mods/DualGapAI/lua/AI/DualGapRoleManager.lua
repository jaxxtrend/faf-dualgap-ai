-- Assigns GROUND / NAVAL / AIR / ECO from the spawn position.
--
-- The role is a property of the start marker, not of the brain, so roles can
-- be computed for every slot (including human allies). AIR uses that to know
-- where its GROUND allies stand.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local Roles = Config.Roles
local slotCache = nil

function IsDualGapMap()
    return Utils.IsDualGapMap()
end

local function GetStartMarkers()
    local out = {}
    for i = 1, 16 do
        local name = 'ARMY_' .. i
        local m = ScenarioUtils.GetMarker(name)
        if m and m.position then
            local nx, nz = Utils.Normalise(m.position[1], m.position[3])
            table.insert(out, { name = name, pos = m.position, nx = nx, nz = nz })
        end
    end
    return out
end

local function NearestSlotRole(nx, nz)
    -- Fold right-team spawns onto the left-team layout.
    if nx > 0.5 then nx = 1 - nx end
    local best, bestD
    for _, slot in ipairs(Config.SpawnSlots) do
        local dx, dz = nx - slot.anchor[1], nz - slot.anchor[2]
        local d = dx * dx + dz * dz
        if not bestD or d < bestD then best, bestD = slot.role, d end
    end
    return best
end

-- Classify a list of {name, nx, nz} markers. Pure function, unit-testable.
function ClassifyMarkers(markers)
    local result = {}
    local sides = { LEFT = {}, RIGHT = {} }
    for _, m in ipairs(markers) do
        m.side = (m.nx <= 0.5) and 'LEFT' or 'RIGHT'
        table.insert(sides[m.side], m)
    end
    local slotCount = table.getn(Config.SpawnSlots)
    for side, list in pairs(sides) do
        table.sort(list, function(a, b) return a.nz < b.nz end)
        local byRank = (table.getn(list) == slotCount)
        for rank, m in ipairs(list) do
            local role
            if byRank then role = Config.SpawnSlots[rank].role else role = NearestSlotRole(m.nx, m.nz) end
            role = Config.RoleOverrides[m.name] or role
            result[m.name] = { role = role, side = side, rank = rank, nx = m.nx, nz = m.nz, pos = m.pos }
        end
    end
    return result
end

-- Slots are computed once per game; tests reset between marker sets.
function ResetCache()
    slotCache = nil
end

function GetSlots()
    if not slotCache then
        slotCache = ClassifyMarkers(GetStartMarkers())
        for name, s in pairs(slotCache) do
            LOG(string.format('DualGap: %s side=%s rank=%d norm=(%.3f, %.3f) role=%s',
                name, s.side, s.rank, s.nx, s.nz, s.role))
        end
    end
    return slotCache
end

-- Returns role, side for a brain.
function DetermineRoleBySpawn(brain)
    local x, z = brain:GetArmyStartPos()
    local nx, nz = Utils.Normalise(x, z)
    local side = (nx <= 0.5) and 'LEFT' or 'RIGHT'

    if Config.RoleOverrides[brain.Name] then
        return Config.RoleOverrides[brain.Name], side
    end
    if not IsDualGapMap() then
        return Config.FallbackRole, side
    end
    local slot = GetSlots()[brain.Name]
    if slot then
        return slot.role, slot.side
    end
    return NearestSlotRole(nx, nz) or Roles.AIR, side
end

