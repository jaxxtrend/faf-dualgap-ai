-- Strategic command: one per team side, every Config.StratCommandSeconds.
-- It runs the team's game-ender war:
--
--   target     the one enemy game ender the whole team goes for (land waves,
--              fleets, bombers): the most dangerous scouted one - Yolona Oss,
--              nuke, T4 artillery, T3 artillery, other experimental
--              structures; finished before under construction; the nearest
--              to the team on ties
--   plan       how the team's own game ender plans adapt (DualGapProjects):
--              no nuke steps while the enemy has StratSkipNukeAntiNukes or
--              more known anti-nukes (artillery instead); no air T4 steps
--              while the staff says the enemy rules the sky
--   nukes      one shared nuke focus for all of the team's silos, so their
--              missiles land on one point and saturate the anti-nukes
--
-- Read by DualGapArmy (EnderTarget) and DualGapProjects (plan, nukes).

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
local Command = import('/mods/DualGapAI/lua/AI/DualGapCommand.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')

local Alive = Utils.Alive

local KindRank = { YOLONA = 1, NUKE = 2, ARTY = 3, T4 = 5 }

-- Exposed for tests: danger rank of an enemy game ender (lower = first).
-- kind: Intel ender kind; t4arty: experimental artillery; complete: finished.
function EnderRank(kind, t4arty, complete)
    local r = KindRank[kind] or 6
    if kind == 'ARTY' and t4arty then r = 2.5 end
    if not complete then r = r + 10 end
    return r
end

-- Exposed for tests: plan steps to skip. Returns skipNuke, skipAirT4.
function PlanSkips(enemyAntiNukes, airStance)
    return enemyAntiNukes >= Config.StratSkipNukeAntiNukes, airStance == 'DEFEND'
end

local commands = {}      -- side -> { brains = {}, target = rec, skipNuke, skipAirT4, nuke = {pos, value0, shots, at, by} }

local function Cmd(side)
    commands[side] = commands[side] or { brains = {} }
    return commands[side]
end

function Register(brain, side)
    table.insert(Cmd(side).brains, brain)
end

-- The team's game ender target record ({unit, pos, kind}) or nil.
function EnderTarget(side)
    local t = Cmd(side).target
    if t and Alive(t.unit) then return t end
    return nil
end

function SkipNuke(side) return Cmd(side).skipNuke == true end
function SkipAirT4(side) return Cmd(side).skipAirT4 == true end

-- Shared nuke focus: { pos, value0, shots } kept for the whole team.
function NukeFocus(side)
    local f = Cmd(side).nuke
    if f and GetGameTimeSeconds() - f.at < Config.StratNukeFocusSeconds then return f end
    return nil
end

function SetNukeFocus(side, f, byName)
    if f then
        f.at = GetGameTimeSeconds()
        f.by = byName
    end
    Cmd(side).nuke = f
end

local function TeamCenter(side)
    local RoleManager = import('/mods/DualGapAI/lua/AI/DualGapRoleManager.lua')
    local x, z, n = 0, 0, 0
    for _, s in pairs(RoleManager.GetSlots()) do
        if s.side == side then x, z, n = x + s.pos[1], z + s.pos[3], n + 1 end
    end
    if n == 0 then return nil end
    return { x / n, 0, z / n }
end

local CatT4Arty = categories.ARTILLERY * categories.EXPERIMENTAL

local function Step(side, brain)
    local cmd = Cmd(side)
    -- 1. The team's game ender target.
    local sx, sz = brain:GetArmyStartPos()
    local center = TeamCenter(side) or { sx, 0, sz }
    local best, bestR, bestD
    for _, rec in ipairs(Intel.Enders(side)) do
        if Alive(rec.unit) then
            -- Finished or not as the team last saw it (no peeking).
            local r = EnderRank(rec.kind, EntityCategoryContains(CatT4Arty, rec.unit), rec.complete ~= false)
            local d = Utils.Dist2D(rec.unit:GetPosition(), center)
            if not bestR or r < bestR or (r == bestR and d < bestD) then best, bestR, bestD = rec, r, d end
        end
    end
    local prev = cmd.target
    cmd.target = best
    if best and (not prev or prev.unit ~= best.unit) then
        Utils.Log(brain, 'STRATEGIC ' .. side .. ': team target ' .. best.kind .. ' ' .. tostring(best.unit:GetBlueprint().BlueprintId))
        Comms.Say(brain, side, 'strat:target', 'Team target: their ' .. Comms.UnitName(best.unit) .. '. Everyone on it!',
            best.unit:GetPosition(), 'attack')
    end

    -- 2. Plan adaptation.
    local antiNukes = 0
    local x0, z0, x1, z1 = Utils.MapBounds()
    local all = brain:GetUnitsAroundPoint(categories.ANTIMISSILE * categories.TECH3 * categories.STRUCTURE,
        { (x0 + x1) / 2, 0, (z0 + z1) / 2 }, math.max(x1 - x0, z1 - z0), 'Enemy') or {}
    for _, e in ipairs(all) do
        if Alive(e) and Intel.Known(e, brain:GetArmyIndex()) then antiNukes = antiNukes + 1 end
    end
    local skipNuke, skipAir = PlanSkips(antiNukes, Command.ZoneStance(side, 'AIR'))
    if skipNuke ~= (cmd.skipNuke == true) then
        Utils.Log(brain, 'STRATEGIC ' .. side .. ': nuke steps ' .. (skipNuke and 'skipped' or 'back on') .. ' (' .. antiNukes .. ' enemy anti-nukes)')
        if skipNuke then
            Comms.Say(brain, side, 'strat:nuke', 'They have ' .. antiNukes .. ' anti-nukes: artillery instead of more nukes.',
                center, 'move')
        end
    end
    if skipAir ~= (cmd.skipAirT4 == true) then
        Utils.Log(brain, 'STRATEGIC ' .. side .. ': air T4 steps ' .. (skipAir and 'skipped (their air rules)' or 'back on'))
    end
    cmd.skipNuke, cmd.skipAirT4 = skipNuke, skipAir
end

local running = false
local function StartLoop()
    if running then return end
    running = true
    ForkThread(function()
        while true do
            WaitSeconds(Config.StratCommandSeconds)
            for side, cmd in pairs(commands) do
                for _, b in ipairs(cmd.brains) do
                    if not Utils.BrainDefeated(b) then
                        local ok, err = pcall(Step, side, b)
                        if not ok then WARN('DualGap strategic command: ' .. tostring(err)) end
                        break
                    end
                end
            end
        end
    end)
end

function Start(brain, ctx)
    Register(brain, ctx.side)
    StartLoop()
end
