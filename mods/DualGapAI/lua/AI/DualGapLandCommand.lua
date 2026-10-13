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

-- The own defensive point of a zone, where SUPPORT waves go.
function ZonePoint(zone, side)
    return import('/mods/DualGapAI/lua/AI/DualGapRoutes.lua').GetPoint(ZoneChoke[zone], side)
end

local commands = {}      -- side -> { members = { {brain, ctx} }, tasks = { name -> task } }

local function Cmd(side)
    commands[side] = commands[side] or { members = {}, tasks = {} }
    return commands[side]
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
            local task = { mode = mode, scale = scale, zone = zone, support = support, at = now, since = since }
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
