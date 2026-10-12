-- General staff: one per team side. Every Config.StaffSeconds it weighs the
-- team's forces against the known enemy forces in each zone of the map and
-- writes the team's orders on a board the branch commands read:
--
--   zones   UPPER (upper mid), LOWER (lower mid), WATER (the basin), AIR
--           (the whole map): own and known enemy mass, and a stance -
--           ATTACK (clearly stronger), DEFEND (clearly weaker), HOLD
--   focus   the zone the team pushes (the ATTACK zone with the best ratio)
--
-- Own forces are the whole team's (allied units are no secret); enemy forces
-- only what the team has seen or has on radar (Intel.Known).
-- Stage 1: the staff only evaluates and announces (log, telemetry, team
-- chat); the branches still run on their own rules.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')

local Alive = Utils.Alive

-- Zones in normalised map coordinates (the map is mirrored left-right, so
-- one set serves both teams): { nx0, nx1, nz0, nz1 }.
local Zones = {
    UPPER = { 0.28, 0.72, 0.00, 0.37 },
    LOWER = { 0.28, 0.72, 0.37, 0.58 },
    WATER = { 0.22, 0.78, 0.58, 1.00 },
}
local ZoneOrder = { 'UPPER', 'LOWER', 'WATER', 'AIR' }
local ZoneName = { UPPER = 'the upper mid', LOWER = 'the lower mid', WATER = 'the water', AIR = 'the air' }

local CatLandForce = categories.LAND * categories.MOBILE - categories.ENGINEER - categories.COMMAND - categories.SCOUT
local CatNavalForce = categories.NAVAL * categories.MOBILE - categories.ENGINEER
local CatAirForce = categories.AIR * categories.MOBILE - categories.SCOUT - categories.TRANSPORTATION - categories.SATELLITE
local CatDefence = categories.STRUCTURE * categories.DEFENSE

-- Exposed for tests: the zone of a normalised point, or nil.
function ZoneOf(nx, nz)
    for _, name in ipairs({ 'UPPER', 'LOWER', 'WATER' }) do
        local z = Zones[name]
        if nx >= z[1] and nx <= z[2] and nz >= z[3] and nz < z[4] then return name end
    end
    return nil
end

-- Exposed for tests: the stance for own vs enemy mass, with hysteresis
-- (an ATTACK holds until the edge drops below StaffHoldRatio).
function Stance(own, enemy, prev)
    local min = Config.StaffMinForce
    if prev == 'ATTACK' and own >= min and own >= Config.StaffHoldRatio * enemy then return 'ATTACK' end
    if own >= min and own >= Config.StaffAttackRatio * enemy then return 'ATTACK' end
    if enemy >= min and enemy >= Config.StaffDefendRatio * own then return 'DEFEND' end
    return 'HOLD'
end

-- Exposed for tests: the focus zone - the ATTACK zone (not AIR) with the
-- best own/enemy ratio, or nil.
function PickFocus(zones)
    local best, bestR
    for _, name in ipairs({ 'UPPER', 'LOWER', 'WATER' }) do
        local z = zones[name]
        if z and z.stance == 'ATTACK' then
            local r = z.own / math.max(1, z.enemy)
            if not bestR or r > bestR then best, bestR = name, r end
        end
    end
    return best
end

local function Mass(u)
    local eco = u:GetBlueprint().Economy
    return (eco and eco.BuildCostMass) or 0
end

-- Own (allied) and known enemy mass per zone, seen through `brain`.
local function Measure(brain)
    local x0, z0, x1, z1 = Utils.MapBounds()
    local center = { (x0 + x1) / 2, 0, (z0 + z1) / 2 }
    local radius = math.max(x1 - x0, z1 - z0)
    local army = brain:GetArmyIndex()
    local out = {}
    for _, name in ipairs(ZoneOrder) do out[name] = { own = 0, enemy = 0 } end
    local function add(list, key, weight)
        for _, u in ipairs(list or {}) do
            if Alive(u) and u:GetFractionComplete() >= 1 and (key == 'own' or Intel.Known(u, army)) then
                local m = Mass(u) * weight
                if EntityCategoryContains(CatAirForce, u) then
                    out.AIR[key] = out.AIR[key] + m
                else
                    local p = u:GetPosition()
                    local nx, nz = Utils.Normalise(p[1], p[3])
                    local zone = ZoneOf(nx, nz)
                    if zone then out[zone][key] = out[zone][key] + m end
                end
            end
        end
    end
    local forces = CatLandForce + CatNavalForce + CatAirForce
    add(brain:GetUnitsAroundPoint(forces, center, radius, 'Ally'), 'own', 1)
    add(brain:GetUnitsAroundPoint(forces, center, radius, 'Enemy'), 'enemy', 1)
    -- Static defences hold a zone too, at part of their worth.
    add(brain:GetUnitsAroundPoint(CatDefence, center, radius, 'Ally'), 'own', Config.StaffDefenceWeight)
    add(brain:GetUnitsAroundPoint(CatDefence, center, radius, 'Enemy'), 'enemy', Config.StaffDefenceWeight)
    return out
end

---------------------------------------------------------------------------
-- The board
---------------------------------------------------------------------------
local staffs = {}        -- side -> { brains = {}, orders = {} }

local function Staff(side)
    staffs[side] = staffs[side] or { brains = {}, orders = nil }
    return staffs[side]
end

function Register(brain, side)
    table.insert(Staff(side).brains, brain)
end

-- The team's current orders (nil before the first evaluation).
function Orders(side)
    return Staff(side).orders
end

-- Stance of a zone for this side ('HOLD' when unknown).
function ZoneStance(side, zone)
    local o = Orders(side)
    return (o and o.zones[zone] and o.zones[zone].stance) or 'HOLD'
end

local function Evaluate(side, brain)
    local st = Staff(side)
    local prev = st.orders
    local m = Measure(brain)
    -- Lower levels misjudge the enemy (DualGapConfig.Levels staffNoise).
    local noise = Utils.Level(brain.DualGap).staffNoise
    if noise > 0 then
        for _, name in ipairs(ZoneOrder) do
            local r = (Random and Random()) or math.random()
            m[name].enemy = m[name].enemy * (1 + noise * (2 * r - 1))
        end
    end
    local orders = { at = GetGameTimeSeconds(), zones = {} }
    for _, name in ipairs(ZoneOrder) do
        local prevStance = prev and prev.zones[name] and prev.zones[name].stance
        orders.zones[name] = { own = math.floor(m[name].own), enemy = math.floor(m[name].enemy),
            stance = Stance(m[name].own, m[name].enemy, prevStance) }
    end
    orders.focus = PickFocus(orders.zones)
    st.orders = orders

    -- Announce changes.
    local parts = {}
    for _, name in ipairs(ZoneOrder) do
        local z = orders.zones[name]
        table.insert(parts, name .. '=' .. z.stance .. '(' .. z.own .. '/' .. z.enemy .. ')')
        if not (prev and prev.zones[name].stance == z.stance) then
            Utils.Log(brain, 'STAFF ' .. side .. ': ' .. name .. ' -> ' .. z.stance .. ' (own ' .. z.own .. ', enemy ' .. z.enemy .. ')')
        end
    end
    if orders.focus ~= (prev and prev.focus) then
        Utils.Log(brain, 'STAFF ' .. side .. ': focus ' .. tostring(orders.focus) .. ' | ' .. table.concat(parts, ' '))
        if orders.focus then
            local zone = Zones[orders.focus]
            local nx, nz = (zone[1] + zone[2]) / 2, (zone[3] + zone[4]) / 2
            Comms.Say(brain, side, 'staff:focus', 'Team focus: push ' .. ZoneName[orders.focus] .. '!',
                Utils.ToWorld({ nx, nz }, side), 'attack')
        end
    end
    local Stats = import('/mods/DualGapAI/lua/AI/DualGapStats.lua')
    local rec = { ev = 'orders', t = orders.at, side = side, focus = orders.focus or '', zones = {} }
    for _, name in ipairs(ZoneOrder) do
        local z = orders.zones[name]
        rec.zones[name] = { z.own, z.enemy, z.stance }
    end
    Stats.Emit(rec)
end

local running = false
function StartStaff()
    if running then return end
    running = true
    ForkThread(function()
        while true do
            WaitSeconds(Config.StaffSeconds)
            for side, st in pairs(staffs) do
                -- Any living DualGap brain of the side does the staff work.
                for _, b in ipairs(st.brains) do
                    if not Utils.BrainDefeated(b) then
                        local ok, err = pcall(Evaluate, side, b)
                        if not ok then WARN('DualGap staff: ' .. tostring(err)) end
                        break
                    end
                end
            end
        end
    end)
end

function Start(brain, ctx)
    Register(brain, ctx.side)
    StartStaff()
end
