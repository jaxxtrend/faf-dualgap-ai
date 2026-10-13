-- Land command: one per team side. Every Config.LandCommandSeconds it reads
-- the general staff's stances (DualGapCommand) and gives each player with
-- the GROUND duty a task for its mid zone (the upper or the lower mid):
--
--   PUSH     the zone is ours to take: waves leave earlier and press on
--   HOLD     even fight: waves as usual
--   DEFEND   the enemy is clearly stronger there: no attack waves, the army
--            holds at its wall; waves out in the enemy half fall back to it
--            instead of being fed in one by one
--   SUPPORT  the other mid is defending: send waves there to help
--
-- DualGapArmy reads the task (Task(side, name)); with no task (no staff
-- orders yet, or no GROUND duty) it plays on its own rules.

local Config = import('/mods/DualGapAI/lua/AI/DualGapConfig.lua')
local Utils = import('/mods/DualGapAI/lua/AI/DualGapUtils.lua')
local Command = import('/mods/DualGapAI/lua/AI/DualGapCommand.lua')
local Comms = import('/mods/DualGapAI/lua/AI/DualGapComms.lua')

local OtherZone = { UPPER = 'LOWER', LOWER = 'UPPER' }
local ZoneChoke = { UPPER = 'ChokeUpper', LOWER = 'ChokeLower' }
local ZoneName = { UPPER = 'upper mid', LOWER = 'lower mid' }

-- Exposed for tests: the task for a GROUND player holding `zone`.
-- Returns mode, wave size scale, and the zone to support (SUPPORT only).
function LandTask(zone, ownStance, otherStance, focus)
    if ownStance == 'DEFEND' then return 'DEFEND', 1, nil end
    if otherStance == 'DEFEND' and not (ownStance == 'ATTACK' and focus == zone) then
        return 'SUPPORT', Config.LandSupportScale, OtherZone[zone]
    end
    if ownStance == 'ATTACK' then return 'PUSH', Config.LandPushScale, nil end
    return 'HOLD', 1, nil
end

-- Exposed for tests: the task mode to keep (prev held since `since`)
-- when the stances now say `new`. A SUPPORT holds LandSupportHold seconds
-- (the army is on its way; calling it back at once only walks it through
-- the base and back), and right after a DEFEND the army is not sent away
-- to the other mid for as long: its own mid got weak just now. Fighting at
-- the own wall goes on regardless (DualGapArmy: enemy at the wall).
function KeepTask(prev, since, now, new)
    if not prev or prev == new then return new end
    local fresh = now - since < Config.LandSupportHold
    if prev == 'SUPPORT' and fresh then return prev end
    if new == 'SUPPORT' and prev == 'DEFEND' and fresh then return prev end
    return new
end

-- The mid zone a player holds: the lower GROUND the lower mid, everyone
-- else (the upper GROUND, an heir with another role) the upper one.
function ZoneOfPlayer(ctx)
    return (ctx.groundArc == 'GroundArcSouth') and 'LOWER' or 'UPPER'
end

---------------------------------------------------------------------------
-- Defence lines (Config.DefenceLines)
---------------------------------------------------------------------------
local function Lerp(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t }
end

-- Number of lines from the own base passes to the enemy's (0 .. LineCount-1).
function LineCount()
    return 2 * table.getn(Config.DefenceLines) - 1
end

-- Exposed for tests: the normalised (left team) point of line i for a
-- zone's player; lines past the centre are the enemy's, mirrored.
function LineAnchorN(i, zone, t)
    local own = table.getn(Config.DefenceLines)
    local j, mirror = i, false
    if i >= own then j, mirror = 2 * (own - 1) - i, true end
    local segs = Config.DefenceLines[j + 1]
    local p
    if table.getn(segs) == 1 then
        p = Lerp(segs[1][1], segs[1][2], t or ((zone == 'LOWER') and 0.7 or 0.3))
    else
        local s = segs[(zone == 'LOWER') and 3 or 2]
        p = Lerp(s[1], s[2], 0.5)
    end
    if mirror then p = { 1 - p[1], p[2] } end
    return p
end

function LineAnchor(i, zone, side, t)
    return Utils.ToWorld(LineAnchorN(i, zone, t), side)
end

-- Exposed for tests: the line to hold now, and why it changed (nil = kept).
-- enemyAt: the lowest line up to the held one with a seen enemy army on
-- it (nil: none); fortified: the held line has own point defences.
function ChooseLine(cur, since, now, stance, enemyAt, fortified, maxLine)
    if enemyAt and enemyAt < cur then return math.max(0, enemyAt - 1), 'enemy past the line' end
    if now - since < Config.LineHoldSeconds then return cur, nil end
    if stance == 'ATTACK' and cur < maxLine and not enemyAt then return cur + 1, 'stronger here' end
    if stance == 'DEFEND' and cur > 0 and not fortified then return cur - 1, 'weaker here' end
    return cur, nil
end

-- The point of the zone where SUPPORT waves go: on the held line (the
-- mid defensive point before there is one).
function ZonePoint(zone, side, line)
    if line then return LineAnchor(line, zone, side) end
    return import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua').GetPoint(ZoneChoke[zone], side)
end

-- Waypoints of an attack from the held line: the zone's points on every
-- line ahead (a straight lane, no detours), then `goal`.
function LinePath(line, zone, side, goal, t)
    local out = {}
    for i = line + 1, LineCount() - 1 do table.insert(out, LineAnchor(i, zone, side, t)) end
    if goal then table.insert(out, goal) end
    return out
end

local CatLineEnemy = categories.LAND * categories.MOBILE - categories.ENGINEER - categories.SCOUT
local CatOwnPD = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE

local function SeenMass(brain, pos, radius)
    local army = brain:GetArmyIndex()
    local Intel = import('/mods/DualGapAI/lua/AI/DualGapIntel.lua')
    local m = 0
    for _, e in ipairs(brain:GetUnitsAroundPoint(CatLineEnemy, pos, radius, 'Enemy') or {}) do
        if not e.Dead and Intel.Known(e, army) then
            local eco = e:GetBlueprint().Economy
            m = m + ((eco and eco.BuildCostMass) or 0)
        end
    end
    return m
end

local function UpdateLine(cmd, b, ctx, zone, side)
    local now = GetGameTimeSeconds()
    local st = cmd.lines[b.Name]
    if not st then
        st = { line = Config.LineStart, since = now }
        cmd.lines[b.Name] = st
    end
    local enemyAt
    for i = 0, st.line do
        if SeenMass(b, LineAnchor(i, zone, side), Config.LineEnemyRadius) >= Config.LineEnemyMass then
            enemyAt = i
            break
        end
    end
    local fortified = Utils.CountAround(b, CatOwnPD, LineAnchor(st.line, zone, side), 40, 'Ally') >= Config.LineFortifiedPDs
    local maxLine = ctx.midPushed and table.getn(Config.DefenceLines) or table.getn(Config.DefenceLines) - 1
    local line, why = ChooseLine(st.line, st.since, now, Command.ZoneStance(side, zone), enemyAt, fortified, maxLine)
    if line ~= st.line then
        Utils.Log(b, 'DEFENCE LINE ' .. zone .. ': ' .. st.line .. ' -> ' .. line .. ' (' .. tostring(why) .. ')')
        if line < st.line then
            Comms.Say(b, side, 'line:' .. b.Name, 'Falling back to the next line on the ' .. ZoneName[zone] .. '.')
        end
        st.line, st.since = line, now
    end
    return st.line, st.since
end

local commands = {}      -- side -> { members = { {brain, ctx} }, tasks = { name -> task } }

local function Cmd(side)
    commands[side] = commands[side] or { members = {}, tasks = {}, lines = {} }
    return commands[side]
end

-- The line a player holds and since when (nil before the first step).
function Line(side, name)
    if not side then return nil end
    local st = Cmd(side).lines[name]
    return st and st.line, st and st.since
end

function Register(brain, ctx)
    table.insert(Cmd(ctx.side).members, { brain = brain, ctx = ctx })
end

-- The current task of a player (nil: play on the own rules).
function Task(side, name)
    if not side then return nil end
    return Cmd(side).tasks[name]
end

local SayText = {
    PUSH = 'Pushing the %s!',
    DEFEND = 'Holding at my wall on the %s, they are stronger here.',
    SUPPORT = 'Sending my army to support the %s.',
}

local function Step(side)
    local cmd = Cmd(side)
    if not Command.Orders(side) then return end
    local focus = Command.Orders(side).focus
    for _, m in ipairs(cmd.members) do
        local b, ctx = m.brain, m.ctx
        if not Utils.BrainDefeated(b) and Utils.HasDuty(ctx, 'GROUND') and Utils.Level(ctx).commands then
            local zone = ZoneOfPlayer(ctx)
            local mode, scale, support = LandTask(zone, Command.ZoneStance(side, zone),
                Command.ZoneStance(side, OtherZone[zone]), focus)
            local prev = cmd.tasks[b.Name]
            local now = GetGameTimeSeconds()
            if prev then
                local keep = KeepTask(prev.mode, prev.since or now, now, mode)
                if keep ~= mode then mode, scale, support = keep, prev.scale, prev.support end
            end
            local since = (prev and prev.mode == mode and prev.support == support) and prev.since or now
            local line = UpdateLine(cmd, b, ctx, zone, side)
            local task = { mode = mode, scale = scale, zone = zone, support = support, at = now, since = since, line = line }
            cmd.tasks[b.Name] = task
            if not prev or prev.mode ~= mode or prev.support ~= support then
                Utils.Log(b, 'LAND COMMAND: ' .. mode .. ' ' .. zone .. (support and (' -> support ' .. support) or ''))
                local text = SayText[mode]
                if text then
                    local where = ZoneName[support or zone]
                    Comms.Say(b, side, 'landcmd:' .. b.Name, string.format(text, where),
                        ZonePoint(support or zone, side), (mode == 'DEFEND') and 'alert' or 'attack')
                end
            end
        else
            cmd.tasks[b.Name] = nil
        end
    end
end

local running = false
local function StartLoop()
    if running then return end
    running = true
    ForkThread(function()
        while true do
            WaitSeconds(Config.LandCommandSeconds)
            for side, _ in pairs(commands) do
                local ok, err = pcall(Step, side)
                if not ok then WARN('DualGap land command: ' .. tostring(err)) end
            end
        end
    end)
end

function Start(brain, ctx)
    Register(brain, ctx)
    StartLoop()
end
