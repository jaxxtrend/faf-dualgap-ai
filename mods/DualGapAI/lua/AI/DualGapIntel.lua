-- Team intelligence and scouts.
--
-- Everything here only counts enemy units this team has actually scouted:
-- a structure once seen stays known (IsSeenEver), mobile units count while
-- seen or on radar. That is what makes scouting matter: a game ender nobody
-- has seen triggers no anti-nuke, no shields and no strike mission.
--
-- Memory is per map side (the two teams of Dual Gap) and shared by all
-- DualGap brains on that side.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')

local Alive = Utils.Alive

local CatEnders = categories.STRUCTURE * (categories.NUKE
    + categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
    + categories.EXPERIMENTAL)
local CatEnemyT4 = categories.EXPERIMENTAL * categories.MOBILE
local CatAA = categories.ANTIAIR * (categories.LAND + categories.NAVAL + categories.STRUCTURE) - categories.AIR
local CatNaval = categories.NAVAL * (categories.MOBILE + categories.STRUCTURE)
local CatEnemyAntiNuke = categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE

local teams = {}

local function Team(side)
    if not teams[side] then
        teams[side] = { enders = {}, t4Seen = false, aa = {}, naval = {}, antiNukes = {} }
    end
    return teams[side]
end

-- Does `army` have intel on enemy unit e?
function Known(e, army)
    if not Alive(e) or not e.GetBlip then return false end
    local ok, blip = pcall(e.GetBlip, e, army)
    if not ok or not blip then return false end
    if EntityCategoryContains(categories.STRUCTURE, e) then return blip:IsSeenEver(army) end
    return blip:IsSeenNow(army) or blip:IsOnRadar(army)
end

local function EnderKind(e)
    if EntityCategoryContains(categories.NUKE, e) then return 'NUKE' end
    if EntityCategoryContains(categories.ARTILLERY, e) then return 'ARTY' end
    return 'T4'
end

local function KnownEnemies(brain, cat)
    local army = brain:GetArmyIndex()
    local x0, z0, x1, z1 = Utils.MapBounds()
    local center = { (x0 + x1) / 2, 0, (z0 + z1) / 2 }
    local out = {}
    for _, e in ipairs(brain:GetUnitsAroundPoint(cat, center, math.max(x1 - x0, z1 - z0), 'Enemy') or {}) do
        if Known(e, army) then table.insert(out, e) end
    end
    return out
end

local function Scan(side, brain)
    local t = Team(side)
    for _, e in ipairs(KnownEnemies(brain, CatEnders)) do
        local key = e.EntityId or tostring(e)
        if not t.enders[key] then
            t.enders[key] = { unit = e, kind = EnderKind(e), pos = e:GetPosition() }
            Utils.Log(brain, 'scouted enemy game ender: ' .. EnderKind(e) .. ' '
                .. tostring(e:GetBlueprint().BlueprintId))
        end
    end
    for key, rec in pairs(t.enders) do
        if not Alive(rec.unit) then t.enders[key] = nil end
    end
    if not t.t4Seen and table.getn(KnownEnemies(brain, CatEnemyT4)) > 0 then
        t.t4Seen = true
        Utils.Log(brain, 'scouted an enemy experimental unit')
    end
    t.aa = {}
    for _, e in ipairs(KnownEnemies(brain, CatAA)) do table.insert(t.aa, e:GetPosition()) end
    t.naval = KnownEnemies(brain, CatNaval)
    t.antiNukes = {}
    for _, e in ipairs(KnownEnemies(brain, CatEnemyAntiNuke)) do table.insert(t.antiNukes, e:GetPosition()) end
end

---------------------------------------------------------------------------
-- Queries. `side` is always the ASKING team's side: its memory of the enemy.
---------------------------------------------------------------------------
function Enders(side, kind)
    local out = {}
    for _, rec in pairs(Team(side).enders) do
        if Alive(rec.unit) and (not kind or rec.kind == kind) then table.insert(out, rec) end
    end
    return out
end

function EnemyT4Seen(side)
    return Team(side).t4Seen
end

-- Known enemy AA units within radius of pos.
function AAThreat(side, pos, radius)
    local n = 0
    radius = radius or Config.AARadius
    for _, p in ipairs(Team(side).aa) do
        if Utils.Dist2D(p, pos) <= radius then n = n + 1 end
    end
    return n
end

function KnownNaval(side)
    return Utils.FilterAlive(Team(side).naval)
end

-- Is pos covered by a known enemy anti-nuke (SMD range 90)?
function UnderEnemyAntiNuke(side, pos)
    for _, p in ipairs(Team(side).antiNukes) do
        if Utils.Dist2D(p, pos) <= 92 then return true end
    end
    return false
end

-- Exposed for tests: replace a side's memory.
function SetTeamForTest(side, data)
    teams[side] = data
end

---------------------------------------------------------------------------
-- Scanner: one thread for the whole sim, any living DualGap brain of a side
-- does the looking (allies share vision in FAF).
---------------------------------------------------------------------------
local observers = {}

function Register(brain, side)
    observers[side] = observers[side] or {}
    table.insert(observers[side], brain)
end

local scanning = false
function StartScanner()
    if scanning then return end
    scanning = true
    ForkThread(function()
        while true do
            WaitSeconds(5)
            for side, list in pairs(observers) do
                for _, b in ipairs(list) do
                    if not Utils.BrainDefeated(b) then
                        local ok, err = pcall(Scan, side, b)
                        if not ok then WARN('DualGap intel: ' .. tostring(err)) end
                        break
                    end
                end
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Scouts (per brain). Air scouts loop over the enemy bases, the enemy water
-- and the front; land scouts sit ahead of the own mid zone as observers.
---------------------------------------------------------------------------
local CatAirScout = categories.AIR * categories.SCOUT * categories.MOBILE
local CatLandScout = categories.LAND * categories.SCOUT * categories.MOBILE

local function OtherSide(side)
    if side == 'LEFT' then return 'RIGHT' end
    return 'LEFT'
end

local function AirScoutRoute(ctx, offset)
    local pts = {}
    local enemy = OtherSide(ctx.side)
    for _, s in pairs(RoleManager.GetSlots()) do
        if s.side == enemy then table.insert(pts, s.pos) end
    end
    table.sort(pts, function(a, b) return a[3] < b[3] end)
    table.insert(pts, Routes.GetPoint('NavalRally', enemy))
    table.insert(pts, Routes.GetPoint('BasinCenter', ctx.side))
    table.insert(pts, Routes.GetPoint('LandCenter', ctx.side))
    -- Rotate so several scouts don't fly in a bunch.
    local out = {}
    local n = table.getn(pts)
    for i = 1, n do
        local j = i + offset
        while j > n do j = j - n end
        table.insert(out, pts[j])
    end
    return out
end

local function ScoutStep(brain, ctx)
    local now = GetGameTimeSeconds()
    local i = 0
    for _, u in ipairs(brain:GetListOfUnits(CatAirScout, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            i = i + 1
            u.DualGapAssigned = true
            if u:IsIdleState() or not u.DGScoutAt or now - u.DGScoutAt > Config.ScoutRepathSeconds then
                u.DGScoutAt = now
                IssueClearCommands({ u })
                for _, p in ipairs(AirScoutRoute(ctx, i * 2)) do IssuePatrol({ u }, p) end
            end
        end
    end
    local j = 0
    for _, u in ipairs(brain:GetListOfUnits(CatLandScout, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            j = j + 1
            u.DualGapAssigned = true
            if u:IsIdleState() then
                local c = ctx.choke or Routes.GetPoint('Choke', ctx.side)
                local dir = (ctx.side == 'LEFT') and 1 or -1
                -- First scout watches ahead of the wall, the next one further out.
                local x = c[1] + dir * (20 + 25 * j)
                IssueMove({ u }, { x, GetSurfaceHeight(x, c[3]), c[3] + (j - 1) * 12 })
            end
        end
    end
end

function Start(brain, ctx)
    Register(brain, ctx.side)
    StartScanner()
    ForkThread(Utils.RunLoop, 'Scouts', brain, ctx, 5, ScoutStep)
end
