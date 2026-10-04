-- Who may build on which mass marker.
--
-- Every mass marker inside the layout gets one owner (an army name) at game
-- start, see the MidBand / MidSplitZ comment in DualGapConfig. Bots only ever
-- build their own markers. When a player is defeated, its markers are split
-- in half between the two nearest living allies (human or bot); a bot then
-- builds its half, a human is free to take theirs.
--
-- The table is module-level, so all DualGap brains share one view.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

-- markers[i] = { pos = {x,y,z}, owner = 'ARMY_n', base = bool, zone = 'BASE'|'MID'|'WATER'|'OTHER' }
local markers = nil
local handledDefeat = {}

local function SlotBy(side, pred)
    for name, s in pairs(RoleManager.GetSlots()) do
        if s.side == side and pred(s) then return name, s end
    end
    return nil
end

local function NearestSlot(pos, side)
    local best, bestD
    for name, s in pairs(RoleManager.GetSlots()) do
        if not side or s.side == side then
            local d = Utils.Dist2D(pos, s.pos)
            if not bestD or d < bestD then best, bestD = name, d end
        end
    end
    return best, bestD
end

-- Pure classification of one marker; exposed for tests.
function ClassifyMarker(pos, isWater)
    local nx, nz = Utils.Normalise(pos[1], pos[3])
    if nz < 0 or nz > 1 or nx < 0 or nx > 1 then return nil, 'OUTSIDE' end
    local side = (nx <= 0.5) and 'LEFT' or 'RIGHT'

    local near, d = NearestSlot(pos, nil)
    if near and d <= Config.BaseRadius then return near, 'BASE' end

    if isWater then
        local naval = SlotBy(side, function(s) return s.role == 'NAVAL' end)
        if naval then return naval, 'WATER' end
    end

    if nx >= Config.MidBand[1] and nx <= Config.MidBand[2] then
        local wantRank = (nz < Config.MidSplitZ) and 2 or 3
        local g = SlotBy(side, function(s) return s.role == 'GROUND' and s.rank == wantRank end)
            or SlotBy(side, function(s) return s.role == 'GROUND' end)
        if g then return g, 'MID' end
    end

    return NearestSlot(pos, side), 'OTHER'
end

function Init()
    if markers then return end
    markers = {}
    for _, m in pairs(ScenarioUtils.GetMarkers() or {}) do
        if m.type == 'Mass' and m.position then
            local p = m.position
            local owner, zone = ClassifyMarker(p, Utils.WaterDepth(p[1], p[3]) > 0.5)
            if owner then
                table.insert(markers, { pos = p, owner = owner, zone = zone, original = owner })
            end
        end
    end
    local counts = {}
    for _, m in ipairs(markers) do counts[m.owner] = (counts[m.owner] or 0) + 1 end
    for name, n in pairs(counts) do LOG('DualGap: mex owner ' .. name .. ' = ' .. n) end
end

function All()
    Init()
    return markers
end

-- Markers owned by an army; zone optional ('BASE', 'MID', ...).
function Owned(armyName, zone)
    Init()
    local out = {}
    for _, m in ipairs(markers) do
        if m.owner == armyName and (not zone or m.zone == zone) then table.insert(out, m) end
    end
    return out
end

-- Own mass extractor standing on a marker, if any.
function ExtractorAt(brain, pos)
    for _, u in ipairs(brain:GetUnitsAroundPoint(categories.MASSEXTRACTION, pos, 1.5, 'Ally') or {}) do
        if Utils.Alive(u) and u:GetAIBrain() == brain then return u end
    end
    return nil
end

function IsFree(brain, pos)
    local id = Utils.FactionId(brain, 'MassExtractorT1')
    return id and brain:CanBuildStructureAt(id, pos)
end

-- Nearest free marker owned by this brain, optionally within maxDist of `from`.
function NearestFree(brain, from, zone, maxDist, exclude)
    local best, bestD
    for _, m in ipairs(Owned(brain.Name, zone)) do
        if not (exclude and exclude[m]) and IsFree(brain, m.pos) then
            local d = Utils.Dist2D(from, m.pos)
            if (not maxDist or d <= maxDist) and (not bestD or d < bestD) then best, bestD = m, d end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Defeated players: split their markers between the two nearest living
-- allies. Split by preference: markers are sorted by how much closer they
-- are to ally A than to ally B, and A takes the first half.
---------------------------------------------------------------------------
local function BrainByName(name)
    for _, b in ipairs(ArmyBrains) do
        if b.Name == name then return b end
    end
    return nil
end

local function Defeated(b)
    return (not b) or Utils.BrainDefeated(b)
end

-- Exposed for tests: returns the two receivers' shares.
function SplitBetween(list, posA, posB)
    table.sort(list, function(m1, m2)
        return (Utils.Dist2D(m1.pos, posA) - Utils.Dist2D(m1.pos, posB))
             < (Utils.Dist2D(m2.pos, posA) - Utils.Dist2D(m2.pos, posB))
    end)
    local half = math.ceil(table.getn(list) / 2)
    local a, b = {}, {}
    for i, m in ipairs(list) do
        if i <= half then table.insert(a, m) else table.insert(b, m) end
    end
    return a, b
end

-- Who took over a defeated player's mexes (the nearest ally): it also
-- takes over the dead player's duties (e.g. the group's base AA).
local heirs = {}
function Heir(name)
    return heirs[name]
end

-- Exposed for tests: follow the heirs from `name` to the first player still
-- in the game (alive(name)), or nil.
function FollowHeirs(name, alive, heir)
    local n = name
    for i = 1, 12 do
        if not n then return nil end
        if alive(n) then return n end
        n = heir(n)
    end
    return nil
end

local function InGame(name)
    local b = BrainByName(name)
    return b ~= nil and not Defeated(b)
end

-- The player now holding `name`'s role: itself while in the game, else its
-- heir (who took its mexes), and so on.
function Holder(name)
    return FollowHeirs(name, InGame, Heir)
end

-- Roles a player holds: its own, plus those of defeated players it inherited.
function DutiesOf(name)
    local out = {}
    for slotName, s in pairs(RoleManager.GetSlots()) do
        if s.role and Holder(slotName) == name then out[s.role] = true end
    end
    return out
end

-- Start positions of the players holding `role` on `side` now (a defeated
-- ECO's duty moves to its heir's base).
function DutyPositions(side, role)
    local out = {}
    local slots = RoleManager.GetSlots()
    for slotName, s in pairs(slots) do
        if s.side == side and s.role == role then
            local h = Holder(slotName)
            if h and slots[h] then table.insert(out, slots[h].pos) end
        end
    end
    return out
end

local function Redistribute(deadName)
    local dead = BrainByName(deadName)
    local slots = RoleManager.GetSlots()
    local deadSlot = slots[deadName]
    if not deadSlot then return end

    -- Living allies, nearest first.
    local allies = {}
    for _, b in ipairs(ArmyBrains) do
        -- Empty slot (never had a player): allies are the same map side.
        local allied
        if dead then
            allied = IsAlly(b:GetArmyIndex(), dead:GetArmyIndex())
        else
            allied = slots[b.Name] and slots[b.Name].side == deadSlot.side
        end
        if b.Name ~= deadName and slots[b.Name] and not Defeated(b) and allied then
            table.insert(allies, { name = b.Name, pos = slots[b.Name].pos,
                d = Utils.Dist2D(slots[b.Name].pos, deadSlot.pos) })
        end
    end
    table.sort(allies, function(x, y) return x.d < y.d end)
    if table.getn(allies) == 0 then return end

    heirs[deadName] = allies[1].name
    local list = Owned(deadName)
    if table.getn(allies) == 1 then
        for _, m in ipairs(list) do m.owner = allies[1].name end
    else
        local a, b = SplitBetween(list, allies[1].pos, allies[2].pos)
        for _, m in ipairs(a) do m.owner = allies[1].name end
        for _, m in ipairs(b) do m.owner = allies[2].name end
    end
    LOG('DualGap: ' .. deadName .. ' defeated, ' .. table.getn(list) .. ' mexes shared')
end

local function WatchDefeats()
    while true do
        WaitSeconds(5)
        for name, _ in pairs(RoleManager.GetSlots()) do
            if not handledDefeat[name] then
                local b = BrainByName(name)
                -- An empty slot counts as defeated from the start.
                if Defeated(b) then
                    handledDefeat[name] = true
                    Redistribute(name)
                end
            end
        end
    end
end

local watching = false
function StartWatcher()
    if watching then return end
    watching = true
    Init()
    ForkThread(WatchDefeats)
end
