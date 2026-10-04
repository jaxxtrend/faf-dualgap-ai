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
            t4Units = {}, lastKnownAt = 0, stale = false, subACUs = {}, acuSeen = {}, lostACUs = {} }
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

-- Tracks when each enemy ACU was last seen, and which enemy players still in
-- the game have lost their ACU from sight with almost nothing else left.
-- Who is still in the game is on everyone's scoreboard: not a cheat.
local CatClues = categories.STRUCTURE - categories.WALL
function LostACUScan(brain, side, t, now)
    if not (ArmyBrains and IsEnemy and ArmyIsOutOfGame) then return end
    for _, e in ipairs(KnownEnemies(brain, categories.COMMAND)) do
        local p = e:GetPosition()
        t.acuSeen[e:GetArmy()] = { at = now, pos = { p[1], p[2], p[3] } }
    end
    local me = brain:GetArmyIndex()
    local x0, z0, x1, z1 = Utils.MapBounds()
    local center = { (x0 + x1) / 2, 0, (z0 + z1) / 2 }
    local known = {}
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatClues, center, math.max(x1 - x0, z1 - z0), 'Enemy') or {}) do
        if Known(e, me) then
            local a = e:GetArmy()
            known[a] = known[a] or {}
            table.insert(known[a], e)
        end
    end
    local lost = {}
    for i, b in ipairs(ArmyBrains) do
        if IsEnemy(me, i) and not ArmyIsOutOfGame(i) and not (ArmyIsCivilian and ArmyIsCivilian(i)) then
            local seen = t.acuSeen[i]
            local structs = known[i] or {}
            t.maxKnown = t.maxKnown or {}
            t.maxKnown[i] = math.max(t.maxKnown[i] or 0, table.getn(structs))
            if ACULost(now, seen and seen.at, table.getn(structs), t.maxKnown[i]) then
                local clues = {}
                if seen and now - seen.at < Config.SubACUMemory * 2 then table.insert(clues, seen.pos) end
                -- Structures on water first: torpedo launchers and AA by the
                -- shore give a hiding spot away.
                local wet, dry = {}, {}
                for _, s in ipairs(structs) do
                    local p = s:GetPosition()
                    if Utils.WaterDepth(p[1], p[3]) > 0 then table.insert(wet, p) else table.insert(dry, p) end
                end
                for _, p in ipairs(wet) do table.insert(clues, p) end
                for _, p in ipairs(dry) do table.insert(clues, p) end
                table.insert(lost, { army = i, clues = clues })
                if not t.lostAnnounced then t.lostAnnounced = {} end
                if not t.lostAnnounced[i] then
                    t.lostAnnounced[i] = true
                    Utils.Log(brain, 'enemy ACU of army ' .. i .. ' is lost: hunting it (' .. table.getn(clues) .. ' clues)')
                    Comms.Say(brain, side, 'lostacu:' .. i, (b.Nickname or 'Enemy') .. "'s ACU is hiding somewhere. Hunt it: sonar, torpedo bombers, ships!",
                        clues[1] or DeepWater(OtherSide(side)), 'attack')
                end
            end
        end
    end
    t.lostACUs = lost
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
            Comms.Say(brain, side, 'ender:' .. key, what .. state .. ' spotted here! Everyone on it!', e:GetPosition(), 'alert')
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
    t.underSince = t.underSince or {}
    for _, e in ipairs(KnownEnemies(brain, categories.COMMAND)) do
        local key = e.EntityId or tostring(e)
        local p0 = e:GetPosition()
        local under = Utils.IsUnderwater(e)
        if under then t.underSince[key] = t.underSince[key] or now0 else t.underSince[key] = nil end
        local nx = Utils.Normalise(p0[1], p0[3])
        local rear = (side == 'LEFT' and nx >= 1 - Utils.RearDepth) or (side == 'RIGHT' and nx <= Utils.RearDepth)
        if under and HidingUnderwater(now0 - t.underSince[key], Utils.WaterDepth(p0[1], p0[3]), rear) then
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
    LostACUScan(brain, side, t, now0)

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

-- Exposed for tests: is an ACU under water for `secs` at `depth` hiding?
function HidingUnderwater(secs, depth, rear)
    return rear and secs >= Config.SubACUHideSeconds and depth >= Config.SubACUHideDepth
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

-- The team's air T4 operation: { lead, units, phase = 'gather'|'go',
-- target (unit or nil), targetPos, id, by } or nil.
function AirT4Op(side)
    if not side then return nil end
    return Team(side).airT4Op
end

function SetAirT4Op(side, op)
    Team(side).airT4Op = op
end

-- The team's current mass air attack: { pos, unit, at } or nil. Set by the
-- AIR player who launches it; the other AIR player joins the same target.
function AirMass(side)
    if not side then return nil end
    return Team(side).airMass
end

function SetAirMass(side, rec)
    Team(side).airMass = rec
end

-- Enemy players still in the game whose ACU is lost (see Config.ACULostSeconds):
-- { army, clues = { points to search, best first } }.
function LostACUs(side)
    if not side then return {} end
    return Team(side).lostACUs or {}
end

-- Exposed for tests: is an enemy player's ACU lost?
function ACULost(now, lastSeenAt, knownStructures, maxKnown)
    if now < Config.ACULostMinTime then return false end
    if (maxKnown or 0) < Config.ACULostMinSeenBase then return false end
    if knownStructures > Config.ACULostMaxStructures then return false end
    return now - (lastSeenAt or 0) >= Config.ACULostSeconds
end

-- Hunt mode: the enemy is lost, an enemy ACU is hiding under water, or a
-- nearly beaten enemy's ACU is nowhere to be seen.
-- Torpedo bombers, subs and fleets are built and sent in small groups.
function HuntMode(side)
    return Stale(side) or table.getn(SubmergedACUs(side)) > 0 or table.getn(LostACUs(side)) > 0
end

-- Where to look for a hidden enemy ACU, best clue first: submerged ACUs'
-- last spots, lost ACUs' clues, then the enemy's deep water spots.
function SearchPoints(side)
    local pts = {}
    for _, rec in ipairs(SubmergedACUs(side)) do table.insert(pts, rec.pos) end
    for _, l in ipairs(LostACUs(side)) do
        for _, p in ipairs(l.clues) do table.insert(pts, p) end
    end
    for _, p in ipairs(DeepSpots(OtherSide(side))) do table.insert(pts, p) end
    return pts
end

-- The k-th search point (wraps around): spreads searchers over the clues.
function SearchPoint(side, k)
    local pts = SearchPoints(side)
    local n = table.getn(pts)
    if n == 0 then return nil end
    k = math.floor(k or 1)
    while k > n do k = k - n end
    if k < 1 then k = 1 end
    return pts[k]
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

-- Several deep water spots in `side`'s rear, at least 120 apart (an ACU
-- may hide in any of them; the deepest is not always the one).
local deepSpotsCache = {}
function DeepSpots(side)
    local c = deepSpotsCache[side]
    local now = GetGameTimeSeconds()
    if not c or now - c.at > 120 then
        local spots = {}
        for i = 1, 4 do
            local p = Utils.DeepestRearWater(side, spots, 120)
            if not p then break end
            table.insert(spots, p)
        end
        c = { at = now, spots = spots }
        deepSpotsCache[side] = c
    end
    return c.spots
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
    -- The enemy's deepest water, where an ACU hides late in the game; while
    -- hunting, every clue of a hidden ACU.
    if HuntMode(ctx.side) then
        for _, p in ipairs(SearchPoints(ctx.side)) do table.insert(pts, p) end
    else
        local deep = DeepWater(enemy)
        if deep then table.insert(pts, deep) end
    end
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

-- Exposed for tests: scouts per pack at game time `now`.
function ScoutPackSize(now)
    if now >= Config.ScoutPackLateSeconds then return Config.ScoutPackSizeLate end
    return Config.ScoutPackSize
end

local function FinishedScouts(brain)
    local out = {}
    for _, u in ipairs(brain:GetListOfUnits(CatAirScout, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            u.DualGapAssigned = true
            table.insert(out, u)
        end
    end
    return out
end

-- AIR: scouts wait at home until a pack is complete, then the pack flies
-- the scouting loop together; each new pack starts the loop elsewhere.
local function PackScouts(brain, ctx, scouts, now)
    ctx.scoutPacks = ctx.scoutPacks or {}
    local inPack = {}
    local keep = {}
    for _, pack in ipairs(ctx.scoutPacks) do
        pack.units = Utils.FilterAlive(pack.units)
        if table.getn(pack.units) > 0 then
            table.insert(keep, pack)
            for _, u in ipairs(pack.units) do inPack[u] = true end
            if now - pack.at > Config.ScoutRepathSeconds then
                pack.at = now
                IssueClearCommands(pack.units)
                for _, p in ipairs(AirScoutRoute(ctx, pack.offset)) do IssuePatrol(pack.units, p) end
            end
        end
    end
    ctx.scoutPacks = keep
    local waiting = {}
    for _, u in ipairs(scouts) do
        if not inPack[u] then table.insert(waiting, u) end
    end
    local size = ScoutPackSize(now)
    if table.getn(waiting) >= size then
        local units = {}
        for k = 1, size do table.insert(units, waiting[k]) end
        ctx.scoutPackN = (ctx.scoutPackN or 0) + 1
        local pack = { units = units, at = now, offset = ctx.scoutPackN * 3 }
        IssueClearCommands(units)
        for _, p in ipairs(AirScoutRoute(ctx, pack.offset)) do IssuePatrol(units, p) end
        table.insert(ctx.scoutPacks, pack)
        Utils.Log(brain, 'scout pack of ' .. size .. ' goes out')
    else
        for _, u in ipairs(waiting) do
            if u:IsIdleState() and Utils.Dist2D(u:GetPosition(), ctx.startPos) > 40 then IssueMove({ u }, ctx.startPos) end
        end
    end
end

-- NAVAL: scouts circle over the leading ships (the one furthest toward the
-- enemy), widening the fleet's sight; over the naval rally without ships.
local function NavalScouts(brain, ctx, scouts, now)
    local dir = (ctx.side == 'LEFT') and 1 or -1
    local lead, best
    for _, u in ipairs(brain:GetListOfUnits(categories.NAVAL * categories.MOBILE, false)) do
        if Alive(u) and u:GetFractionComplete() >= 1 then
            local x = u:GetPosition()[1] * dir
            if not best or x > best then lead, best = u, x end
        end
    end
    local c = lead and lead:GetPosition() or Routes.GetPoint('NavalRally', ctx.side)
    local r = Config.NavalScoutRadius
    for i, u in ipairs(scouts) do
        if u:IsIdleState() or not u.DGScoutAt or now - u.DGScoutAt > 15 then
            u.DGScoutAt = now
            local a = (i - 1) * 1.6
            local pts = {}
            for k = 0, 3 do
                local ang = a + k * 1.5708
                local x, z = c[1] + math.cos(ang) * r + dir * 20, c[3] + math.sin(ang) * r
                table.insert(pts, { x, GetSurfaceHeight(x, z), z })
            end
            IssueClearCommands({ u })
            for _, p in ipairs(pts) do IssuePatrol({ u }, p) end
        end
    end
end

-- ECO: right before its game ender goes in, the scouts fly over the enemy
-- ECO base together (and its experimental construction spots).
local function EcoScouts(brain, ctx, scouts, now)
    if table.getn(scouts) == 0 then return end
    local busy = false
    for _, u in ipairs(scouts) do if not u:IsIdleState() then busy = true end end
    if busy and ctx.ecoScoutAt and now - ctx.ecoScoutAt < Config.ScoutRepathSeconds then return end
    if table.getn(scouts) < Config.ScoutPackSize and not busy and not ctx.t4Op then return end
    ctx.ecoScoutAt = now
    local enemy = OtherSide(ctx.side)
    local pts = {}
    for _, p in ipairs(import('/mods/DualGapAI/lua/AI/DualGapMexOwnership.lua').DutyPositions(enemy, 'ECO')) do
        table.insert(pts, p)
    end
    for _, m in pairs(ScenarioUtils.GetMarkers() or {}) do
        if m.type == 'Protected Experimental Construction' and m.position and Utils.SideOf(m.position) == enemy
            and pts[1] and Utils.Dist2D(m.position, pts[1]) < 250 then
            table.insert(pts, m.position)
        end
    end
    if table.getn(pts) == 0 then return end
    IssueClearCommands(scouts)
    for _, p in ipairs(pts) do IssuePatrol(scouts, p) end
    Utils.Log(brain, table.getn(scouts) .. ' scouts look over the enemy ECO base before our game ender')
end

local function ScoutStep(brain, ctx)
    local now = GetGameTimeSeconds()
    local scouts = FinishedScouts(brain)
    if ctx.role == 'NAVAL' then
        NavalScouts(brain, ctx, scouts, now)
    elseif ctx.role == 'ECO' then
        EcoScouts(brain, ctx, scouts, now)
    else
        PackScouts(brain, ctx, scouts, now)
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
