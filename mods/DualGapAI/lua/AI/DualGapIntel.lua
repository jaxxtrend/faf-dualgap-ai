-- Team intelligence and scouts.
--
-- Everything here only counts enemy units this team has actually scouted:
-- a structure once seen stays known (IsSeenEver), mobile units count while
-- seen or on radar. That is what makes scouting matter: a game ender nobody
-- has seen triggers no anti-nuke, no shields and no strike mission.
--
-- Memory is per map side (the two teams of Dual Gap) and shared by all
-- DualGap brains on that side. What a scout finds is also called out to the
-- team (DualGapComms): a ping on the map and a team chat line.
--
-- Stalemate: when the team has known nothing about the enemy for
-- Config.StaleSeconds (typically the last enemy ACU hiding underwater, out
-- of everyone's sight), Stale(side) turns true and scouts, torpedo bombers
-- and fleets search the enemy's deep water. Submerged units are only found
-- by sonar (air scouts, torpedo bombers and ships carry it).

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
local Routes = import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')
local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')

local Alive = Utils.Alive

local CatEnders = categories.STRUCTURE * (categories.NUKE
    + categories.ARTILLERY * (categories.TECH3 + categories.EXPERIMENTAL)
    + categories.EXPERIMENTAL)
local CatEnemyT4 = categories.EXPERIMENTAL * categories.MOBILE
local CatAA = categories.ANTIAIR * (categories.LAND + categories.NAVAL + categories.STRUCTURE) - categories.AIR
local CatNaval = categories.NAVAL * (categories.MOBILE + categories.STRUCTURE)
local CatEnemyAntiNuke = categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE
local CatShields = categories.SHIELD * categories.STRUCTURE
-- Anything worth hunting: when none of it is known, the team is stuck.
local CatHuntable = categories.STRUCTURE + categories.LAND + categories.NAVAL + categories.COMMAND - categories.WALL

local teams = {}

local function OtherSide(side)
    if side == 'LEFT' then return 'RIGHT' end
    return 'LEFT'
end

local function Team(side)
    if not teams[side] then
        teams[side] = { enders = {}, t4Seen = false, aa = {}, naval = {}, antiNukes = {}, shields = {},
            t4Units = {}, lastKnownAt = 0, stale = false, subACUs = {} }
    end
    return teams[side]
end

-- Does `army` have intel on enemy unit e?
function Known(e, army)
    if not Alive(e) or not e.GetBlip then return false end
    local ok, blip = pcall(e.GetBlip, e, army)
    if not ok or not blip then return false end
    if EntityCategoryContains(categories.STRUCTURE, e) then return blip:IsSeenEver(army) end
    if blip:IsSeenNow(army) or blip:IsOnRadar(army) then return true end
    -- Submerged units only show up on sonar (or omni).
    if blip.IsOnSonar and blip:IsOnSonar(army) then return true end
    if blip.IsOnOmni and blip:IsOnOmni(army) then return true end
    return false
end

local function EnderKind(e)
    -- Yolona Oss: an experimental launcher that fires nukes one after another.
    if EntityCategoryContains(categories.NUKE * categories.EXPERIMENTAL, e) then return 'YOLONA' end
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
            local what = 'Enemy ' .. Comms.UnitName(e)
            if EnderKind(e) == 'NUKE' then what = 'Enemy NUKE' end
            if EnderKind(e) == 'YOLONA' then what = 'Enemy YOLONA OSS (rapid nukes), build anti-nukes!' end
            local state = (e:GetFractionComplete() < 1) and ' under construction' or ''
            Comms.Say(brain, side, 'ender:' .. key, what .. state .. ' spotted here!', e:GetPosition(), 'alert')
        end
    end
    for key, rec in pairs(t.enders) do
        if not Alive(rec.unit) then t.enders[key] = nil end
    end
    for _, e in ipairs(KnownEnemies(brain, CatEnemyT4)) do
        local key = e.EntityId or tostring(e)
        if not t.t4Units[key] then
            t.t4Units[key] = true
            t.t4Seen = true
            Utils.Log(brain, 'scouted an enemy experimental unit')
            -- One callout per experimental type a minute, not one per unit.
            Comms.Say(brain, side, 't4:' .. tostring(e:GetBlueprint().BlueprintId), 'Enemy experimental: ' .. Comms.UnitName(e) .. '!',
                e:GetPosition(), 'alert')
        end
    end
    t.aa = {}
    for _, e in ipairs(KnownEnemies(brain, CatAA)) do table.insert(t.aa, e:GetPosition()) end
    t.naval = KnownEnemies(brain, CatNaval)
    t.antiNukes = {}
    for _, e in ipairs(KnownEnemies(brain, CatEnemyAntiNuke)) do table.insert(t.antiNukes, e:GetPosition()) end
    t.shields = KnownEnemies(brain, CatShields)

    -- Enemy ACUs seen under water: remembered (last position) for a while,
    -- so torpedo bombers and fleets keep hunting them after contact is lost.
    local now0 = GetGameTimeSeconds()
    for _, e in ipairs(KnownEnemies(brain, categories.COMMAND)) do
        local key = e.EntityId or tostring(e)
        if Utils.IsUnderwater(e) then
            if not t.subACUs[key] then
                Comms.Say(brain, side, 'subacu:' .. key, 'Enemy ACU hiding under water here! Torpedo bombers and ships!',
                    e:GetPosition(), 'attack')
            end
            local p = e:GetPosition()
            t.subACUs[key] = { unit = e, pos = { p[1], p[2], p[3] }, at = now0 }
        elseif t.subACUs[key] then
            t.subACUs[key] = nil
        end
    end
    for key, rec in pairs(t.subACUs) do
        if not Alive(rec.unit) or now0 - rec.at > Config.SubACUMemory then t.subACUs[key] = nil end
    end

    -- Stalemate watch.
    local now = GetGameTimeSeconds()
    if table.getn(KnownEnemies(brain, CatHuntable)) > 0 then
        t.lastKnownAt = now
        if t.stale then
            t.stale = false
            Utils.Log(brain, 'enemy found again, search mode off')
        end
    elseif not t.stale and now - t.lastKnownAt >= Config.StaleSeconds and now > 600 then
        t.stale = true
        Utils.Log(brain, 'no known enemy for ' .. Config.StaleSeconds .. 's: searching the deep water')
        Comms.Say(brain, side, 'stale', 'Lost the enemy. Searching their deep water, send sonar and torpedo bombers.',
            DeepWater(OtherSide(side)), 'move')
    end
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

-- Known enemy structure shields whose bubble covers pos and is up right now.
function ShieldsOver(side, pos)
    local n = 0
    for _, s in ipairs(Team(side).shields) do
        if Alive(s) and s:GetFractionComplete() >= 1 then
            local bp = s:GetBlueprint()
            local size = bp.Defense and bp.Defense.Shield and bp.Defense.Shield.ShieldSize
            if size and Utils.Dist2D(s:GetPosition(), pos) <= size / 2 then
                local up = true
                if s.MyShield and s.MyShield.IsUp then
                    local ok, res = pcall(s.MyShield.IsUp, s.MyShield)
                    if ok then up = res end
                end
                if up then n = n + 1 end
            end
        end
    end
    return n
end

-- True while the team has lost track of the enemy (see the header).
function Stale(side)
    if not side then return false end
    return Team(side).stale
end

-- Enemy ACUs seen under water recently: { unit, pos (last seen), at }.
function SubmergedACUs(side)
    local out = {}
    if not side then return out end
    for _, rec in pairs(Team(side).subACUs or {}) do
        if Alive(rec.unit) then table.insert(out, rec) end
    end
    return out
end

-- Hunt mode: the enemy is lost, or an enemy ACU is hiding under water.
-- Torpedo bombers, subs and fleets are built and sent in small groups.
function HuntMode(side)
    return Stale(side) or table.getn(SubmergedACUs(side)) > 0
end

-- Deepest water in `side`'s rear: where an ACU hides. Map knowledge every
-- player has; cached for two minutes (the playable area can grow).
local deepCache = {}
function DeepWater(side)
    local c = deepCache[side]
    local now = GetGameTimeSeconds()
    if not c or now - c.at > 120 then
        c = { at = now, pos = Utils.DeepestRearWater(side) }
        deepCache[side] = c
    end
    return c.pos
end

-- Is pos covered by a known enemy anti-nuke (SMD range 90)?
function UnderEnemyAntiNuke(side, pos)
    return AntiNukesCovering(side, pos) > 0
end

-- How many known enemy anti-nukes cover pos.
function AntiNukesCovering(side, pos)
    local n = 0
    for _, p in ipairs(Team(side).antiNukes) do
        if Utils.Dist2D(p, pos) <= 92 then n = n + 1 end
    end
    return n
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

local function AirScoutRoute(ctx, offset)
    local pts = {}
    local enemy = OtherSide(ctx.side)
    for _, s in pairs(RoleManager.GetSlots()) do
        if s.side == enemy then table.insert(pts, s.pos) end
    end
    -- Where experimentals and game enders get built: the map's protected
    -- construction spots next to the enemy bases.
    for _, m in pairs(ScenarioUtils.GetMarkers() or {}) do
        if m.type == 'Protected Experimental Construction' and m.position and Utils.SideOf(m.position) == enemy then
            table.insert(pts, m.position)
        end
    end
    table.sort(pts, function(a, b) return a[3] < b[3] end)
    table.insert(pts, Routes.GetPoint('NavalRally', enemy))
    -- The enemy's deepest water, where an ACU hides late in the game.
    local deep = DeepWater(enemy)
    if deep then table.insert(pts, deep) end
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
